import SwiftUI

@main
struct MyApp: App {
    @StateObject private var playlistStore = PlaylistStore()
    @StateObject private var preferences = PreferencesStore()
    @StateObject private var watchStore = WatchStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if preferences.hasCompletedOnboarding {
                    RootView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(playlistStore)
            .environmentObject(preferences)
            .environmentObject(watchStore)
            .preferredColorScheme(.dark)
            .task { await playlistStore.refreshAll() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var showingFavoriteNotificationPrompt = false

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            LiveTVView()
                .tabItem { Label("Live TV", systemImage: "play.tv.fill") }

            MatchesView()
                .tabItem { Label("Sports", systemImage: "sportscourt.fill") }

            NewsView()
                .tabItem { Label("News", systemImage: "newspaper.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .task { updateFavoriteNotificationPrompt() }
        .onChange(of: prefs.favoriteTeams) { updateFavoriteNotificationPrompt() }
        .onChange(of: prefs.matchNotificationsEnabled) { updateFavoriteNotificationPrompt() }
        .alert("Get notified before your favourite teams play?", isPresented: $showingFavoriteNotificationPrompt) {
            Button("Not Now", role: .cancel) {
                prefs.markFavoriteTeamNotificationPromptAnswered()
            }
            Button("Enable Notifications") {
                Task { await enableFavoriteTeamNotifications() }
            }
        } message: {
            Text("StadiaTV can remind you before games for teams you star. You can change this later in Settings.")
        }
    }

    private func updateFavoriteNotificationPrompt() {
        showingFavoriteNotificationPrompt = prefs.shouldPromptForFavoriteTeamNotifications
    }

    private func enableFavoriteTeamNotifications() async {
        prefs.markFavoriteTeamNotificationPromptAnswered()
        let granted = await MatchNotificationService.shared.requestAuthorization()
        prefs.setMatchNotificationsEnabled(granted)
    }
}

#Preview {
    RootView()
        .environmentObject(PlaylistStore())
        .environmentObject(PreferencesStore())
        .environmentObject(WatchStore())
        .preferredColorScheme(.dark)
}
