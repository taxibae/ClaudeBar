import Foundation

enum UsageTab: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

/// A provider's last successful result survives subsequent fetch failures.
@MainActor
@Observable
final class ProviderUsageState {
    private(set) var usage: UsageSnapshot?
    private(set) var error: String?
    private(set) var lastUpdate: Date?
    private(set) var isLoading = false
    private(set) var planType: String?

    private let provider: any UsageProvider

    init(provider: any UsageProvider) {
        self.provider = provider
    }

    func refresh() async -> UsageSnapshot? {
        guard !isLoading else { return nil }
        isLoading = true
        defer {
            isLoading = false
            planType = provider.planType
        }
        do {
            let snapshot = try await provider.fetchUsage()
            usage = snapshot
            error = nil
            lastUpdate = Date()
            return snapshot
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
