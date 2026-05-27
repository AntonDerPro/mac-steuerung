import SwiftUI
import UserNotifications

struct ContentView: View {
    @StateObject private var config = AgentConfig()
    @StateObject private var api: AgentAPI
    @State private var selectedTab = 0
    @State private var showSettings = false

    init() {
        let c = AgentConfig()
        _config = StateObject(wrappedValue: c)
        _api = StateObject(wrappedValue: AgentAPI(config: c))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            StatusView(showSettings: $showSettings)
                .tabItem { Label("Status", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(0)

            MediaView(showSettings: $showSettings)
                .tabItem { Label("Musik", systemImage: "music.note") }
                .tag(1)

            FileView(showSettings: $showSettings)
                .tabItem { Label("Dateien", systemImage: "folder") }
                .tag(2)

            AgentView(showSettings: $showSettings)
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag(3)

            ChatView(showSettings: $showSettings)
                .tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(4)
        }
        .environmentObject(config)
        .environmentObject(api)
        .tint(config.accentColor)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(config)
                .environmentObject(api)
        }
        .preferredColorScheme(config.preferredColorScheme)
        .onAppear {
            NotificationManager.shared.requestPermission()
            updateTabBarAppearance()
        }
        .onChange(of: config.colorSchemeRaw) { _, _ in updateTabBarAppearance() }
        .onChange(of: config.accentColorRaw) { _, _ in updateTabBarAppearance() }
    }

    private func updateTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
