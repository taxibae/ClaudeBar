import SwiftUI

struct UsageContentView: View {
    let usage: UsageSnapshot
    let planType: String?

    private func barColor(for percent: Int) -> Color {
        switch percent {
        case 0..<50: return .green
        case 50..<75: return .yellow
        case 75..<100: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(usage.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 { divider }
                sectionHeader(section.title.text, showPlan: section.showsPlan)
                ForEach(section.rows) { row in
                    switch row {
                    case .quota(let quota):
                        usageRow(title: quota.title.text, subtitle: quota.subtitleText(), bucket: quota.bucket)
                    case .spending(let spending):
                        extraUsageRow(spending)
                    }
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, showPlan: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if showPlan, let plan = planType {
                planBadge(plan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Plan Badge

    private func planBadge(_ plan: String) -> some View {
        Text(L("plan.badge", plan))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor)
            .clipShape(Capsule())
    }

    // MARK: - Usage Row

    private func usageRow(title: String, subtitle: String?, bucket: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .frame(width: 100, alignment: .leading)

                progressBar(percent: bucket.percent)

                Text(L("usage.percent_used", bucket.percent))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Extra Usage Row

    private func extraUsageRow(_ extra: UsageSpendingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L("usage.spent", extra.usedAmountText))
                    .font(.system(size: 13))
                    .frame(width: 100, alignment: .leading)

                progressBar(percent: extra.percent)

                Text(L("usage.percent_used", extra.percent))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // Kapatılmışsa gerekçe, açıksa sıfırlanma tarihi ve limit
            Text(extra.disabledReason?.text ?? L("usage.resets_limit", extra.resetDateText(), extra.limitAmountText))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Progress Bar

    private func progressBar(percent: Int) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 4)
                    .fill(barColor(for: percent))
                    .frame(width: max(4, geo.size.width * CGFloat(min(percent, 100)) / 100))
            }
        }
        .frame(height: 8)
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

}
