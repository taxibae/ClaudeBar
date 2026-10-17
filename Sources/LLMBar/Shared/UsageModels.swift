import Foundation

/// Kullanım kovası. utilization null gelebilir (örneğin planın o penceresi yoksa);
/// bu durumda hasData false olur ve satır gizlenir.
struct UsageBucket: Codable, Equatable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double?, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    var hasData: Bool { utilization != nil }

    /// Kullanım yüzdesi (0-100), veri yoksa 0
    var percent: Int {
        Int((utilization ?? 0).rounded())
    }

    var resetDate: Date? {
        ISO8601.parse(resetsAt)
    }

    /// Süre kalmadıysa nil döner; "Resets in 3 hr 56 min" veya "Resets Sat 9:59 AM"
    func resetText(style: ResetStyle, now: Date = Date()) -> String? {
        guard let target = resetDate, target > now else { return nil }

        switch style {
        case .relative:
            let (hours, minutes) = Self.split(seconds: target.timeIntervalSince(now))
            if hours > 0 {
                return L("reset.in_hours_minutes", hours, minutes)
            }
            return L("reset.in_minutes", minutes)

        case .absolute:
            return L("reset.at", Self.absoluteText(for: target))

        case .expires:
            return L("usage.expires", Self.absoluteText(for: target))
        }
    }

    /// Bildirim gövdesi için yalnızca kalan süre: "2 hr 34 min"
    func remainingText(now: Date = Date()) -> String? {
        guard let target = resetDate, target > now else { return nil }
        let (hours, minutes) = Self.split(seconds: target.timeIntervalSince(now))
        if hours > 0 {
            return L("time.hours_minutes", hours, minutes)
        }
        return L("time.minutes", minutes)
    }

    private static func split(seconds: TimeInterval) -> (hours: Int, minutes: Int) {
        let total = Int(seconds)
        return (total / 3600, (total % 3600) / 60)
    }

    /// "Sat 9:59 AM" biçimi; 59. dakika sunucunun yuvarlama artığıdır, tam saate çekilir
    private static func absoluteText(for target: Date) -> String {
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: target)
        let rounded = minute >= 59
            ? (calendar.date(byAdding: .minute, value: 1, to: target) ?? target)
            : target

        let locale = activeLocale()
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE")
        return "\(dayFormatter.string(from: rounded)) \(timeFormatter.string(from: rounded))"
    }

    enum ResetStyle: Equatable, Sendable {
        case relative   // "Resets in 3 hr 56 min"
        case absolute   // "Resets Sat 9:59 AM"
        case expires    // "Expires Sat 9:59 AM" (tek seferlik kredi)
    }
}

// MARK: - Helpers

/// Sunucu tarihleri bazen kesirli saniyeli, bazen düz ISO 8601 gelir; ikisini de kabul et
enum ISO8601 {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

/// Cent cinsinden tutarı seçili dilin para biçimiyle yazar; para birimi gelmezse USD varsayılır
enum Money {
    static func format(cents: Double, currency: String?, fractionDigits: Int) -> String {
        format(amount: cents / 100, currency: currency, fractionDigits: fractionDigits)
    }

    static func format(amount: Double, currency: String?, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = activeLocale()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency?.uppercased() ?? "USD"
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}
