import SwiftUI

/// Menu bar application for monitoring Claude usage limits
@main
struct LLMBarApp: App {
    @State private var service = UsageService(
        provider: ClaudeUsageProvider(), notifier: Notifier(), codexProvider: CodexUsageProvider()
    )
    
    var body: some Scene {
        MenuBarExtra {
            UsageView()
                .environment(service)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }
    
    /// Each provider's five-hour usage, e.g. "C12% G10%"; the gauge icon only while there is none
    @ViewBuilder
    private var menuBarLabel: some View {
        if let text = service.menuBarText {
            Text(text)
                .font(.caption2)
                .monospacedDigit()
        } else {
            Image(systemName: "gauge.medium")
        }
    }
}
