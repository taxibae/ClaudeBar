import Foundation

/// Local data for exercising the provider tabs before Codex integration.
@MainActor
final class CodexSampleUsageProvider: UsageProvider {
    let planType: String? = "Plus"
    private let snapshot: UsageSnapshot

    init(now: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        func quota(_ id: String, _ title: String, _ percent: Double,
                   _ minutes: Int, _ style: UsageBucket.ResetStyle) -> UsageRow {
            .quota(UsageQuotaRow(
                id: id, title: .localized(title),
                bucket: UsageBucket(utilization: percent, resetsAt: formatter.string(
                    from: now.addingTimeInterval(Double(minutes) * 60)
                )),
                subtitle: .reset(style), windowDurationMinutes: minutes
            ))
        }
        snapshot = UsageSnapshot(
            providerID: "codex", menuBarPercent: 32,
            sections: [
                UsageSection(id: "plan", title: .localized("section.plan_usage"), showsPlan: true, rows: [
                    quota("five_hour", "usage.current_session", 32, 300, .relative)
                ]),
                UsageSection(id: "weekly", title: .localized("section.weekly"), rows: [
                    quota("seven_day", "usage.all_models", 58, 10080, .absolute),
                    quota("seven_day_sonnet", "usage.sonnet_only", 21, 10080, .absolute),
                    quota("seven_day_opus", "usage.opus_only", 12, 10080, .absolute)
                ]),
                UsageSection(id: "credits", title: .localized("section.credits"), rows: [
                    quota("one_time_credit", "usage.one_time_credit", 15, 43200, .expires)
                ]),
                UsageSection(id: "extra_usage", title: .localized("section.extra_usage"), rows: [
                    .spending(UsageSpendingRow(
                        id: "extra_usage", usedAmount: 4, limitAmount: 20,
                        currency: "USD", percent: 20, disabledReason: nil
                    ))
                ])
            ], trackedLimits: []
        )
    }

    func fetchUsage() async throws -> UsageSnapshot { snapshot }
}
