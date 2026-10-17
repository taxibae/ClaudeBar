import Foundation

/// Application state, preferences, polling and alerts over an injected usage provider.
@MainActor
@Observable
final class UsageService {

    // MARK: - Public State

    private(set) var usage: UsageSnapshot?
    private(set) var error: String?
    private(set) var lastUpdate: Date?
    private(set) var isLoading = false
    private(set) var planType: String?
    private(set) var languageRefreshID = 0
    /// Kullanıcı bildirim iznini reddettiyse true; ayarlar panelinde uyarı gösterilir
    private(set) var notificationsDenied = false

    // MARK: - Settings (persisted)

    var showPercentage: Bool {
        didSet { defaults.set(showPercentage, forKey: "showPercentage") }
    }

    var refreshInterval: Int {
        didSet {
            defaults.set(refreshInterval, forKey: "refreshInterval")
            restartPolling()
        }
    }

    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: "appLanguage")
            invalidateBundleCache()
            languageRefreshID += 1
        }
    }

    // MARK: - Notification Settings (persisted)

    var notifyAt50: Bool {
        didSet { defaults.set(notifyAt50, forKey: "notifyAt50") }
    }

    var notifyAt75: Bool {
        didSet { defaults.set(notifyAt75, forKey: "notifyAt75") }
    }

    var notifyAt100: Bool {
        didSet { defaults.set(notifyAt100, forKey: "notifyAt100") }
    }

    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: "notifyOnReset") }
    }

    // MARK: - Dependencies

    private let provider: any UsageProvider
    private let notifier: any UsageNotifying
    private let defaults: UserDefaults
    private let startsAutomatically: Bool
    /// Kova anahtarı → son görülen durum; eşik geçişleri buradan hesaplanır
    private var previous: [String: BucketSnapshot] = [:]
    private var timer: Timer?

    // MARK: - Lifecycle

    init(provider: any UsageProvider, notifier: any UsageNotifying,
         defaults: UserDefaults = .standard, startsAutomatically: Bool = true) {
        self.provider = provider
        self.notifier = notifier
        self.defaults = defaults
        self.startsAutomatically = startsAutomatically
        showPercentage = defaults.object(forKey: "showPercentage") as? Bool ?? true
        refreshInterval = defaults.object(forKey: "refreshInterval") as? Int ?? 60
        notifyAt50 = defaults.object(forKey: "notifyAt50") as? Bool ?? true
        notifyAt75 = defaults.object(forKey: "notifyAt75") as? Bool ?? true
        notifyAt100 = defaults.object(forKey: "notifyAt100") as? Bool ?? true
        notifyOnReset = defaults.object(forKey: "notifyOnReset") as? Bool ?? false
        let langRaw = defaults.string(forKey: "appLanguage") ?? "system"
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system

        guard startsAutomatically else { return }

        Task { [weak self] in
            guard let self else { return }
            if let granted = await notifier.requestAuthorization() {
                notificationsDenied = !granted
            }
        }
        Task { await refresh() }
        startPolling()
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
        }
    }

    // MARK: - Public Methods

    /// Refresh using the selected provider strategy, retaining the last successful data on failure.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            planType = provider.planType
        }
        do {
            let snapshot = try await provider.fetchUsage()
            notifyThresholds(for: snapshot)
            usage = snapshot
            error = nil
            lastUpdate = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Polling

    private func startPolling() {
        guard startsAutomatically else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval), repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private func restartPolling() {
        timer?.invalidate()
        startPolling()
    }

    // MARK: - Notifications

    func sendTestNotification() {
        let resetTime = L("time.hours_minutes", 2, 34)

        notifier.send(title: L("notification.50_title"), body: L("notification.test_50_body"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.notifier.send(title: L("notification.75_title"), body: L("notification.test_75_body"))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.notifier.send(title: L("notification.limit_title"), body: L("notification.test_limit_body", resetTime))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.notifier.send(title: L("notification.reset_title"), body: L("notification.test_reset_body"))
        }
    }

    /// Each provider supplies its own tracked limits; the threshold rules stay shared.
    private func notifyThresholds(for new: UsageSnapshot) {
        let settings = ThresholdSettings(at50: notifyAt50, at75: notifyAt75, at100: notifyAt100, onReset: notifyOnReset)

        var next: [String: BucketSnapshot] = [:]
        for item in new.trackedLimits {
            let key = "\(new.providerID):\(item.id)"
            let snapshot = BucketSnapshot(percent: item.bucket.percent, resetsAt: item.bucket.resetsAt)
            let events = UsageThresholds.events(previous: previous[key], current: snapshot, settings: settings)
            for event in events {
                deliver(event, limitName: item.name.text, bucket: item.bucket)
            }
            next[key] = snapshot
        }
        previous = next
    }

    private func deliver(_ event: UsageEvent, limitName: String, bucket: UsageBucket) {
        switch event {
        case .reached50:
            notifier.send(title: L("notification.50_title"), body: L("notification.50_body", limitName))
        case .reached75:
            notifier.send(title: L("notification.75_title"), body: L("notification.75_body", limitName))
        case .limitReached:
            let body: String
            if let remaining = bucket.remainingText() {
                body = L("notification.limit_body_resets", limitName, remaining)
            } else {
                body = L("notification.limit_body", limitName)
            }
            notifier.send(title: L("notification.limit_title"), body: body)
        case .reset:
            notifier.send(title: L("notification.reset_title"), body: L("notification.reset_body", limitName))
        }
    }
}
