import Foundation

/// Adapts Claude's response and display rules into provider-neutral rows and alert limits.
enum ClaudeUsageAdapter {
    static func snapshot(from response: ClaudeUsageResponse) -> UsageSnapshot {
        var sections: [UsageSection] = []
        var tracked: [TrackedUsageLimit] = []

        func track(_ id: String, _ name: UsageLabel, _ bucket: UsageBucket) {
            tracked.append(TrackedUsageLimit(id: id, name: name, bucket: bucket))
        }

        var session: [UsageRow] = []
        if let bucket = response.fiveHour, bucket.hasData {
            session.append(.quota(UsageQuotaRow(
                id: "five_hour", title: .localized("usage.current_session"),
                bucket: bucket, subtitle: .reset(.relative), windowDurationMinutes: 300
            )))
            track("five_hour", .localized("limit.current_session"), bucket)
        }
        // Keep the plan header even when all quotas are absent, as before.
        sections.append(UsageSection(
            id: "plan", title: .localized("section.plan_usage"), showsPlan: true, rows: session
        ))

        var weekly: [UsageRow] = []
        if let bucket = response.sevenDay, bucket.hasData {
            weekly.append(.quota(UsageQuotaRow(
                id: "seven_day", title: .localized("usage.all_models"),
                bucket: bucket, subtitle: .reset(.absolute), windowDurationMinutes: 10080
            )))
            track("seven_day", .localized("limit.weekly"), bucket)
        }
        if let bucket = response.sevenDaySonnet, bucket.hasData {
            weekly.append(.quota(UsageQuotaRow(
                id: "seven_day_sonnet", title: .localized("usage.sonnet_only"), bucket: bucket,
                subtitle: bucket.percent == 0 ? .text(.localized("usage.sonnet_not_used")) : .reset(.absolute),
                windowDurationMinutes: 10080
            )))
            track("seven_day_sonnet", .localized("limit.sonnet_weekly"), bucket)
        }
        if let bucket = response.sevenDayOpus, bucket.hasData {
            // Zero-usage Opus stays hidden in the UI, but must still participate in reset alerts.
            if bucket.percent > 0 {
                weekly.append(.quota(UsageQuotaRow(
                    id: "seven_day_opus", title: .localized("usage.opus_only"),
                    bucket: bucket, subtitle: .reset(.absolute), windowDurationMinutes: 10080
                )))
            }
            track("seven_day_opus", .localized("limit.opus_weekly"), bucket)
        }
        for limit in response.modelLimits {
            guard let name = limit.modelName else { continue }
            let id = "model:\(name.lowercased())"
            // Preserve Claude's dynamic-model handling, including a null percentage becoming 0.
            weekly.append(.quota(UsageQuotaRow(
                id: id, title: .formatted("usage.model_only", name),
                bucket: limit.bucket, subtitle: .reset(.absolute), windowDurationMinutes: 10080
            )))
            track(id, .formatted("limit.model_weekly", name), limit.bucket)
        }
        if !weekly.isEmpty {
            sections.append(UsageSection(id: "weekly", title: .localized("section.weekly"), rows: weekly))
        }

        if let credit = response.oneTimeCredit, credit.hasData {
            sections.append(UsageSection(
                id: "credits", title: .localized("section.credits"), rows: [
                    .quota(UsageQuotaRow(
                        id: "one_time_credit", title: .localized("usage.one_time_credit"),
                        bucket: credit, subtitle: .reset(.expires)
                    ))
                ]
            ))
        }

        if let extra = response.extraUsage {
            if extra.isVisible {
                let reason: UsageLabel?
                switch extra.disabledReason {
                case nil: reason = nil
                case let code?:
                    switch code {
                    case "org_level_disabled_until", "org_spend_cap_reached", "out_of_credits":
                        reason = .localized("usage.extra_disabled.\(code)")
                    default: reason = .localized("usage.extra_disabled.generic")
                    }
                }
                sections.append(UsageSection(
                    id: "extra_usage", title: .localized("section.extra_usage"), rows: [
                        .spending(UsageSpendingRow(
                            id: "extra_usage", usedAmount: (extra.usedCredits ?? 0) / 100,
                            limitAmount: extra.monthlyLimit.map { $0 / 100 }, currency: extra.currency,
                            percent: extra.percent, disabledReason: reason
                        ))
                    ]
                ))
            }
            if extra.isEnabled {
                track("extra_usage", .localized("limit.extra_usage"), UsageBucket(
                    utilization: Double(extra.percent), resetsAt: nil
                ))
            }
        }

        return UsageSnapshot(
            providerID: "claude", menuBarPercent: response.fiveHour?.percent,
            sections: sections, trackedLimits: tracked, providerName: "Claude"
        )
    }
}
