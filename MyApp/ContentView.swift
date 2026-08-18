import SwiftUI

@main
struct MyApp: App {
    @StateObject private var playlistStore = PlaylistStore()
    @StateObject private var preferences = PreferencesStore()
    @StateObject private var watchStore = WatchStore()
    @StateObject private var entitlements = EntitlementStore()
    @StateObject private var predictions = PredictionsStore()
    @StateObject private var articleLibrary = ArticleLibraryStore()
    @StateObject private var podcastStore = PodcastStore()

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
            .environmentObject(articleLibrary)
            .environmentObject(podcastStore)
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
    @EnvironmentObject private var podcastStore: PodcastStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @StateObject private var liveViewModel = LiveViewModel()
    @StateObject private var epgRepository = EPGRepository()
    @State private var showingFavoriteNotificationPrompt = false

    // Applying safeAreaInset to each Tab's content (not the TabView) is the correct
    // way to place content between the tab content and the tab bar chrome.
    @ViewBuilder private var miniPlayerBar: some View {
        if podcastStore.nowPlaying != nil {
            PodcastMiniPlayer()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Following", systemImage: "star.circle.fill") {
                MatchesView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Live", systemImage: "dot.radiowaves.left.and.right") {
                LiveView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Discover", systemImage: "safari.fill") {
                DiscoverView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                MoreView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(Theme.accent)
        .environmentObject(liveViewModel)
        .environmentObject(epgRepository)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: podcastStore.nowPlaying != nil)
        .task { updateFavoriteNotificationPrompt() }
        .task { await liveViewModel.load(favoriteTeams: prefs.favoriteTeams) }
        .task { epgRepository.setupWithChannels(playlistStore.allChannels) }
        .onChange(of: playlistStore.channelsByPlaylist) {
            epgRepository.setupWithChannels(playlistStore.allChannels)
        }
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
        .environmentObject(ArticleLibraryStore())
        .environmentObject(PodcastStore())
        .preferredColorScheme(.dark)
}
