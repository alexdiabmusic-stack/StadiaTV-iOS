import SwiftUI

@main
struct MyApp: App {
    @StateObject private var playlistStore = PlaylistStore()
    @StateObject private var preferences = PreferencesStore()
    @StateObject private var watchStore = WatchStore()
    @StateObject private var entitlements = EntitlementStore()
    @StateObject private var predictions = PredictionsStore()

    var body: some Scene {
        WindowGroup {
            Group {
                #if os(tvOS)
                if preferences.hasCompletedOnboarding {
                    TVRootView()
                } else {
                    TVOnboardingView()
                }
                #else
                if preferences.hasCompletedOnboarding {
                    RootView()
                } else {
                    OnboardingView()
                }
                #endif
            }
            .environmentObject(playlistStore)
            .environmentObject(preferences)
            .environmentObject(watchStore)
            .environmentObject(entitlements)
            .environmentObject(predictions)
            #if !os(tvOS)
            .dynamicTypeSize(Theme.isPad ? DynamicTypeSize.xLarge... : DynamicTypeSize.xSmall...)
            #endif
            .preferredColorScheme(preferences.appearance.colorScheme)
            .task { await playlistStore.refreshAll() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var showingFavoriteNotificationPrompt = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
            }

            Tab("Following", systemImage: "star.circle.fill") {
                MatchesView()
            }

            Tab("Live", systemImage: "dot.radiowaves.left.and.right") {
                LiveView()
            }

            Tab("Discover", systemImage: "safari.fill") {
                DiscoverView()
            }

            Tab("More", systemImage: "ellipsis.circle.fill") {
                MoreView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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
        #if os(tvOS)
        showingFavoriteNotificationPrompt = false
        #else
        showingFavoriteNotificationPrompt = prefs.shouldPromptForFavoriteTeamNotifications
        #endif
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
        .environmentObject(EntitlementStore())
        .environmentObject(PredictionsStore())
        .preferredColorScheme(.dark)
}
