import SwiftUI

@main
struct MyApp: App {
    // Sourced from BannerAppEnvironment.shared so CarPlay (a separate scene with no
    // SwiftUI environment of its own) reads/drives the same instances instead of
    // duplicating stores or polling loops. See BannerAppEnvironment.swift.
    @StateObject private var playlistStore = BannerAppEnvironment.shared.playlistStore
    @StateObject private var preferences = BannerAppEnvironment.shared.preferences
    @StateObject private var podcastStore = BannerAppEnvironment.shared.podcastStore
    @StateObject private var epgRepository = BannerAppEnvironment.shared.epgRepository
    @StateObject private var guideStore = BannerAppEnvironment.shared.guideStore
    @StateObject private var streamStore = BannerAppEnvironment.shared.streamStore
    @StateObject private var eventChannelRefresh = BannerAppEnvironment.shared.eventChannelRefresh
    // WatchStore forwards favourites to the channel preferences store, so `init` builds them together.
    @StateObject private var watchStore: WatchStore
    @StateObject private var entitlements = EntitlementStore()
    @StateObject private var predictions = PredictionsStore()
    @StateObject private var articleLibrary = ArticleLibraryStore()
    @StateObject private var channelPrefsStore: ChannelPreferencesStore
    @StateObject private var customGroupStore = CustomGroupStore()
    @StateObject private var groupPrefsStore = GroupPreferencesStore()
    @StateObject private var fantasyStore = FantasyStore.shared
    @StateObject private var bannerFantasyStore = BannerFantasyStore.shared
    @StateObject private var launchCoordinator = StartupCoordinator()

    init() {
        // WatchStore forwards favourites to the channel preferences store, so build them together.
        let channelPrefs = ChannelPreferencesStore()
        _channelPrefsStore = StateObject(wrappedValue: channelPrefs)
        _watchStore = StateObject(wrappedValue: WatchStore(channelPreferences: channelPrefs))
        PlaybackPriority.launchDate = Date()
        AudioSessionManager.configureAtLaunch()
        LegacyFeatureCleanup.runIfNeeded()
        // Registers the notification delegate now so a tap that launches the app is delivered.
        _ = MatchNotificationService.shared
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG || GUIDEBENCHMARK
            if let guideBenchmarkDirectory = GuideBenchmark.requestedDirectory {
                GuideBenchmarkRunnerView(directory: guideBenchmarkDirectory)
            } else {
                normalContent
            }
            #else
            normalContent
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        .commands { MacCommands() }
        #endif
        #if os(macOS)
        Settings {
            MoreView()
                .environmentObject(playlistStore)
                .environmentObject(preferences)
                .environmentObject(watchStore)
                .environmentObject(entitlements)
                .environmentObject(predictions)
                .environmentObject(articleLibrary)
                .environmentObject(podcastStore)
                .environmentObject(epgRepository)
                .environmentObject(guideStore)
                .environmentObject(streamStore)
                .environmentObject(eventChannelRefresh)
                .environmentObject(BannerAppEnvironment.shared)
                .environmentObject(channelPrefsStore)
                .environmentObject(customGroupStore)
                .environmentObject(groupPrefsStore)
                .environmentObject(fantasyStore)
                .environmentObject(bannerFantasyStore)
                .environmentObject(ProgrammeReminderStore.shared)
                .environmentObject(launchCoordinator)
                .frame(minWidth: 480, minHeight: 420)
        }
        #endif
    }

    @ViewBuilder
    private var normalContent: some View {
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
            .environmentObject(epgRepository)
            .environmentObject(guideStore)
            .environmentObject(streamStore)
            .environmentObject(eventChannelRefresh)
            .environmentObject(BannerAppEnvironment.shared)
            .environmentObject(channelPrefsStore)
            .environmentObject(customGroupStore)
            .environmentObject(groupPrefsStore)
            .environmentObject(fantasyStore)
            .environmentObject(bannerFantasyStore)
            .environmentObject(ProgrammeReminderStore.shared)
            .environmentObject(launchCoordinator)
            .onOpenURL { url in
                if let link = DeepLink(url: url) { DeepLinkRouter.shared.handle(link) }
            }
            #if !os(tvOS)
            .dynamicTypeSize(Theme.isPad ? DynamicTypeSize.xLarge... : DynamicTypeSize.xSmall...)
            #endif
            .preferredColorScheme(preferences.appearance.colorScheme)
            // Channel refresh — parallel across all playlists (see PlaylistStore.refreshAll).
            .task { await playlistStore.refreshAll() }
            // Fantasy — load local state first, then refresh ESPN and event contexts concurrently.
            .task(priority: .utility) {
                await bannerFantasyStore.load()
                // Not needed for the first screen; don't compete with launch or the first stream.
                await PlaybackPriority.waitForBackgroundSlot()
                async let espnRefresh: Void = fantasyStore.refresh(
                    channels: playlistStore.allChannels,
                    preferredLanguages: preferences.preferredStreamLanguages
                )
                // No epgRepository/streamStore yet at this point — RootView, which owns them,
                // hasn't been created. This early pass just warms the schedule/roster data;
                // RootView's own forced refresh (onAppear) fills in matchedChannel.
                async let eventContextRefresh: Void = bannerFantasyStore.refreshEventContexts(
                    channels: playlistStore.allChannels,
                    preferredLanguages: preferences.preferredStreamLanguages
                )
                _ = await (espnRefresh, eventContextRefresh)
            }
            .onOpenURL { url in
                if let link = BannerDeepLink(url: url) {
                    BannerAppEnvironment.shared.pendingDeepLink = link
                }
            }
            // Cold-launch brand animation — starts the visual sequence immediately.
            // The startup pipeline runs concurrently; `markAppShellReady()` is called
            // from HomeView once the first batch of data is available.
            .task { launchCoordinator.startBrandSequence() }
            // Overlay — present during every launch phase except `.home`.
            // Removed from the hierarchy once the transition is fully complete.
            #if os(iOS)
            .overlay {
                if launchCoordinator.phase != .home {
                    LaunchAnimationView()
                        .environmentObject(launchCoordinator)
                }
            }
            #endif
        }
    }

enum AppTab: String, Hashable {

    case home, following, live, discover, settings
}

struct RootView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var podcastStore: PodcastStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @StateObject private var liveViewModel = LiveViewModel()
    @EnvironmentObject private var epgRepository: EPGRepository
    @EnvironmentObject private var guideStore: GuideChannelStore
    @EnvironmentObject private var streamStore: StreamAvailabilityStore
    @EnvironmentObject private var eventChannelRefresh: EventChannelRefreshService
    @EnvironmentObject private var appEnvironment: BannerAppEnvironment
    @State private var showingFavoriteNotificationPrompt = false
    @State private var selectedTab: AppTab = .home
    // `banner://game/{eventID}` links from CarPlay, Live Activities and Siri (see BannerAppEnvironment).
    @State private var deepLinkMatch: Match?
    // Notification taps and `banner://` tab/match links, which carry the league and date (see DeepLink).
    @ObservedObject private var deepLinks = DeepLinkRouter.shared
    @State private var notificationMatch: DeepLinkMatchTarget?

    // Applying safeAreaInset to each Tab's content (not the TabView) is the correct
    // way to place content between the tab content and the tab bar chrome.
    @ViewBuilder private var miniPlayerBar: some View {
        if podcastStore.nowPlaying != nil {
            PodcastMiniPlayer()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    #if os(macOS)
    /// Native Mac sidebar + detail shell. `selectedTab` stays non-optional (shared with
    /// iOS/iPadOS and with `appEnvironment.requestedTab` elsewhere in this file), so the
    /// sidebar `List` selection binding bridges it to the `Optional` it expects.
    private var macSidebarSelection: Binding<AppTab?> {
        Binding(get: { selectedTab }, set: { if let newValue = $0 { selectedTab = newValue } })
    }

    @ViewBuilder
    private func macSidebarRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Theme.Mac.Sidebar.iconLabelGap) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.Mac.Sidebar.iconSize))
                .frame(width: Theme.Mac.Sidebar.iconSize, alignment: .center)
            Text(title)
                .font(.system(size: Theme.Mac.Sidebar.labelSize, weight: .medium))
        }
        .padding(.horizontal, Theme.Mac.Sidebar.horizontalPadding)
        .frame(height: Theme.Mac.Sidebar.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
    }

    private var macNavigationBody: some View {
        NavigationSplitView {
            List(selection: macSidebarSelection) {
                macSidebarRow("Home", systemImage: "house.fill").tag(AppTab.home)
                macSidebarRow("Following", systemImage: "star.fill").tag(AppTab.following)
                macSidebarRow("Live", systemImage: "dot.radiowaves.left.and.right").tag(AppTab.live)
                macSidebarRow("Discover", systemImage: "safari.fill").tag(AppTab.discover)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 188, ideal: Theme.Mac.Sidebar.width)
        } detail: {
            macDetailContent
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
        }
    }

    @ViewBuilder
    private var macDetailContent: some View {
        switch selectedTab {
        case .home: HomeView(switchToFollowing: { selectedTab = .following })
        case .following: MatchesView()
        case .live: LiveView()
        case .discover: DiscoverView()
        case .settings: MoreView()
        }
    }
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            macNavigationBody
            #else
            TabView(selection: $selectedTab) {
                Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                    HomeView(switchToFollowing: { selectedTab = .following })
                        .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
                }
                Tab("Following", systemImage: "star.fill", value: AppTab.following) {
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
            #endif
        }
        .tint(Theme.accent)
        .environmentObject(liveViewModel)
        .environmentObject(epgRepository)
        .environment(\.playerStores, PlayerStoreReferences(playlistStore: playlistStore, epgRepository: epgRepository, streamStore: streamStore))
        .environmentObject(guideStore)
        .environmentObject(streamStore)
        .environmentObject(eventChannelRefresh)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: podcastStore.nowPlaying != nil)
        .task { updateFavoriteNotificationPrompt() }
        .appOrchestration(
            liveViewModel: liveViewModel,
            epgRepository: epgRepository,
            streamStore: streamStore,
            eventChannelRefresh: eventChannelRefresh
        )
        .onChange(of: liveViewModel.allLive) { _, live in updateLiveActivity(live) }
        .onChange(of: prefs.favoriteTeams) { updateFavoriteNotificationPrompt() }
        .onChange(of: prefs.matchNotificationsEnabled) { updateFavoriteNotificationPrompt() }
        // A tapped notification or banner:// URL. `initial` picks up a link that arrived
        // before this view existed (a cold launch from a notification).
        .onChange(of: deepLinks.pending, initial: true) { _, link in
            guard let link else { return }
            deepLinks.clear()
            open(link)
        }
        .sheet(item: $notificationMatch) { DeepLinkMatchSheet(target: $0) }
        .onChange(of: appEnvironment.pendingDeepLink) { _, link in
            guard let link else { return }
            appEnvironment.pendingDeepLink = nil
            Task { await handleDeepLink(link) }
        }
        .onChange(of: appEnvironment.requestedTab) { _, tab in
            guard let tab else { return }
            selectedTab = tab
            appEnvironment.requestedTab = nil
        }
        .fullScreenCoverCompat(item: $deepLinkMatch) { MatchDetailView(match: $0) }
        .alert("Get notified before your favourite teams play?", isPresented: $showingFavoriteNotificationPrompt) {
            Button("Not Now", role: .cancel) {
                prefs.markFavoriteTeamNotificationPromptAnswered()
            }
            Button("Allow Notifications") {
                Task { await enableFavoriteTeamNotifications() }
            }
        } message: {
            Text("BannerTV can remind you before games for teams you star. You can change this later in Settings.")
        }
    }

    private func open(_ link: DeepLink) {
        switch link {
        case .match(let leagueID, let matchID, let date):
            notificationMatch = DeepLinkMatchTarget(leagueID: leagueID, matchID: matchID, date: date)
        case .home: selectedTab = .home
        case .following: selectedTab = .following
        case .live: selectedTab = .live
        case .discover: selectedTab = .discover
        case .settings: selectedTab = .settings
        }
    }

    /// Resolves a `banner://game/{eventID}` link to a `Match` and presents its Game Centre
    /// screen. Checks the already-loaded live/starting-soon lists first (instant for the
    /// common case of tapping a notification about a game that's currently live), then
    /// falls back to a one-off broad fetch across every league for games outside that set.
    private func handleDeepLink(_ link: BannerDeepLink) async {
        guard case .game(let matchID) = link else { return }
        if let match = (liveViewModel.allLive + liveViewModel.startingSoon).first(where: { $0.id == matchID }) {
            deepLinkMatch = match
            return
        }
        let snapshot = await SportsRepository.shared.liveMatchSnapshot(leagues: League.all, startingSoonWindow: 7 * 24 * 3600, nextLimit: 100)
        let all = snapshot.live + snapshot.startingSoon + snapshot.next + snapshot.pastStartToday
        deepLinkMatch = all.first(where: { $0.id == matchID })
    }

    /// Piggybacks on `LiveViewModel`'s own refresh (no new polling loop) to keep at most
    /// one Live Activity tracking the highest-priority live game.
    private func updateLiveActivity(_ live: [Match]) {
        let favoriteIDs = Set(live.filter { prefs.isFavoriteMatch($0) }.map(\.id))
        let followedLeagueIDs = Set(live.filter { prefs.followedLeagues.contains($0.league) }.map(\.id))
        LiveActivityManager.shared.reconcile(
            liveMatches: live,
            favoriteMatchIDs: favoriteIDs,
            listeningMatchID: appEnvironment.activeLivePlaybackContext?.match.id,
            followedTeamMatchIDs: favoriteIDs,
            followedLeagueMatchIDs: followedLeagueIDs)
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
        .environmentObject(EPGRepository())
        .environmentObject(GuideChannelStore())
        .environmentObject(StreamAvailabilityStore())
        .environmentObject(EventChannelRefreshService())
        .environmentObject(BannerAppEnvironment.shared)
        .environmentObject(FantasyStore.shared)
        .environmentObject(BannerFantasyStore.shared)
        .environmentObject(StartupCoordinator())
        .preferredColorScheme(.dark)
}
