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
    @StateObject private var channelPrefsStore = ChannelPreferencesStore()
    @StateObject private var customGroupStore = CustomGroupStore()
    @StateObject private var groupPrefsStore = GroupPreferencesStore()
    @StateObject private var fantasyStore = FantasyStore.shared
    @StateObject private var stadiaFantasyStore = StadiaFantasyStore.shared
    @StateObject private var launchCoordinator = StartupCoordinator()

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
            .environmentObject(channelPrefsStore)
            .environmentObject(customGroupStore)
            .environmentObject(groupPrefsStore)
            .environmentObject(fantasyStore)
            .environmentObject(stadiaFantasyStore)
            .environmentObject(ProgrammeReminderStore.shared)
            .environmentObject(RecordingService.shared)
            .environmentObject(ParentalControlStore.shared)
            .environmentObject(launchCoordinator)
            .task { channelPrefsStore.migrateLegacyFavorites(watchStore.favorites) }
            #if !os(tvOS)
            .dynamicTypeSize(Theme.isPad ? DynamicTypeSize.xLarge... : DynamicTypeSize.xSmall...)
            #endif
            .preferredColorScheme(preferences.appearance.colorScheme)
            // Channel refresh — parallel across all playlists (see PlaylistStore.refreshAll).
            .task { await playlistStore.refreshAll() }
            // Fantasy — load local state first, then refresh ESPN and event contexts concurrently.
            .task {
                await stadiaFantasyStore.load()
                async let espnRefresh: Void = fantasyStore.refresh(
                    channels: playlistStore.allChannels,
                    preferredLanguages: preferences.preferredStreamLanguages
                )
                async let eventContextRefresh: Void = stadiaFantasyStore.refreshEventContexts(
                    channels: playlistStore.allChannels,
                    preferredLanguages: preferences.preferredStreamLanguages
                )
                _ = await (espnRefresh, eventContextRefresh)
            }
            // Cold-launch brand animation — starts the visual sequence immediately.
            // The startup pipeline runs concurrently; `markAppShellReady()` is called
            // from HomeView once the first batch of data is available.
            .task { launchCoordinator.startBrandSequence() }
            // Overlay — present during every launch phase except `.home`.
            // Removed from the hierarchy once the transition is fully complete.
            #if !os(tvOS)
            .overlay {
                if launchCoordinator.phase != .home {
                    LaunchAnimationView()
                        .environmentObject(launchCoordinator)
                }
            }
            #endif
        }
    }
}

enum AppTab: String, Hashable {
    case home, following, live, discover, settings
}

struct RootView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var podcastStore: PodcastStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var stadiaFantasyStore: StadiaFantasyStore
    @StateObject private var liveViewModel = LiveViewModel()
    @StateObject private var epgRepository = EPGRepository()
    @StateObject private var guideStore = GuideChannelStore()
    @State private var showingFavoriteNotificationPrompt = false
    @State private var selectedTab: AppTab = .home

    // Applying safeAreaInset to each Tab's content (not the TabView) is the correct
    // way to place content between the tab content and the tab bar chrome.
    @ViewBuilder private var miniPlayerBar: some View {
        if podcastStore.nowPlaying != nil {
            PodcastMiniPlayer()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView(switchToFollowing: { selectedTab = .following })
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Following", systemImage: "star.circle.fill", value: AppTab.following) {
                MatchesView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Live", systemImage: "dot.radiowaves.left.and.right", value: AppTab.live) {
                LiveView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Discover", systemImage: "safari.fill", value: AppTab.discover) {
                DiscoverView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                MoreView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(Theme.accent)
        .environmentObject(liveViewModel)
        .environmentObject(epgRepository)
        .environmentObject(guideStore)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: podcastStore.nowPlaying != nil)
        .task { updateFavoriteNotificationPrompt() }
        .task { await liveViewModel.load(favoriteTeams: prefs.favoriteTeams) }
        .task { epgRepository.setupWithChannels(playlistStore.allChannels) }
        .onChange(of: playlistStore.channelsByPlaylist) {
            epgRepository.setupWithChannels(playlistStore.allChannels)
            Task { await refreshFantasyContexts(force: true) }
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

    private func refreshFantasyContexts(force: Bool = false) async {
        await stadiaFantasyStore.load()
        async let espnRefresh: Void = fantasyStore.refresh(
            channels: playlistStore.allChannels,
            preferredLanguages: prefs.preferredStreamLanguages,
            force: force
        )
        async let eventContextRefresh: Void = stadiaFantasyStore.refreshEventContexts(
            channels: playlistStore.allChannels,
            preferredLanguages: prefs.preferredStreamLanguages
        )
        _ = await (espnRefresh, eventContextRefresh)
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
        .environmentObject(FantasyStore.shared)
        .environmentObject(StadiaFantasyStore.shared)
        .environmentObject(StartupCoordinator())
        .preferredColorScheme(.dark)
}
