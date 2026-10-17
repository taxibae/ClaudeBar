import Foundation

/// Strategy boundary: the application never needs a provider's credentials or wire response.
/// Implementations keep the last known plan even when a subsequent fetch fails.
@MainActor
protocol UsageProvider: AnyObject {
    var planType: String? { get }
    func fetchUsage() async throws -> UsageSnapshot
}

struct UsageProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Resolve text at display time so changing the app language does not require a new fetch.
enum UsageLabel: Equatable, Sendable {
    case localized(String)
    case formatted(String, String)
    case literal(String)

    var text: String {
        switch self {
        case .localized(let key): return L(key)
        case .formatted(let key, let argument): return L(key, argument)
        case .literal(let value): return value
        }
    }
}

/// Provider-neutral presentation and notification data, independent of API field names.
struct UsageSnapshot: Equatable, Sendable {
    let providerID: String
    let menuBarPercent: Int?
    let sections: [UsageSection]
    let trackedLimits: [TrackedUsageLimit]
}

struct UsageSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: UsageLabel
    var showsPlan = false
    let rows: [UsageRow]
}

enum UsageRow: Identifiable, Equatable, Sendable {
    case quota(UsageQuotaRow)
    case spending(UsageSpendingRow)

    var id: String {
        switch self {
        case .quota(let row): return row.id
        case .spending(let row): return row.id
        }
    }
}

struct UsageQuotaRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: UsageLabel
    let bucket: UsageBucket
    let subtitle: UsageSubtitle
    var windowDurationMinutes: Int? = nil

    func subtitleText(now: Date = Date()) -> String? {
        switch subtitle {
        case .reset(let style): return bucket.resetText(style: style, now: now)
        case .text(let label): return label.text
        }
    }
}

enum UsageSubtitle: Equatable, Sendable {
    case reset(UsageBucket.ResetStyle)
    case text(UsageLabel)
}

/// Monetary display data, already converted from the provider's units and reason codes.
struct UsageSpendingRow: Identifiable, Equatable, Sendable {
    let id: String
    let usedAmount: Double
    let limitAmount: Double?
    let currency: String?
    let percent: Int
    let disabledReason: UsageLabel?

    var usedAmountText: String {
        Money.format(amount: usedAmount, currency: currency, fractionDigits: 2)
    }

    var limitAmountText: String {
        guard let limitAmount else { return L("usage.unlimited") }
        return Money.format(amount: limitAmount, currency: currency, fractionDigits: 0)
    }

    func resetDateText(now: Date = Date()) -> String {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month], from: now)
        guard let month = components.month else { return L("usage.next_month") }
        components.month = month + 1
        components.day = 1
        guard let nextMonth = calendar.date(from: components) else { return L("usage.next_month") }
        let formatter = DateFormatter()
        formatter.locale = activeLocale()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: nextMonth)
    }
}

struct TrackedUsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let name: UsageLabel
    let bucket: UsageBucket
}
