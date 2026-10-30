import SwiftUI
import Combine

// MARK: - Home Filter

enum HomeFilter: Hashable {
    case forYou
    case allSports
    case sport(SportGroup)

    var label: String {
        switch self {
        case .forYou: return "For You"
        case .allSports: return "All Sports"
        case .sport(let g): return g.rawValue
        }
    }

    var icon: String {
        switch self {
        case .forYou: return "sparkles"
        case .allSports: return "sportscourt"
        case .sport(let g): return g.systemImage
        }
    }
}

// MARK: - Schedule Day

enum ScheduleDay: String, CaseIterable, Identifiable {
    case today = "Today"
    case tomorrow = "Tomorrow"
    case weekend = "Weekend"
    var id: String { rawValue }
}

// MARK: - Home View

struct HomeView: View {
    var switchToFollowing: (() -> Void)? = nil
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var nativeFantasyStore: BannerFantasyStore
    @EnvironmentObject private var launchCoordinator: StartupCoordinator
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @EnvironmentObject private var streamStore: StreamAvailabilityStore
    @EnvironmentObject private var channelPrefs: ChannelPreferencesStore
    @StateObject private var viewModel = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playingChannel: Channel?
    @State private var quickStreamMatch: Match?
    @State private var selectedLiveSport: SportGroup?
    @State private var selectedScheduleDay: ScheduleDay = .today
    @State private var showingNotificationAlert = false
    @State private var notificationAlertMessage = ""
    @State private var showingTeamEditor = false
    // Launch reveal state — each section animates in independently with stagger.
    @State private var homeRevealed = false   // drives search button + re-appearance guard
    @State private var showGreeting = false
    @State private var showHero = false
    @State private var showSportsDay = false
    @State private var showLiveNow = false
    @State private var showSchedule = false
    @State private var showRemaining = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                mainContent
            }
            .inlineNavigationTitle()
            .toolbar { toolbarContent }
            #if os(iOS) || os(tvOS)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .navigationDestination(for: Match.self) { MatchDetailView(match: $0) }
            .fullScreenCoverCompat(item: $playingChannel) { PlayerView(channel: $0) }
            .sheet(item: $quickStreamMatch) { match in
                #if os(tvOS)
                TVMatchDetailView(match: match)
                #else
                QuickStreamSheet(match: match, sources: streamStore.topRanked(for: match.id))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                #endif
            }
            .sheet(isPresented: $showingTeamEditor) { TeamEditorView() }
        }
        .tint(Theme.accent)
        .task(id: loadPreferencesKey) {
            await viewModel.load(
                leagues: prefs.followedLeagues,
                favorites: prefs.favoriteTeams,
                notifications: prefs.notificationSettings
            )
            viewModel.startAutoRefresh()
            // Safety-net: markAppShellReady is called here after all phases, and also
        // earlier via onChange(of: viewModel.isLoading) when Phase 1 finishes.
            launchCoordinator.markAppShellReady()
        }
        // Fire markAppShellReady as soon as Phase 1 (live snapshot) completes so
        // the coordinator can begin the transition without waiting for Phase 2/3.
        // markAppShellReady() is idempotent — safe to call multiple times.
        .onChange(of: viewModel.isLoading) { _, isLoading in
            if !isLoading { launchCoordinator.markAppShellReady() }
        }
        // Match favourite-team games against the playlist/EPG from the moment the loading
        // screen appears — not just live/starting-soon matches (RootView's scan) — so a
        // favourite's stream is already linked by the time the user opens the game from Home.
        // Re-fires whenever the favourite-team lists, channel count or EPG guide change.
        .task(id: favoriteStreamScanKey) {
            await streamStore.scanDebounced(
                matches: favoriteStreamMatches,
                channels: playlistStore.allChannels,
                epgRepository: epgRepository
            )
        }
        // PRIMARY reveal trigger: begin the staggered section rise the moment the
        // logo starts moving. Content builds upward while the logo is in flight.
        .onChange(of: launchCoordinator.isTransitioningToHome) { _, transitioning in
            guard transitioning && !homeRevealed else { return }
            homeRevealed = true
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) {
                    showGreeting = true; showHero = true; showSportsDay = true
                    showLiveNow = true; showSchedule = true; showRemaining = true
                }
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation(.easeOut(duration: 0.45)) { showGreeting = true }
                    try? await Task.sleep(for: .milliseconds(70))
                    withAnimation(.easeOut(duration: 0.5)) { showHero = true }
                    try? await Task.sleep(for: .milliseconds(70))
                    withAnimation(.easeOut(duration: 0.5)) { showSportsDay = true }
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.5)) { showLiveNow = true }
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.5)) { showSchedule = true }
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.45)) { showRemaining = true }
                }
            }
        }
        // FALLBACK reveal: covers the edge case where isTransitioningToHome onChange
        // was missed (e.g., HomeView mounted after the transition already began).
        .onChange(of: launchCoordinator.phase) { _, phase in
            if phase == .home && !homeRevealed {
                homeRevealed = true
                withAnimation(.easeOut(duration: 0.3)) {
                    showGreeting = true; showHero = true; showSportsDay = true
                    showLiveNow = true; showSchedule = true; showRemaining = true
                }
            }
        }
        .onAppear {
            // Re-appearance after launch: reveal immediately without animation.
            // During launch itself the isTransitioningToHome onChange handles reveals.
            if launchCoordinator.phase == .home && !homeRevealed {
                homeRevealed = true
                showGreeting = true; showHero = true; showSportsDay = true
                showLiveNow = true; showSchedule = true; showRemaining = true
            }
        }
        .onDisappear { viewModel.stopAutoRefresh() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await viewModel.load(
                    leagues: prefs.followedLeagues,
                    favorites: prefs.favoriteTeams,
                    notifications: prefs.notificationSettings
                )
            }
        }
        .alert("Notifications", isPresented: $showingNotificationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notificationAlertMessage)
        }
        .refreshable {
            await viewModel.load(
                leagues: prefs.followedLeagues,
                favorites: prefs.favoriteTeams,
                notifications: prefs.notificationSettings,
                force: true
            )
        }
    }

    /// Favourite-team live, today's and near-term upcoming matches, deduplicated — the set the
    /// launch-time stream scan covers. Bounded to a handful of upcoming games so this doesn't
    /// grow into a full-schedule scan.
    private var favoriteStreamMatches: [Match] {
        var seen = Set<String>()
        var result: [Match] = []
        for match in viewModel.favoriteTeamLiveMatches + viewModel.favoriteTeamMatchesToday + viewModel.favoriteTeamUpcoming.prefix(8) {
            if seen.insert(match.id).inserted { result.append(match) }
        }
        return result
    }

    private var favoriteStreamScanKey: String {
        let ids = favoriteStreamMatches.map(\.id).sorted().joined(separator: ",")
        return "\(ids)-\(playlistStore.channelsRevision)-\(epgRepository.programmeRevision)"
    }

    private var loadPreferencesKey: String {
        [
            prefs.followedLeagues.map(\.id).sorted().joined(separator: ","),
            prefs.favoriteTeams.map(\.id).sorted().joined(separator: ","),
            String(describing: prefs.notificationSettings)
        ].joined(separator: "|")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Switches to opacity 1 in the same render frame the overlay is removed
        // (both triggered by the same `phase = .home` state change). No animation —
        // the overlay's animated BrandMark handles the visual all the way to this
        // position; the toolbar logo takes over atomically in one frame.
        ToolbarItem(placement: .principal) {
            BrandMark()
                .opacity(launchCoordinator.phase == .home ? 1 : 0)
        }
        // Appears ~80 ms after the logo begins moving. `.buttonStyle(.plain)` removes
        // the system circular tap-target background so only the icon fades in.
        ToolbarItem(placement: .primaryAction) {
            NavigationLink(destination: SearchView()) {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("Search")
                    .font(.system(size: Theme.isMac ? Theme.Mac.Header.searchIconSize : 16))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.isMac ? Theme.Mac.Header.searchSize : nil,
                           height: Theme.isMac ? Theme.Mac.Header.searchSize : nil)
                    .background(Theme.isMac ? Theme.surfaceElevated : Color.clear, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(homeRevealed ? 1 : 0)
            .animation(.easeIn(duration: 0.2).delay(0.08), value: homeRevealed)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isLoading && viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            ContentSkeleton(kind: .games)
        } else if let msg = viewModel.errorMessage, viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            errorView(msg)
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
        ScrollView {
            // Two columns when the window is wide enough (Duo unfolded, iPad), one otherwise.
            // Order is preserved: the primary column's sections come first when stacked.
            AdaptiveTwoPane(spacing: 28) {
                // Each section rises upward (positive offset → 0) while fading in.
                // Offsets increase with depth so deeper sections travel further.
                // `|| reduceMotion` collapses the offset to 0 for accessibility.

                greetingSection
                    .opacity(showGreeting ? 1 : 0)
                    .offset(y: (showGreeting || reduceMotion) ? 0 : 18)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.45), value: showGreeting)

                heroSection
                    .opacity(showHero ? 1 : 0)
                    .offset(y: (showHero || reduceMotion) ? 0 : 26)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.5), value: showHero)

                if !favouriteChannels.isEmpty {
                    FavouriteChannelsRail(channels: favouriteChannels) { PlaybackTapClock.record(); playingChannel = $0 }
                        .opacity(showHero ? 1 : 0)
                        .offset(y: (showHero || reduceMotion) ? 0 : 26)
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.5), value: showHero)
                }

                sportsDaySummaryCard
                    .opacity(showSportsDay ? 1 : 0)
                    .offset(y: (showSportsDay || reduceMotion) ? 0 : 30)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.5), value: showSportsDay)

                fantasyContextCard
                    .opacity(showSportsDay ? 1 : 0)
                    .offset(y: (showSportsDay || reduceMotion) ? 0 : 30)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.5), value: showSportsDay)

            } secondary: {
                liveNowSection
                    .opacity(showLiveNow ? 1 : 0)
                    .offset(y: (showLiveNow || reduceMotion) ? 0 : 34)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.5), value: showLiveNow)

                if !viewModel.startingSoon.filter { $0.id != viewModel.primeMatch?.id }.isEmpty {
                    StartingSoonTimeline(matches: viewModel.startingSoon.filter { $0.id != viewModel.primeMatch?.id })
                        .opacity(showLiveNow ? 1 : 0)
                        .offset(y: (showLiveNow || reduceMotion) ? 0 : 34)
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.5), value: showLiveNow)
                }

                scheduleSection
                    .opacity(showSchedule ? 1 : 0)
                    .offset(y: (showSchedule || reduceMotion) ? 0 : 38)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.5), value: showSchedule)

                if !viewModel.recentHighlights.isEmpty {
                    TrendingSection(highlights: viewModel.recentHighlights)
                        .opacity(showRemaining ? 1 : 0)
                        .offset(y: (showRemaining || reduceMotion) ? 0 : 40)
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.45), value: showRemaining)
                }

                // Straight back into what you were watching — placed last so it doesn't
                // compete with today's live/upcoming content for top-of-page attention.
                if !continueWatchingItems.isEmpty {
                    ContinueWatchingSection(items: continueWatchingItems) { PlaybackTapClock.record(); playingChannel = $0 }
                        .opacity(showRemaining ? 1 : 0)
                        .offset(y: (showRemaining || reduceMotion) ? 0 : 40)
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.45), value: showRemaining)
                }

            }
            .padding(.horizontal, 20)
            .padding(.bottom, Theme.Spacing.section)
            .macContentWidth()
        }
    }

    private var continueWatchingItems: [ContinueWatchingItem] {
        watchStore.continueWatchingItems(using: playlistStore)
    }

    /// Favourite channels in the user's order, resolved through the channel index.
    private var favouriteChannels: [Channel] {
        channelPrefs.favoriteChannelIDs.prefix(20).compactMap { playlistStore.channelsByID[$0] }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.system(.largeTitle, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Your sports, all in one place.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        if let prime = viewModel.primeMatch {
            FeaturedGameCard(
                match: prime,
                confirmedStreams: streamStore.confirmedCount(for: prime.id),
                possibleStreams: streamStore.count(for: prime.id),
                onWatch: { quickStreamMatch = prime },
                onRemind: { Task { await setAlert(for: prime) } }
            )
        }
    }

    // MARK: - Sports Day Summary

    private var sportsDaySummaryCard: some View {
        YourSportsDayCard(
            matches: viewModel.favoriteTeamMatchesToday,
            favorites: prefs.favoriteTeams,
            nextUpcoming: viewModel.favoriteTeamUpcoming.first,
            onSeeAll: { switchToFollowing?() },
            onFollowTeams: { showingTeamEditor = true }
        )
    }

    // MARK: - Fantasy Context

    @ViewBuilder
    private var fantasyContextCard: some View {
        if fantasyStore.settings.showFantasyOnHome, let summary = homeFantasySummary {
            HStack(spacing: 12) {
                Image(systemName: summary.isLive ? "star.circle.fill" : "star.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(summary.isLive ? Theme.live : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(summary.isLive ? Theme.live : Theme.accent)
                    Text(summary.subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let channel = summary.watchChannel {
                    Button { PlaybackTapClock.record(); playingChannel = channel } label: {
                        Label("Watch", systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(summary.isLive ? Theme.live : Theme.accent)
                } else {
                    NavigationLink { FantasyDashboardView() } label: {
                        HStack(spacing: 5) {
                            Text("View")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private var homeFantasySummary: HomeFantasySummary? {
        let liveContexts = fantasyStore.liveEventContexts + nativeFantasyStore.liveEventContexts
        if !liveContexts.isEmpty {
            let playerCount = liveContexts.reduce(0) { $0 + $1.playerGames.count }
            let total = fantasyStore.matchup?.userTeam.effectivePoints
            let points = total.map { " · \($0.formatted(.number.precision(.fractionLength(1)))) pts" } ?? ""
            return HomeFantasySummary(
                title: "FANTASY LIVE",
                subtitle: "\(playerCount) player\(playerCount == 1 ? "" : "s") · \(gameCountLabel(for: liveContexts))\(points)",
                isLive: true,
                watchChannel: liveContexts.first(where: { $0.watchAvailable })?.matchedChannel?.channel
            )
        }
        let todayContexts = (fantasyStore.todayEventContexts + nativeFantasyStore.todayEventContexts).filter { $0.isUpcoming }
        if !todayContexts.isEmpty {
            let playerCount = todayContexts.reduce(0) { $0 + $1.playerGames.count }
            return HomeFantasySummary(
                title: "FANTASY TONIGHT",
                subtitle: "\(playerCount) player\(playerCount == 1 ? "" : "s") · \(gameCountLabel(for: todayContexts))",
                isLive: false,
                watchChannel: nil
            )
        }
        return nil
    }

    /// "2 NHL games", or just "3 games" when the contexts span more than one league.
    private func gameCountLabel(for contexts: [FantasyEventContext]) -> String {
        let leagues = Set(contexts.map { $0.event.league.shortName })
        let noun = contexts.count == 1 ? "game" : "games"
        if leagues.count == 1, let league = leagues.first { return "\(contexts.count) \(league) \(noun)" }
        return "\(contexts.count) \(noun)"
    }

    // MARK: - Live Now

    @ViewBuilder
    private var liveNowSection: some View {
        if viewModel.liveNow.contains(where: { $0.id != viewModel.primeMatch?.id }) {
            LiveNowCommandCenter(
                matches: viewModel.liveNow.filter { $0.id != viewModel.primeMatch?.id },
                startingSoon: viewModel.startingSoon,
                nextMatches: viewModel.nextMatchesAcrossSports,
                selectedSport: $selectedLiveSport,
                onSetAlert: { match in Task { await setAlert(for: match) } },
                onAddToCalendar: { match in Task { await addToCalendar(match) } }
            )
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var scheduleSection: some View {
        let upcoming = viewModel.favoriteTeamUpcoming.filter { $0.id != viewModel.primeMatch?.id }
        if !upcoming.isEmpty {
            ScheduleSection(upcoming: upcoming, selectedDay: $selectedScheduleDay)
        }
    }

    private func setAlert(for match: Match) async {
        let scheduled = await MatchNotificationService.shared.scheduleReminder(for: match, leadTime: prefs.matchReminderLeadTime)
        if scheduled {
            prefs.setMatchNotificationsEnabled(true)
        } else if !(await MatchNotificationService.shared.isAuthorized()) {
            // A finished game can't be reminded about; only a revoked permission turns alerts off.
            prefs.setMatchNotificationsEnabled(false)
        }
        notificationAlertMessage = scheduled
            ? (match.state == .live ? "Live alert sent for \(match.shortName)." : "Alert set for \(match.shortName).")
            : (match.state == .final ? "\(match.shortName) is already final." : "Notifications are disabled. Enable them in Settings to receive game alerts.")
        showingNotificationAlert = true
    }

    private func addToCalendar(_ match: Match) async {
        #if canImport(EventKit)
        do {
            let saved = try await MatchCalendarService.shared.add(matches: [match])
            notificationAlertMessage = saved == 1 ? "Added \(match.shortName) to Calendar." : "No calendar event was added."
        } catch {
            notificationAlertMessage = error.localizedDescription
        }
        #else
        notificationAlertMessage = "Calendar export is not available on this device."
        #endif
        showingNotificationAlert = true
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task {
                    await viewModel.load(
                        leagues: prefs.followedLeagues,
                        favorites: prefs.favoriteTeams,
                        notifications: prefs.notificationSettings,
                        force: true
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(32)
    }
}

private struct HomeFantasySummary {
    let title: String
    let subtitle: String
    let isLive: Bool
    let watchChannel: Channel?
}

// MARK: - Your Sports Day

/// Which side of `match` (if any) belongs to one of the user's favourite teams, matched the
/// same way `HomeViewModel.involvesFavorite` does (provider team ID, league-qualified ID,
/// canonical ID, or display-name fallback).
private struct YourSportsDayCard: View {
    let matches: [Match]
    let favorites: [FavoriteTeam]
    let nextUpcoming: Match?
    let onSeeAll: () -> Void
    let onFollowTeams: () -> Void

    var body: some View {
        Card(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("Your Sports Day", systemImage: "calendar.badge.clock")
                    .font(Theme.Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                if favorites.isEmpty {
                    Button("Follow your teams", action: onFollowTeams)
                        .frame(minHeight: 44)
                } else {
                    if matches.isEmpty {
                        if let next = nextUpcoming {
                            Text(next.shortName).font(Theme.Typography.callout)
                            Text(next.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                                .font(Theme.Typography.captionDigits)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("No games today").font(Theme.Typography.callout)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        Text("Games today: \(matches.count)")
                            .font(Theme.Typography.callout)
                        let live = matches.filter { $0.state == .live }.count
                        if live > 0 {
                            Text("Live games: \(live)")
                                .font(Theme.Typography.captionDigits)
                                .foregroundStyle(Theme.live)
                        }
                    }
                    Button("See upcoming schedule", action: onSeeAll)
                        .frame(minHeight: 44)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .buttonStyle(.plain)
            .tint(Theme.accessibleAccent)
        }
    }
}

private struct HomeFilterBar: View {
    @Binding var selected: HomeFilter
    let followedLeagues: [League]

    private var filters: [HomeFilter] {
        var result: [HomeFilter] = [.forYou, .allSports]
        var seenGroups: Set<String> = []
        for league in followedLeagues {
            let group = league.group
            if seenGroups.insert(group.rawValue).inserted {
                result.append(.sport(group))
            }
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private func filterChip(_ filter: HomeFilter) -> some View {
        Button { withAnimation(Theme.Motion.snappy) { selected = filter } } label: {
            Label(filter.label, systemImage: filter.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected == filter ? .white : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected == filter ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected == filter ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Featured Hero (Dispatcher)

private struct LiveNowCommandCenter: View {
    let matches: [Match]
    let startingSoon: [Match]
    let nextMatches: [Match]
    @Binding var selectedSport: SportGroup?
    let onSetAlert: (Match) -> Void
    let onAddToCalendar: (Match) -> Void
    @EnvironmentObject private var streamStore: StreamAvailabilityStore
    @State private var hiddenMatchIDs: Set<String> = []

    private var visibleMatches: [Match] {
        matches.filter { !hiddenMatchIDs.contains($0.id) }
    }

    private var activeSports: [SportGroup] {
        var seen: [SportGroup] = []
        for m in visibleMatches where !seen.contains(m.league.group) { seen.append(m.league.group) }
        return seen
    }

    private var displayed: [Match] {
        guard let s = selectedSport else { return visibleMatches }
        return visibleMatches.filter { $0.league.group == s }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                PulsingLiveBadge()
                Text("LIVE NOW")
                    .font(Theme.isMac ? .system(size: Theme.Mac.Typography.standardMetadata, weight: .semibold) : .footnote.weight(.semibold))
                    .tracking(Theme.isMac ? 0.4 : 0)
                    .foregroundStyle(Theme.live)
                Spacer()
                if !matches.isEmpty {
                    NavigationLink(destination: LiveView()) {
                        Text("See All")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            // Sport chips
            if !activeSports.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        sportChip(title: "All", icon: "sportscourt", selected: selectedSport == nil) {
                            withAnimation(Theme.Motion.snappy) { selectedSport = nil }
                        }
                        ForEach(activeSports) { sport in
                            sportChip(title: sport.rawValue, icon: sport.systemImage, selected: selectedSport == sport) {
                                withAnimation(Theme.Motion.snappy) { selectedSport = selectedSport == sport ? nil : sport }
                            }
                        }
                    }
                }
            }

            // Content
            if visibleMatches.isEmpty {
                noLiveContent
            } else if displayed.isEmpty {
                Text("No live \(selectedSport?.rawValue ?? "games") right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                ForEach(displayed.prefix(5)) { match in
                    CompactGameRow(match: match, confirmedStreams: streamStore.confirmedCount(for: match.id))
                        .contextMenu {
                            Button("Set alert", systemImage: "bell") { onSetAlert(match) }
                            Button("Add to Calendar", systemImage: "calendar.badge.plus") { onAddToCalendar(match) }
                            Button("Hide", systemImage: "eye.slash") { hiddenMatchIDs.insert(match.id) }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var noLiveContent: some View {
        if !startingSoon.isEmpty || !nextMatches.isEmpty {
            let soonMatches = startingSoon.isEmpty ? Array(nextMatches.prefix(3)) : startingSoon
            let headline = startingSoon.isEmpty ? "Nothing live right now — next up" : "Nothing live right now — starting soon"
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.fill")
                    Text(headline)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.starting)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(soonMatches) { match in
                            NavigationLink(value: match) {
                                SoonTimelineCard(match: match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(Theme.textSecondary)
                Text("Nothing is live right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func sportChip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Chip(title: title, systemImage: icon, isSelected: selected, action: action)
    }
}

// MARK: - Starting Soon Timeline

struct StartingSoonTimeline: View {
    let matches: [Match]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.fill")
                Text("STARTING SOON")
                    .font(Theme.isMac ? .system(size: Theme.Mac.Typography.standardMetadata, weight: .semibold) : .footnote.weight(.semibold))
                    .tracking(Theme.isMac ? 0.4 : 0)
                    .foregroundStyle(Theme.starting)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(matches.prefix(8)) { match in
                        NavigationLink(value: match) {
                            SoonTimelineCard(match: match)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct SoonTimelineCard: View {
    let match: Match

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let secs = max(0, Int(match.date.timeIntervalSince(ctx.date)))
            let h = secs / 3600; let m = (secs % 3600) / 60
            let urgent = m < 10 && h == 0

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(match.date, style: .time)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(match.league.shortName)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }

                if GameCentreArchetype(match: match).usesHeadToHeadParticipantUI {
                    HStack(spacing: 6) {
                        TeamLogo(url: match.leadingSide.logoURL, size: 28)
                        Text("vs").font(.caption2).foregroundStyle(Theme.textSecondary)
                        TeamLogo(url: match.trailingSide.logoURL, size: 28)
                    }
                } else {
                    Image(systemName: match.league.group.systemImage)
                        .font(.title2)
                        .foregroundStyle(Theme.accessibleAccent)
                }

                Text(match.shortName)
                    .font(Theme.isMac ? .system(size: Theme.Mac.Typography.body, weight: .semibold) : .caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(secs < 60 ? "Starts now" : (h > 0 ? "In \(h)h \(m)m" : "In \(m) min"))
                    .font(.system(size: Theme.isMac ? 13 : 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(urgent ? Theme.live : Theme.starting)

                if let broadcast = match.broadcasts.first {
                    Label(broadcast, systemImage: "tv")
                        .font(Theme.Typography.overline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(Theme.isMac ? 14 : 12)
            .frame(width: Theme.isMac ? 165 : 150)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(urgent ? Theme.live : Theme.starting)
                    .frame(height: 2)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            }
        }
    }
}

// MARK: - Schedule Section

private struct ScheduleSection: View {
    let upcoming: [Match]
    @State private var showingTeamEditor = false
    @Binding var selectedDay: ScheduleDay

    private let calendar = Calendar.current

    private var todayMatches: [Match] {
        matches(inDayOffset: 0)
    }

    private var tomorrowMatches: [Match] {
        matches(inDayOffset: 1)
    }

    private func matches(inDayOffset offset: Int) -> [Match] {
        let start = calendar.startOfDay(for: Date())
        guard let dayStart = calendar.date(byAdding: .day, value: offset, to: start),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }
        return upcoming.filter { $0.date >= dayStart && $0.date < dayEnd }
    }

    // Only the actual upcoming Sat+Sun (or today if Sat/Sun).
    private var weekendMatches: [Match] {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // 1=Sun … 7=Sat

        let startDate: Date
        let endDate: Date

        switch weekday {
        case 7: // Saturday — show Sat + Sun
            startDate = today
            endDate = calendar.date(byAdding: .day, value: 2, to: today)!
        case 1: // Sunday — show just today
            startDate = today
            endDate = calendar.date(byAdding: .day, value: 1, to: today)!
        default: // Mon–Fri: find next Saturday
            let daysToSat = 7 - weekday // Mon(2)→5, Tue(3)→4, …, Fri(6)→1
            startDate = calendar.date(byAdding: .day, value: daysToSat, to: today)!
            endDate   = calendar.date(byAdding: .day, value: daysToSat + 2, to: today)!
        }

        return upcoming.filter {
            let d = calendar.startOfDay(for: $0.date)
            return d >= startDate && d < endDate
        }
    }

    private var displayedMatches: [Match] {
        switch selectedDay {
        case .today: return todayMatches
        case .tomorrow: return tomorrowMatches
        case .weekend: return weekendMatches
        }
    }

    private static let dayLabelFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt
    }()

    // Groups matches by calendar day, preserving order.
    private func groupByDay(_ matches: [Match]) -> [(label: String, matches: [Match])] {
        var order: [Date] = []
        var groups: [Date: [Match]] = [:]
        for match in matches {
            let day = calendar.startOfDay(for: match.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(match)
        }
        return order.map { day in
            (label: Self.dayLabelFormatter.string(from: day), matches: groups[day]!)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR SCHEDULE")
                .font(Theme.isMac ? .system(size: Theme.Mac.Typography.standardMetadata, weight: .semibold) : .footnote.weight(.semibold))
                .tracking(Theme.isMac ? 0.4 : 0)
                .foregroundStyle(Theme.textSecondary)

            // Day picker
            HStack(spacing: 0) {
                ForEach(ScheduleDay.allCases) { day in
                    let isSelected = selectedDay == day
                    Button { withAnimation(Theme.Motion.snappy) { selectedDay = day } } label: {
                        Text(day.rawValue)
                            .font(Theme.isMac ? .system(size: Theme.Mac.Typography.body, weight: .semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                            .padding(.vertical, Theme.isMac ? 0 : 8)
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.isMac ? Theme.Mac.ControlHeight.md : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .frame(maxWidth: Theme.isMac ? 650 : .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                GeometryReader { proxy in
                    let idx = ScheduleDay.allCases.firstIndex(of: selectedDay) ?? 0
                    let w = proxy.size.width / CGFloat(ScheduleDay.allCases.count)
                    RoundedRectangle(cornerRadius: Theme.isMac ? Theme.Radius.sm : 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.15))
                        .frame(width: w, height: proxy.size.height)
                        .offset(x: w * CGFloat(idx))
                        .animation(Theme.Motion.snappy, value: selectedDay)
                        .allowsHitTesting(false)
                }
            )

            // Matches — grouped by date for Tomorrow/Weekend
            if displayedMatches.isEmpty, let next = upcoming.filter({ $0.date > .now }).min(by: { $0.date < $1.date }) {
                NavigationLink(value: next) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Next followed-team game").font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                        Text(next.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            .font(Theme.Typography.caption)
                        ScheduleRow(match: next)
                    }
                }
                .buttonStyle(.plain)
            } else if displayedMatches.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.checkmark")
                            .foregroundStyle(Theme.textSecondary)
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    Button("Follow a team", systemImage: "star.badge.plus") { showingTeamEditor = true }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.accessibleAccent)
                        .frame(minHeight: 44)
                }
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
            } else if selectedDay == .today {
                ForEach(displayedMatches) { match in
                    NavigationLink(value: match) { ScheduleRow(match: match) }
                        .buttonStyle(.plain)
                }
            } else {
                let groups = groupByDay(displayedMatches)
                ForEach(groups, id: \.label) { group in
                    Text(group.label)
                        .font(Theme.isMac ? .system(size: Theme.Mac.Typography.smallMetadata, weight: .semibold) : .footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                    ForEach(group.matches) { match in
                        NavigationLink(value: match) { ScheduleRow(match: match) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: $showingTeamEditor) { TeamEditorView() }
    }

    private var emptyText: String {
        switch selectedDay {
        case .today: return "No games for your favourite teams today."
        case .tomorrow: return "No announced games for tomorrow yet."
        case .weekend: return "No weekend games found for your favourite teams."
        }
    }
}

private struct ScheduleRow: View {
    let match: Match

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(match.date, style: .time)
                    .font(.system(size: Theme.isMac ? 15 : 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(match.league.shortName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 68, alignment: .trailing)

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: 36)

            HStack(spacing: 10) {
                TeamLogo(url: match.leadingSide.logoURL, size: Theme.isMac ? Theme.Mac.LogoSize.card - 8 : 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.shortName)
                        .font(.system(size: Theme.isMac ? 15 : 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !match.broadcasts.isEmpty {
                        Text(match.broadcasts.prefix(2).joined(separator: " · "))
                            .font(Theme.isMac ? .system(size: Theme.Mac.Typography.smallMetadata) : .caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TeamLogo(url: match.trailingSide.logoURL, size: Theme.isMac ? Theme.Mac.LogoSize.card - 8 : 28)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Theme.isMac ? 14 : 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Trending Section

private struct TrendingSection: View {
    let highlights: [MatchHighlight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                Text("RECENT HIGHLIGHTS")
                    .font(Theme.isMac ? .system(size: Theme.Mac.Typography.standardMetadata, weight: .semibold) : .footnote.weight(.semibold))
                    .tracking(Theme.isMac ? 0.4 : 0)
            }
            .foregroundStyle(Theme.accent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(highlights) { clip in
                        HighlightCard(clip: clip)
                    }
                }
            }
        }
    }
}

// MARK: - Continue Watching Section

/// Horizontal rail of favourite channel logos on Home.
struct FavouriteChannelsRail: View {
    let channels: [Channel]
    let onPlay: (Channel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Favourite Channels", systemImage: "star.fill")
                .overlineStyle()
                .foregroundStyle(Theme.accent)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(channels) { channel in
                        Button { onPlay(channel) } label: {
                            VStack(spacing: Theme.Spacing.xs) {
                                ChannelLogo(url: channel.logoURL, name: channel.name, size: 72)
                                Text(channel.name)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .frame(width: 80)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(channel.name)")
                    }
                }
            }
        }
    }
}

/// A watch-history entry paired with the playable channel rebuilt from live provider data.
struct ContinueWatchingItem: Identifiable {
    let entry: WatchHistoryEntry
    let channel: Channel

    var id: String { entry.id }
}

extension WatchStore {
    /// History entries that can be played right now, most recent first. Entries whose playlist
    /// hasn't loaded yet, or whose channel the provider no longer lists, are left out.
    func continueWatchingItems(using playlists: PlaylistStore) -> [ContinueWatchingItem] {
        history.compactMap { entry in
            playlists.channel(for: entry.saved).map { ContinueWatchingItem(entry: entry, channel: $0) }
        }
    }
}

struct ContinueWatchingSection: View {
    @EnvironmentObject private var watchStore: WatchStore
    @State private var detailChannel: Channel?
    let items: [ContinueWatchingItem]
    let onPlay: (Channel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Continue Watching")
                    .font(Theme.isMac ? .system(size: Theme.Mac.Typography.standardMetadata, weight: .semibold) : .footnote.weight(.semibold))
                    .tracking(Theme.isMac ? 0.4 : 0)
            }
            .foregroundStyle(Theme.textSecondary)
            .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        Button { onPlay(item.channel) } label: {
                            ContinueWatchingCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Watch \(ChannelDisplayName.make(from: item.channel.name).title)")
                        .accessibilityHint("Opens the channel’s current broadcast")
                        .contextMenu {
                            Button(watchStore.isFavorite(item.channel) ? "Remove from Favourites" : "Add to Favourites",
                                   systemImage: "heart") { watchStore.toggleFavorite(item.channel) }
                            Button("Channel details", systemImage: "info.circle") { detailChannel = item.channel }
                            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                                watchStore.removeFromHistory(item.entry)
                            }
                        }
                        .accessibilityAction(named: Text("Toggle favourite")) { watchStore.toggleFavorite(item.channel) }
                        .accessibilityAction(named: Text("Channel details")) { detailChannel = item.channel }
                        .accessibilityAction(named: Text("Remove from Continue Watching")) { watchStore.removeFromHistory(item.entry) }
                    }
                }
            }
        }
        .sheet(item: $detailChannel) { channel in
            ChannelInformationSheet(channel: channel)
        }
    }
}

private struct ContinueWatchingCard: View {
    let item: ContinueWatchingItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.surfaceElevated
                CachedImage(url: item.channel.logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(10)
                    } else {
                        Text(ChannelDisplayName.make(from: item.channel.name).title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(width: min(tileWidth, 280), height: min(tileWidth, 280) * 9 / 16)
            .accessibilityHidden(true)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .padding(6)
            }

            Text(ChannelDisplayName.make(from: item.channel.name).title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            Text("Open live channel")
                .font(.caption)
                .foregroundStyle(Theme.accessibleAccent)
            Text(item.entry.lastWatched.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: min(tileWidth, 280))
    }
}

// MARK: - Home View Model (unchanged)

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var liveNow: [Match] = []
    @Published private(set) var favoriteTeamLiveMatches: [Match] = []
    @Published private(set) var favoriteTeamMatchesToday: [Match] = []
    @Published private(set) var favoriteTeamUpcoming: [Match] = []
    @Published private(set) var nextMatchesAcrossSports: [Match] = []
    @Published private(set) var startingSoon: [Match] = []
    @Published private(set) var upcoming: [Match] = []
    private var featuredPicks: [FeaturedEventPick] = []
    @Published private(set) var primeMatch: Match?
    @Published private(set) var recentHighlights: [MatchHighlight] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let featuredCalendar = FeaturedEventCalendar.shared

    private var lastLoadedLeagueIDs: Set<String> = []
    private var lastLoadedFavoriteSignature: String = ""
    private var lastLoadedAt: Date?
    private var isLoadInFlight = false
    private var matchesByLeague: [String: [Match]] = [:]
    private let cacheLifetime: TimeInterval = 120
    // Shorter cache window while live games are in progress so state stays current
    private let cacheLifetimeLive: TimeInterval = 25
    // matchesByLeague is never wiped wholesale (see load()) so matches don't
    // vanish from the home screen when a reload happens to run mid-session.
    // Only matches that are unambiguously over and old enough to be irrelevant
    // to "recently finished" are dropped, so the cache doesn't grow forever
    // over a long-lived app process.
    private let finishedMatchRetention: TimeInterval = 2 * 24 * 3600

    private var demandScoreCache: [String: Int] = [:]

    private var refreshTask: Task<Void, Never>?
    private var lastLoadArgs: (leagues: [League], favorites: [FavoriteTeam], notifications: NotificationSettings)?
    /// What the notification schedule was last brought in line with, so a change to the settings
    /// or favourites resyncs even when the match data itself is still fresh.
    private var lastSyncedNotifications: (settings: NotificationSettings, favoriteSignature: String)?

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // Refresh more aggressively when live games are in progress.
                let hasLive = await MainActor.run { self?.liveNow.isEmpty == false }
                let nanoseconds: UInt64 = hasLive ? 30_000_000_000 : 60_000_000_000
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let self, let args = self.lastLoadArgs, AppActivity.shared.isActive else { continue }
                await self.load(leagues: args.leagues, favorites: args.favorites, notifications: args.notifications)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func load(leagues: [League], favorites: [FavoriteTeam], notifications: NotificationSettings = NotificationSettings(), force: Bool = false) async {
        lastLoadArgs = (leagues, favorites, notifications)
        let followedLeagueIDs = Set(leagues.map(\.id))
        var seenDiscoveryLeagueIDs: Set<String> = []
        let discoveryLeagues = (leagues + League.all).filter { seenDiscoveryLeagueIDs.insert($0.id).inserted }
        let discoveryLeagueIDs = Set(discoveryLeagues.map(\.id))
        let favoriteIDs = Set(favorites.flatMap { favorite -> [String] in
            var keys = [favorite.id, favorite.canonicalTeamID, favorite.teamID, "\(favorite.leaguePath)-\(favorite.teamID)"] + favorite.providerAliases.map(\.id)
            if !favorite.abbreviation.isEmpty { keys.append("\(favorite.leaguePath)-\(favorite.abbreviation.lowercased())") }
            return keys
        })
        let favoriteNames = Set(favorites.map { $0.displayName.lowercased() })
        let favoriteSignature = favorites
            .flatMap { favorite in [favorite.id, favorite.canonicalTeamID, favorite.teamID, favorite.leaguePath, favorite.leagueBannerKey] + favorite.providerAliases.map(\.id) }
            .sorted()
            .joined(separator: "|")
        featuredPicks = featuredCalendar.picks()
        let hasData = !(liveNow.isEmpty && upcoming.isEmpty && favoriteTeamUpcoming.isEmpty)
        let effectiveCacheLifetime = liveNow.isEmpty ? cacheLifetime : cacheLifetimeLive
        if !force, hasData, discoveryLeagueIDs == lastLoadedLeagueIDs, favoriteSignature == lastLoadedFavoriteSignature,
           let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < effectiveCacheLifetime {
            // Nothing to fetch, but notification settings may have changed since the last pass.
            await syncNotificationsIfNeeded(favorites: favorites, settings: notifications, favoriteSignature: favoriteSignature)
            return
        }
        guard !isLoadInFlight else { return }

        isLoadInFlight = true
        isLoading = true
        errorMessage = nil
        demandScoreCache.removeAll(keepingCapacity: true)
        // matchesByLeague is intentionally NOT cleared here — it's the running,
        // merged cache of every match synced since the app opened. Each phase
        // below upserts into it so previously-synced matches never disappear
        // from the home screen just because a reload ran (e.g. after returning
        // from a match's Game Centre).
        defer {
            isLoadInFlight = false
            isLoading = false
        }

        let favoriteLeagueIDs = Set(favorites.flatMap { [$0.leaguePath, $0.leagueBannerKey] })
        let favoriteLeagues = League.all.filter {
            favoriteLeagueIDs.contains($0.id) || favoriteLeagueIDs.contains($0.bannerKey)
        }
        let p2Leagues = leagues
        let p3Leagues = favoriteLeagues

        // Phase 0: all requests fire concurrently — live scores, 7-day schedule,
        // and full-season schedule all start at the same time as the news prefetch.
        let newsLeagues = leagues
        Task.detached(priority: .utility) {
            await SportsRepository.shared.prefetchNews(for: newsLeagues)
        }

        // Capture loop-local sets so the callback closure can safely cross actor boundaries.
        let capturedFollowedIDs = followedLeagueIDs
        let capturedFavoriteIDs = favoriteIDs
        let capturedFavoriteNames = favoriteNames
        async let liveSnapshotTask = SportsRepository.shared.liveMatchSnapshot(
            leagues: discoveryLeagues,
            startingSoonWindow: 6 * 3600,
            nextLimit: 8,
            onPartialResult: { [weak self] partial in
                // Each league that completes lands here so the UI fills in incrementally rather
                // than waiting for all of them; the rebuild itself is batched (see below).
                let matches = partial.live + partial.startingSoon + partial.next + partial.pastStartToday
                Task { @MainActor [weak self] in
                    self?.receivePartial(matches, followedIDs: capturedFollowedIDs, favoriteIDs: capturedFavoriteIDs, favoriteNames: capturedFavoriteNames)
                }
            }
        )
        async let sevenDaySchedulesTask = loadSchedules(for: p2Leagues, days: 7, maxConcurrentLoads: 8)
        async let favoriteSeasonSchedulesTask = loadSchedules(for: p3Leagues, days: 365, maxConcurrentLoads: 6)

        // Await the final snapshot and merge it in as the authoritative
        // live/starting-soon/next baseline. The callbacks above have already
        // populated the UI incrementally — merge rather than replace so any
        // previously-loaded 7-day/season schedule data (from this or an
        // earlier load cycle) is preserved instead of discarded.
        let liveSnapshot = await liveSnapshotTask
        // The final snapshot carries everything the partial results did.
        partialFlushTask?.cancel()
        partialFlushTask = nil
        pendingPartialMatches.removeAll()
        // Include pastStartToday so games that started but still show as scheduled are
        // present in allMatches — they can appear in Live Now via the featured-IDs special
        // case and will be correctly matched to featured picks.
        for match in liveSnapshot.live + liveSnapshot.startingSoon + liveSnapshot.next + liveSnapshot.pastStartToday {
            matchesByLeague[match.league.id, default: []].append(match)
        }
        for key in matchesByLeague.keys {
            matchesByLeague[key] = mergeMatches(matchesByLeague[key] ?? [])
        }
        if !matchesByLeague.isEmpty {
            rebuildSections(matchesByLeague: matchesByLeague, followedIDs: followedLeagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        }

        isLoading = false
        // Don't surface the blocking error state yet: this is only the fast "live or
        // starting soon" pass, and finding nothing here is the ordinary outcome most
        // hours of most days (no live games) — it says nothing about whether the
        // slower 7-day/season schedule fetches below, still in flight, will succeed.
        // Showing "Try Again" at this point flashed on effectively every quiet moment.

        let sevenDaySchedules = await sevenDaySchedulesTask
        for (leagueID, matches, _) in sevenDaySchedules where !matches.isEmpty {
            if Task.isCancelled { break }
            matchesByLeague[leagueID] = mergeMatches((matchesByLeague[leagueID] ?? []) + matches)
        }
        if !Task.isCancelled, !sevenDaySchedules.isEmpty {
            rebuildSections(matchesByLeague: matchesByLeague, followedIDs: followedLeagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        }

        let favoriteSeasonSchedules = await favoriteSeasonSchedulesTask
        for (leagueID, matches, _) in favoriteSeasonSchedules where !matches.isEmpty {
            if Task.isCancelled { break }
            matchesByLeague[leagueID] = mergeMatches((matchesByLeague[leagueID] ?? []) + matches)
        }
        if !Task.isCancelled, !favoriteSeasonSchedules.isEmpty {
            rebuildSections(matchesByLeague: matchesByLeague, followedIDs: followedLeagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        }

        await syncNotificationsIfNeeded(favorites: favorites, settings: notifications, favoriteSignature: favoriteSignature, force: true)

        let recentlyFinished = matchesByLeague
            .filter { followedLeagueIDs.contains($0.key) }
            .values.flatMap { $0 }
            .filter { $0.state == .final }
            .sorted { $0.date > $1.date }
            .prefix(3)

        if !recentlyFinished.isEmpty {
            var clips: [MatchHighlight] = []
            await withTaskGroup(of: [MatchHighlight].self) { group in
                for match in recentlyFinished {
                    group.addTask {
                        (try? await SportsRepository.shared.legacyGameSummary(for: match))?.highlights ?? []
                    }
                }
                for await matchClips in group {
                    clips.append(contentsOf: matchClips)
                }
            }
            recentHighlights = Array(clips.prefix(8))
        }

        if !Task.isCancelled, !matchesByLeague.isEmpty {
            errorMessage = nil
            lastLoadedLeagueIDs = discoveryLeagueIDs
            lastLoadedFavoriteSignature = favoriteSignature
            lastLoadedAt = Date()
        } else if !Task.isCancelled {
            // Live-or-soon, 7-day, and season-long schedule fetches all came back
            // empty across every league in the catalog — that's not a single bad
            // league, it's total data unavailability. Surface the real failure
            // reason(s) instead of a generic "check your connection" message so a
            // provider/routing bug doesn't masquerade as a network problem.
            //
            // Thrown errors only cover leagues with no valid provider route at all
            // (every League.all entry has one — see SportsCatalogProviderCoverageTests —
            // but a league removed from SportsRepository.init's provider list without
            // also being removed from League.all would show up this way). A provider
            // that's silently succeeding with empty results
            // for every league (the thing the ProviderHealthMonitor circuit breaker
            // is meant to catch) never throws, so it wouldn't show up here — check
            // its health snapshot directly so a tripped/degraded provider isn't
            // invisible just because it didn't throw.
            let distinctFailures = orderedUnique(
                liveSnapshot.failures
                    + sevenDaySchedules.compactMap(\.failure)
                    + favoriteSeasonSchedules.compactMap(\.failure)
            )
            let parts = Array(distinctFailures.prefix(3))
            errorMessage = parts.isEmpty
                ? "Couldn't load sports data. Check your connection and try again."
                : "Couldn't load sports data: \(parts.joined(separator: "; "))"
        }
    }

    // MARK: Partial results

    /// Every rebuild re-merges and re-sorts all the sections, and a league's results used to trigger
    /// one each (eleven during one live pass). The first partial result is folded in straight away,
    /// the rest are collected and folded in together at most every `partialFlushInterval`.
    private static let partialFlushInterval: TimeInterval = 0.25
    private var pendingPartialMatches: [Match] = []
    private var partialFlushTask: Task<Void, Never>?
    private var lastPartialFlush = Date.distantPast

    private func receivePartial(_ matches: [Match], followedIDs: Set<String>, favoriteIDs: Set<String>, favoriteNames: Set<String>) {
        guard isLoadInFlight else { return }
        pendingPartialMatches.append(contentsOf: matches)
        guard partialFlushTask == nil else { return }
        let wait = max(0, Self.partialFlushInterval - Date().timeIntervalSince(lastPartialFlush))
        partialFlushTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.flushPartialMatches(followedIDs: followedIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        }
    }

    private func flushPartialMatches(followedIDs: Set<String>, favoriteIDs: Set<String>, favoriteNames: Set<String>) {
        partialFlushTask = nil
        let batch = pendingPartialMatches
        pendingPartialMatches.removeAll(keepingCapacity: true)
        guard isLoadInFlight, !batch.isEmpty else { return }
        lastPartialFlush = Date()
        var touchedLeagues: Set<String> = []
        for match in batch {
            matchesByLeague[match.league.id, default: []].append(match)
            touchedLeagues.insert(match.league.id)
        }
        // Only the leagues that just received matches need merging; the others were merged earlier.
        for leagueID in touchedLeagues {
            matchesByLeague[leagueID] = mergeMatches(matchesByLeague[leagueID] ?? [])
        }
        rebuildSections(matchesByLeague: matchesByLeague, followedIDs: followedIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        isLoading = false
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private nonisolated func loadSchedules(for leagues: [League], days: Int, maxConcurrentLoads: Int) async -> [(leagueID: String, matches: [Match], failure: String?)] {
        guard !leagues.isEmpty else { return [] }
        return await withTaskGroup(of: (leagueID: String, matches: [Match], failure: String?).self) { group in
            let maxActiveLoads = max(1, maxConcurrentLoads)
            var results: [(leagueID: String, matches: [Match], failure: String?)] = []
            var nextLeagueIndex = 0

            func enqueueNextLeague() {
                guard nextLeagueIndex < leagues.count else { return }
                let league = leagues[nextLeagueIndex]
                nextLeagueIndex += 1
                group.addTask {
                    do {
                        let matches = try await SportsRepository.shared.legacyScoreboards(
                            for: league,
                            starting: Date(),
                            days: days
                        )
                        return (league.id, matches, nil)
                    } catch {
                        return (league.id, [], "\(league.name): \(error.localizedDescription)")
                    }
                }
            }

            for _ in 0..<min(maxActiveLoads, leagues.count) {
                enqueueNextLeague()
            }

            while let result = await group.next() {
                results.append(result)
                enqueueNextLeague()
            }
            return results
        }
    }

    /// Brings the scheduled notifications in line with the loaded matches. After a full load it
    /// always runs; when the data was still fresh it runs only if the settings or favourites changed.
    private func syncNotificationsIfNeeded(
        favorites: [FavoriteTeam],
        settings: NotificationSettings,
        favoriteSignature: String,
        force: Bool = false
    ) async {
        let previous = lastSyncedNotifications
        if !force, let previous, previous.settings == settings, previous.favoriteSignature == favoriteSignature { return }
        lastSyncedNotifications = (settings, favoriteSignature)
        guard settings.enabled else { return }

        let allMatches = matchesByLeague.values.flatMap { $0 }
        await MatchNotificationService.shared.syncNotifications(matches: allMatches, favorites: favorites, settings: settings)
        if settings.morningDigest {
            await MatchNotificationService.shared.scheduleMorningDigest(matches: allMatches, hour: settings.morningDigestHour)
        } else if previous?.settings.morningDigest != false {
            // First pass of this launch, or just switched off: clear any briefing still scheduled.
            await MatchNotificationService.shared.removeMorningDigests()
        }
    }

    private func rebuildSections(matchesByLeague: [String: [Match]], followedIDs: Set<String>, favoriteIDs: Set<String>, favoriteNames: Set<String>) {
        let now = Date()
        let calendar = Calendar.current
        let allMatches = mergeMatches(matchesByLeague.values.flatMap { $0 })
        let followedMatches = mergeMatches(matchesByLeague
            .filter { followedIDs.contains($0.key) }
            .values.flatMap { $0 })

        var scores: [String: Int] = [:]
        scores.reserveCapacity(allMatches.count)
        for match in allMatches {
            scores[match.id] = primeScore(match, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        }
        func score(_ match: Match) -> Int { scores[match.id] ?? 0 }

        // Associate editorial picks with provider events; a scheduled start alone
        // is never evidence that an event is live.
        var syncedFeaturedMatches: [String: Match] = [:]
        // Iterate from highest-scoring to lowest. Track which picks have already been
        // matched so a lower-quality (e.g. stale "scheduled") match cannot overwrite
        // a live match that was processed first.
        var matchedPickIDs = Set<String>()
        for match in allMatches.sorted(by: { score($0) > score($1) }) {
            for pick in featuredCalendar.matchingPicks(for: match) {
                if matchedPickIDs.insert(pick.id).inserted {
                    syncedFeaturedMatches[pick.id] = match
                }
            }
        }
        let featuredIDs = Set(syncedFeaturedMatches.values.map { $0.id })

        liveNow = allMatches
            .filter { $0.state == .live }
            .sorted { score($0) > score($1) }
        favoriteTeamLiveMatches = liveNow
            .filter { involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
        favoriteTeamMatchesToday = allMatches
            .filter { calendar.isDateInToday($0.date) && involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
            .sorted { $0.date < $1.date }
        favoriteTeamUpcoming = allMatches
            .filter { BannerGameStatus(presentationOf: $0) == .scheduled && $0.date >= now && involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
            .sorted { $0.date < $1.date }
        nextMatchesAcrossSports = allMatches
            .filter { $0.state == .pre && $0.date >= now }
            .sorted { $0.date < $1.date }
            .prefix(3)
            .map { $0 }
        let soonWindow = now.addingTimeInterval(6 * 60 * 60)
        startingSoon = allMatches
            .filter { BannerGameStatus(presentationOf: $0) == .scheduled && $0.date > now && $0.date <= soonWindow && !featuredIDs.contains($0.id) }
            .sorted { $0.date < $1.date }
            .prefix(8)
            .map { $0 }
        upcoming = followedMatches
            .filter { $0.state == .pre && $0.date >= now }
            .sorted { $0.date < $1.date }
        // Context takes precedence over an additive score: live favourites, other
        // live events, then the next followed fixture and the wider schedule.
        primeMatch = favoriteTeamLiveMatches.first ?? liveNow.first
            ?? favoriteTeamUpcoming.first ?? upcoming.first ?? nextMatchesAcrossSports.first
    }

    private func mergeMatches(_ matches: [Match]) -> [Match] {
        // Pass 1: deduplicate by exact ID, preferring the highest-quality state.
        // On a tie, the later entry wins (>=) rather than the first-seen one —
        // matchesByLeague now accumulates across load() cycles instead of being
        // wiped, so a freshly-fetched update (e.g. a live match's latest score)
        // must be able to overwrite an older entry of the same quality tier.
        var bestByID: [String: Match] = [:]
        for match in matches {
            if let existing = bestByID[match.id] {
                if matchQuality(match) >= matchQuality(existing) {
                    bestByID[match.id] = match
                }
            } else {
                bestByID[match.id] = match
            }
        }
        // Pass 2: fuzzy-deduplicate by team abbreviations + half-hour bucket.
        // Catches cross-provider duplicates where the same game has different IDs
        // (e.g. Apple Sports canonical ID vs ESPN numeric ID).
        var bestByFuzzyKey: [String: Match] = [:]
        for match in bestByID.values {
            let key = fuzzyMatchKey(match)
            if let existing = bestByFuzzyKey[key] {
                if matchQuality(match) >= matchQuality(existing) {
                    bestByFuzzyKey[key] = match
                }
            } else {
                bestByFuzzyKey[key] = match
            }
        }
        let retentionCutoff = Date().addingTimeInterval(-finishedMatchRetention)
        return bestByFuzzyKey.values
            .filter { !($0.state == .final && $0.date < retentionCutoff) }
            .sorted { $0.date < $1.date }
    }

    private func fuzzyMatchKey(_ match: Match) -> String {
        let bucket = Int(match.date.timeIntervalSince1970 / 1800)
        let participants = [match.away.abbreviation, match.home.abbreviation]
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0 != "tbd" }
            .sorted()
            .joined(separator: ":")
        guard !participants.isEmpty else {
            let day = Int(Calendar.current.startOfDay(for: match.date).timeIntervalSince1970)
            return "\(match.league.bannerKey):\(day):\(match.id)"
        }
        return "\(match.league.bannerKey):\(bucket):\(participants)"
    }

    private func matchQuality(_ match: Match) -> Int {
        var q = 0
        if match.state == .live { q += 1000 }
        if match.state == .final { q += 500 }
        if match.hasDisplayScore { q += 100 }
        if !match.broadcasts.isEmpty { q += 10 }
        return q
    }

    private func primeScore(_ match: Match, favoriteIDs: Set<String> = [], favoriteNames: Set<String> = []) -> Int {
        var score = cachedDemandScore(match)
        if match.state == .live { score += 100 }
        if match.hasDisplayScore { score += 25 }
        if involvesFavorite(match, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) { score += 50 }
        if !match.broadcasts.isEmpty { score += 20 }
        score -= max(0, Int(match.date.timeIntervalSinceNow / 3600))
        return score
    }

    private func cachedDemandScore(_ match: Match) -> Int {
        if let cached = demandScoreCache[match.id] { return cached }
        let score = eventDemandScore(match)
        demandScoreCache[match.id] = score
        return score
    }

    private func eventDemandScore(_ match: Match) -> Int {
        let text = [match.name, match.shortName, match.statusDetail, match.league.name, match.league.shortName]
            .joined(separator: " ")
            .lowercased()
        var score = featuredCalendar.demandBoost(for: match)

        if text.contains("world cup") || text.contains("fifa") { score += 220 }
        if text.contains("champions league") || text.contains("uefa") { score += 140 }
        if text.contains("final") || text.contains("championship") || text.contains("title") { score += 130 }
        if text.contains("semifinal") || text.contains("semi-final") || text.contains("playoff") { score += 80 }
        if text.contains("derby") || text.contains("rivalry") { score += 30 }

        switch match.league.name {
        case "NFL": score += 70
        case "NBA", "Premier League", "Champions League": score += 55
        case "MLB", "NHL": score += 35
        case "MLS", "La Liga", "Serie A", "Bundesliga", "Ligue 1": score += 25
        default: score += 10
        }

        return score
    }

    private func involvesFavorite(_ match: Match, favoriteIDs: Set<String>, favoriteNames: Set<String>) -> Bool {
        guard !favoriteIDs.isEmpty || !favoriteNames.isEmpty else { return false }
        let sides = [match.home, match.away]
        return sides.contains { side in
            if let teamID = side.teamID,
               favoriteIDs.contains(teamID) ||
               favoriteIDs.contains("\(match.league.path)-\(teamID)") ||
               favoriteIDs.contains("\(match.league.bannerKey)-\(teamID)") {
                return true
            }
            if let canonicalID = side.canonicalIDString, favoriteIDs.contains(canonicalID) {
                return true
            }
            if favoriteNames.contains(side.displayName.lowercased()) {
                return true
            }
            // League-scoped abbreviation fallback uses the selected league to avoid cross-league collisions.
            return !side.abbreviation.isEmpty && favoriteIDs.contains("\(match.league.path)-\(side.abbreviation.lowercased())")
        }
    }
}
