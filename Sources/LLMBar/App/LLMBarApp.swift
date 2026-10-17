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
    
    /// Menu bar icon with current session usage percentage
    private var menuBarLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.medium")
            
            if service.showPercentage, let percent = service.usage?.menuBarPercent {
                Text("\(percent)%")
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
    }
}
