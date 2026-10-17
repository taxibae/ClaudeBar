import Foundation

/// Places windows by their reported length, not their primary/secondary slot, and never
/// invents a window the response does not contain.
enum CodexUsageAdapter {
    static let fiveHourMinutes = 300
    static let weeklyMinutes = 10080

    static func snapshot(from response: CodexUsageResponse) -> UsageSnapshot {
        let windows = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .filter { $0.usedPercent != nil }
        func window(minutes: Int) -> UsageBucket? {
            windows.first { $0.durationMinutes == minutes }?.bucket
        }

        var sections: [UsageSection] = []
        var tracked: [TrackedUsageLimit] = []
        func track(_ id: String, _ name: String, _ bucket: UsageBucket) {
            tracked.append(TrackedUsageLimit(
                id: id, name: .localized(name), bucket: bucket, resetBodyKey: "notification.codex_reset_body"
            ))
        }

        let fiveHour = window(minutes: fiveHourMinutes)
        var plan: [UsageRow] = []
        if let bucket = fiveHour {
            plan.append(.quota(UsageQuotaRow(
                id: "five_hour", title: .localized("usage.five_hour"),
                bucket: bucket, subtitle: .reset(.relative), windowDurationMinutes: fiveHourMinutes
            )))
            track("five_hour", "limit.codex_five_hour", bucket)
        }
        // The plan header stays even without a five-hour window, as for Claude.
        sections.append(UsageSection(
            id: "plan", title: .localized("section.codex_plan_usage"), showsPlan: true, rows: plan
        ))

        if let bucket = window(minutes: weeklyMinutes) {
            sections.append(UsageSection(id: "weekly", title: .localized("section.weekly"), rows: [
                .quota(UsageQuotaRow(
                    id: "weekly", title: .localized("usage.weekly"),
                    bucket: bucket, subtitle: .reset(.absolute), windowDurationMinutes: weeklyMinutes
                ))
            ]))
            track("weekly", "limit.codex_weekly", bucket)
        }

        return UsageSnapshot(
            providerID: "codex", menuBarPercent: fiveHour?.percent,
            sections: sections, trackedLimits: tracked
        )
    }

    /// "plus" → "Plus"; unknown or empty values show no badge
    static func planBadge(_ planType: String?) -> String? {
        guard let planType, !planType.isEmpty, planType != "unknown" else { return nil }
        return planType.capitalized
    }
}
