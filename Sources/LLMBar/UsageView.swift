import SwiftUI
import ServiceManagement

/// Menü çubuğu penceresi: kullanım limitleri, ayarlar ve hakkında panelleri
struct UsageView: View {
    @Environment(UsageService.self) private var service
    @State private var showSettings = false
    @State private var showAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: Binding(
                get: { service.selectedTab },
                set: { service.selectedTab = $0 }
            )) {
                ForEach(UsageTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if let usage = service.selectedState.usage {
                UsageContentView(usage: usage, planType: service.selectedState.planType)
            } else if let error = service.selectedState.error {
                errorView(error)
            } else {
                loadingView
            }

            divider

            if showSettings {
                settingsPanel
                divider
            }

            if showAbout {
                aboutPanel
                divider
            }

            footer
        }
        .frame(minWidth: 340, idealWidth: 340)
        .fixedSize(horizontal: true, vertical: false)
        .id(service.languageRefreshID)
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    // MARK: - About Panel

    private var versionText: String {
        // Paket dışında (swift run) Info.plist yoktur; "dev" göstermek yanlış sürüm göstermekten iyidir
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "dev")"
    }

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("about.title"))
                .font(.system(size: 13, weight: .semibold))

            Text(L("about.description"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("about.created_by"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let url = URL(string: "https://github.com/kemalasliyuksek") {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10))
                            Text("Kemal Aslıyüksek")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 12) {
                if let url = URL(string: "https://github.com/taxibae/ClaudeBar") {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                            Text(L("about.github"))
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if let url = URL(string: "https://github.com/taxibae/ClaudeBar/issues") {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.system(size: 10))
                            Text(L("about.report_issue"))
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(versionText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("settings.title"))
                .font(.system(size: 13, weight: .semibold))

            SettingsRow(title: L("settings.launch_at_login")) {
                Toggle("", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { newValue in
                        try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingsRow(title: L("settings.show_percentage")) {
                Toggle("", isOn: Binding(
                    get: { service.showPercentage },
                    set: { service.showPercentage = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingsRow(title: L("settings.language")) {
                Picker("", selection: Binding(
                    get: { service.appLanguage },
                    set: { service.appLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            SettingsRow(title: L("settings.refresh_interval")) {
                Picker("", selection: Binding(
                    get: { service.refreshInterval },
                    set: { service.refreshInterval = $0 }
                )) {
                    Text(L("interval.30s")).tag(30)
                    Text(L("interval.1m")).tag(60)
                    Text(L("interval.2m")).tag(120)
                    Text(L("interval.5m")).tag(300)
                }
                .pickerStyle(.menu)
                .frame(width: 70)
            }

            Divider()
                .padding(.vertical, 2)

            HStack {
                Text(L("settings.notifications"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(L("settings.test")) {
                    service.sendTestNotification()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if service.notificationsDenied {
                Text(L("settings.notifications_denied"))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            SettingsRow(title: L("settings.notify_50")) {
                Toggle("", isOn: Binding(
                    get: { service.notifyAt50 },
                    set: { service.notifyAt50 = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingsRow(title: L("settings.notify_75")) {
                Toggle("", isOn: Binding(
                    get: { service.notifyAt75 },
                    set: { service.notifyAt75 = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingsRow(title: L("settings.notify_limit")) {
                Toggle("", isOn: Binding(
                    get: { service.notifyAt100 },
                    set: { service.notifyAt100 = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingsRow(title: L("settings.notify_reset")) {
                Toggle("", isOn: Binding(
                    get: { service.notifyOnReset },
                    set: { service.notifyOnReset = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let date = service.selectedState.lastUpdate {
                Text(L("footer.last_updated", relativeTime(from: date)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAbout.toggle()
                    if showAbout { showSettings = false }
                }
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showAbout ? .primary : .secondary)
            .focusable(false)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettings.toggle()
                    if showSettings { showAbout = false }
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showSettings ? .primary : .secondary)
            .focusable(false)

            Button {
                Task { await service.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .focusable(false)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .focusable(false)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return L("footer.less_than_minute")
        } else if seconds < 3600 {
            let mins = seconds / 60
            let key = mins == 1 ? "footer.minute_ago" : "footer.minutes_ago"
            return L(key, mins)
        } else {
            let hrs = seconds / 3600
            let key = hrs == 1 ? "footer.hour_ago" : "footer.hours_ago"
            return L(key, hrs)
        }
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("loading"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func errorView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(20)
    }
}

// MARK: - Settings Row

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            content()
        }
    }
}
