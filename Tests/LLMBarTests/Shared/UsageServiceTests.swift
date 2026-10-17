import XCTest
@testable import LLMBar

@MainActor
final class UsageServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "LLMBar-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Deliberately uses a non-Claude source and metric to verify the strategy boundary.
    private func snapshot(_ percent: Int, providerID: String = "test-provider", reset: String? = nil) -> UsageSnapshot {
        UsageSnapshot(providerID: providerID, menuBarPercent: percent, sections: [], trackedLimits: [
            TrackedUsageLimit(id: "custom-window", name: .literal("Custom limit"),
                              bucket: UsageBucket(utilization: Double(percent), resetsAt: reset))
        ])
    }

    private func service(_ provider: StubUsageProvider, _ notifier: RecordingNotifier) -> UsageService {
        UsageService(provider: provider, notifier: notifier, defaults: defaults, startsAutomatically: false,
                     codexProvider: StubUsageProvider([]))
    }

    func testInjectedStrategySuppliesUsageAndPlanWithoutStartupSideEffects() async {
        let expected = snapshot(42)
        let provider = StubUsageProvider([.success(expected)])
        let notifier = RecordingNotifier()
        let service = service(provider, notifier)
        XCTAssertNil(service.usage)
        XCTAssertNil(service.lastUpdate)
        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(notifier.authorizationRequests, 0)
        await service.refresh()
        XCTAssertEqual(service.usage, expected)
        XCTAssertEqual(service.planType, "Test plan")
        XCTAssertNotNil(service.lastUpdate)
        XCTAssertNil(service.error)
        XCTAssertFalse(service.isLoading)
        XCTAssertTrue(notifier.messages.isEmpty, "First observation must not produce threshold notifications")
    }

    func testFailureRetainsDataTimestampAndThresholdHistoryThenRecovers() async {
        let initial = snapshot(49)
        let provider = StubUsageProvider([
            .success(initial), .failure(UsageProviderError(message: "offline")), .success(snapshot(50))
        ])
        let notifier = RecordingNotifier()
        let service = service(provider, notifier)
        await service.refresh()
        let updated = service.lastUpdate
        await service.refresh()
        XCTAssertEqual(service.usage, initial)
        XCTAssertEqual(service.lastUpdate, updated)
        XCTAssertEqual(service.error, "offline")
        XCTAssertFalse(service.isLoading)
        await service.refresh()
        XCTAssertEqual(service.usage?.menuBarPercent, 50)
        XCTAssertNil(service.error)
        XCTAssertEqual(notifier.messages.map(\.title), [L("notification.50_title")])
        XCTAssertEqual(notifier.messages.first?.body, L("notification.50_body", "Custom limit"))
    }

    func testFirstFailureLeavesLoadingScreenAndAllowsRetry() async {
        let provider = StubUsageProvider([.failure(UsageProviderError(message: "sign in")), .success(snapshot(0))])
        let service = service(provider, RecordingNotifier())
        await service.refresh()
        XCTAssertNil(service.usage)
        XCTAssertNil(service.lastUpdate)
        XCTAssertEqual(service.error, "sign in")
        XCTAssertEqual(service.planType, "Test plan")
        XCTAssertFalse(service.isLoading)
        await service.refresh()
        XCTAssertNotNil(service.usage)
        XCTAssertNil(service.error)
    }

    func testThresholdCrossingsRepeatedPollsAndResetKeepExistingBehavior() async {
        defaults.set(true, forKey: "notifyOnReset")
        let provider = StubUsageProvider([
            .success(snapshot(10)), .success(snapshot(100)), .success(snapshot(100)), .success(snapshot(0))
        ])
        let notifier = RecordingNotifier()
        let service = service(provider, notifier)
        for _ in 0..<4 { await service.refresh() }
        XCTAssertEqual(notifier.messages.map(\.title), [
            L("notification.50_title"), L("notification.75_title"),
            L("notification.limit_title"), L("notification.reset_title")
        ])
        XCTAssertEqual(notifier.messages[2].body, L("notification.limit_body", "Custom limit"))
    }

    func testRolledResetWindowStillNotifiesAndDisabledThresholdsStaySilent() async {
        defaults.set(false, forKey: "notifyAt50")
        defaults.set(false, forKey: "notifyAt75")
        defaults.set(false, forKey: "notifyAt100")
        defaults.set(true, forKey: "notifyOnReset")
        let provider = StubUsageProvider([
            .success(snapshot(10, reset: "2030-01-01T10:00:00Z")),
            .success(snapshot(100, reset: "2030-01-01T10:00:00Z")),
            .success(snapshot(4, reset: "2030-01-01T15:00:00Z"))
        ])
        let notifier = RecordingNotifier()
        let service = service(provider, notifier)
        for _ in 0..<3 { await service.refresh() }
        XCTAssertEqual(notifier.messages.map(\.title), [L("notification.reset_title")])
    }

    func testProviderIDsDoNotShareThresholdHistory() async {
        let provider = StubUsageProvider([
            .success(snapshot(49)), .success(snapshot(80, providerID: "another-provider"))
        ])
        let notifier = RecordingNotifier()
        let service = service(provider, notifier)
        await service.refresh()
        await service.refresh()
        XCTAssertTrue(notifier.messages.isEmpty)
    }

    func testSameLimitIDKeepsSeparateHistoryPerProvider() async {
        let claude = StubUsageProvider([.success(snapshot(49)), .success(snapshot(49))])
        let codex = StubUsageProvider([
            .success(snapshot(10, providerID: "codex")), .success(snapshot(80, providerID: "codex"))
        ])
        let notifier = RecordingNotifier()
        let service = UsageService(provider: claude, notifier: notifier, defaults: defaults,
                                   startsAutomatically: false, codexProvider: codex)
        await service.refresh()
        await service.refresh()
        XCTAssertEqual(notifier.messages.map(\.title), [L("notification.50_title"), L("notification.75_title")],
                       "Claude's report must not erase Codex's previous observation")
    }

    func testConcurrentRefreshIsIgnoredAndLoadingResetsAfterCompletion() async {
        let provider = StubUsageProvider([.success(snapshot(42))])
        let codex = StubUsageProvider([.success(snapshot(18, providerID: "codex"))])
        provider.suspend = true
        let began = expectation(description: "Provider started")
        provider.onFetch = { began.fulfill() }
        let service = UsageService(provider: provider, notifier: RecordingNotifier(), defaults: defaults,
                                   startsAutomatically: false, codexProvider: codex)
        let pending = Task { await service.refresh() }
        await fulfillment(of: [began], timeout: 1)
        XCTAssertTrue(service.isLoading)
        XCTAssertEqual(service.codex.usage?.menuBarPercent, 18, "Codex must not wait for Claude")
        await service.refresh()
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(codex.calls, 1)
        provider.resume()
        await pending.value
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.usage?.menuBarPercent, 42)
    }

    func testTabsShareRefreshWithoutSharingResultsErrorsOrAlerts() async {
        let claude = StubUsageProvider([
            .success(snapshot(10)), .failure(UsageProviderError(message: "Claude offline")),
            .success(snapshot(20))
        ])
        let codex = StubUsageProvider([
            .success(snapshot(49, providerID: "codex")), .success(snapshot(100, providerID: "codex")),
            .failure(UsageProviderError(message: "Codex offline"))
        ])
        let notifier = RecordingNotifier()
        let service = UsageService(provider: claude, notifier: notifier, defaults: defaults,
                                   startsAutomatically: false, codexProvider: codex)
        XCTAssertEqual(service.selectedTab, .claude)
        await service.refresh()
        let claudeUpdate = service.claude.lastUpdate

        service.selectedTab = .codex
        XCTAssertTrue(service.selectedState === service.codex)
        XCTAssertEqual(service.selectedState.usage?.menuBarPercent, 49)
        XCTAssertEqual(service.usage?.menuBarPercent, 10, "Menu bar must remain tied to Claude")
        service.selectedTab = .claude
        XCTAssertEqual(claude.calls, 1)
        XCTAssertEqual(codex.calls, 1, "Switching tabs must not fetch")

        await service.refresh()
        XCTAssertEqual(service.claude.error, "Claude offline")
        XCTAssertEqual(service.claude.lastUpdate, claudeUpdate)
        XCTAssertEqual(service.codex.usage?.menuBarPercent, 100)
        XCTAssertNil(service.codex.error)
        let codexUpdate = service.codex.lastUpdate
        XCTAssertNotNil(codexUpdate)
        XCTAssertEqual(notifier.messages.map(\.title), [
            L("notification.50_title"), L("notification.75_title"), L("notification.limit_title")
        ], "Codex thresholds use the shared alert settings")

        await service.refresh()
        XCTAssertEqual(service.claude.usage?.menuBarPercent, 20)
        XCTAssertNil(service.claude.error)
        XCTAssertEqual(service.codex.error, "Codex offline")
        XCTAssertEqual(service.codex.usage?.menuBarPercent, 100)
        XCTAssertEqual(service.codex.lastUpdate, codexUpdate)
        XCTAssertEqual(claude.calls, 3)
        XCTAssertEqual(codex.calls, 3)
    }

    func testPreferencesKeepTheirExistingKeysAndDefaults() {
        let provider = StubUsageProvider([])
        let service = service(provider, RecordingNotifier())
        XCTAssertTrue(service.showPercentage)
        XCTAssertEqual(service.refreshInterval, 60)
        XCTAssertTrue(service.notifyAt50)
        XCTAssertTrue(service.notifyAt75)
        XCTAssertTrue(service.notifyAt100)
        XCTAssertFalse(service.notifyOnReset)
        service.showPercentage = false
        service.refreshInterval = 120
        service.notifyAt75 = false
        service.notifyOnReset = true
        let restored = self.service(provider, RecordingNotifier())
        XCTAssertFalse(restored.showPercentage)
        XCTAssertEqual(restored.refreshInterval, 120)
        XCTAssertFalse(restored.notifyAt75)
        XCTAssertTrue(restored.notifyOnReset)
    }
}

@MainActor
private final class StubUsageProvider: UsageProvider {
    var planType: String? = "Test plan"
    var results: [Result<UsageSnapshot, UsageProviderError>]
    private(set) var calls = 0
    var suspend = false
    var onFetch: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ results: [Result<UsageSnapshot, UsageProviderError>]) {
        self.results = results
    }

    func fetchUsage() async throws -> UsageSnapshot {
        calls += 1
        guard !results.isEmpty else { throw UsageProviderError(message: "No stubbed result") }
        if suspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                onFetch?()
            }
        }
        return try results.removeFirst().get()
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecordingNotifier: UsageNotifying {
    struct Message {
        let title: String
        let body: String
    }
    private(set) var messages: [Message] = []
    private(set) var authorizationRequests = 0

    func requestAuthorization() async -> Bool? {
        authorizationRequests += 1
        return true
    }

    func send(title: String, body: String) {
        messages.append(Message(title: title, body: body))
    }
}
