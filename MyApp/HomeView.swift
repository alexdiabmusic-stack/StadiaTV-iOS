import SwiftUI
import Combine

struct HomeView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var watchStore: WatchStore
    @StateObject private var viewModel = HomeViewModel()
    @State private var playingChannel: Channel?
    @State private var selectedLiveSport: SportGroup?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationDestination(for: Match.self) { match in
                MatchDetailView(match: match)
            }
            .navigationTitle("Home")
            .searchToolbar()
            .sheet(item: $playingChannel) { channel in
                PlayerView(channel: channel)
            }
        }
        .tint(Theme.accent)
        .task(id: loadPreferencesKey) {
            await viewModel.load(leagues: prefs.followedLeagues, favorites: prefs.favoriteTeams, notificationsEnabled: prefs.matchNotificationsEnabled, notificationLeadTime: prefs.matchReminderLeadTime, morningDigestEnabled: prefs.morningDigestEnabled)
            viewModel.startAutoRefresh()
        }
        .onDisappear { viewModel.stopAutoRefresh() }
        .refreshable {
            await viewModel.load(leagues: prefs.followedLeagues, favorites: prefs.favoriteTeams, notificationsEnabled: prefs.matchNotificationsEnabled, notificationLeadTime: prefs.matchReminderLeadTime, morningDigestEnabled: prefs.morningDigestEnabled, force: true)
        }
    }

    private var loadPreferencesKey: String {
        [
            prefs.followedLeagues.map(\.id).sorted().joined(separator: ","),
            prefs.favoriteTeams.map(\.id).sorted().joined(separator: ","),
            prefs.matchNotificationsEnabled ? "notifications-on" : "notifications-off",
            "lead-\(prefs.matchReminderLeadTime.rawValue)",
            prefs.morningDigestEnabled ? "digest-on" : "digest-off"
        ].joined(separator: "|")
    }

    @ViewBuilder private var content: some View {
        if viewModel.isLoading && viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            ProgressView().tint(Theme.accent)
        } else if let message = viewModel.errorMessage, viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: Theme.scaled(42)))
                    .foregroundStyle(Theme.textSecondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await viewModel.load(leagues: prefs.followedLeagues, favorites: prefs.favoriteTeams, notificationsEnabled: prefs.matchNotificationsEnabled) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(32)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    HomeHeroSection(
                        featuredPicks: viewModel.featuredPicks,
                        featuredMatchesByPickID: viewModel.featuredMatchesByPickID,
                        favoriteLiveMatches: viewModel.favoriteTeamLiveMatches,
                        primeMatch: viewModel.primeMatch
                    )

                    HomeSection(title: "Your Teams Today", systemImage: "star.fill", tint: Theme.accent, matches: viewModel.favoriteTeamMatchesToday, emptyText: prefs.favoriteTeams.isEmpty ? "Favorite teams in setup or settings to see them here." : "No games today for your favorite teams.", limit: 5)
                    LiveNowSection(matches: viewModel.liveNow, nextMatches: viewModel.nextMatchesAcrossSports, startingSoon: viewModel.startingSoon, selectedSport: $selectedLiveSport)
                    if !viewModel.recentHighlights.isEmpty {
                        RecentHighlightsSection(highlights: viewModel.recentHighlights)
                    }
                    HomeSection(title: "Upcoming Games", systemImage: "calendar", tint: Color(hex: 0x3DBE6B), matches: viewModel.favoriteTeamUpcoming, emptyText: prefs.favoriteTeams.isEmpty ? "Favorite teams in setup or settings to see them here." : "No announced upcoming games for your favorite teams.", limit: 5)

                    if !watchStore.history.isEmpty {
                        ContinueWatchingSection(entries: watchStore.history) { channel in
                            playingChannel = channel
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var liveNow: [Match] = []
    @Published private(set) var favoriteTeamLiveMatches: [Match] = []
    @Published private(set) var favoriteTeamMatchesToday: [Match] = []
    @Published private(set) var favoriteTeamUpcoming: [Match] = []
    @Published private(set) var nextMatchesAcrossSports: [Match] = []
    @Published private(set) var startingSoon: [Match] = []
    @Published private(set) var upcoming: [Match] = []
    @Published private(set) var featuredPicks: [FeaturedEventPick] = []
    @Published private(set) var featuredMatchesByPickID: [String: Match] = [:]
    @Published private(set) var primeMatch: Match?
    @Published private(set) var recentHighlights: [MatchHighlight] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service = ESPNService()
    private let featuredCalendar = FeaturedEventCalendar.shared

    // Cache bookkeeping so revisiting the tab doesn't refetch everything.
    private var lastLoadedLeagueIDs: Set<String> = []
    private var lastLoadedAt: Date?
    private let cacheLifetime: TimeInterval = 120

    // eventDemandScore is string-heavy, so reuse results across the
    // progressive section rebuilds within a load pass.
    private var demandScoreCache: [String: Int] = [:]

    private var refreshTask: Task<Void, Never>?
    private var lastLoadArgs: (leagues: [League], favorites: [FavoriteTeam], notificationsEnabled: Bool, notificationLeadTime: MatchReminderLeadTime, morningDigestEnabled: Bool)?

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled, let self, let args = self.lastLoadArgs else { continue }
                await self.load(leagues: args.leagues, favorites: args.favorites, notificationsEnabled: args.notificationsEnabled, notificationLeadTime: args.notificationLeadTime, morningDigestEnabled: args.morningDigestEnabled)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func load(leagues: [League], favorites: [FavoriteTeam], notificationsEnabled: Bool = false, notificationLeadTime: MatchReminderLeadTime = .thirty, morningDigestEnabled: Bool = false, force: Bool = false) async {
        lastLoadArgs = (leagues, favorites, notificationsEnabled, notificationLeadTime, morningDigestEnabled)
        let leagueIDs = Set(leagues.map(\.id))
        featuredPicks = featuredCalendar.picks()
        let hasData = !(liveNow.isEmpty && upcoming.isEmpty && favoriteTeamUpcoming.isEmpty)
        if !force, hasData, leagueIDs == lastLoadedLeagueIDs,
           let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < cacheLifetime {
            return
        }
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        demandScoreCache.removeAll(keepingCapacity: true)
        let favoriteIDs = Set(favorites.map(\.id))
        let favoriteNames = Set(favorites.map { $0.displayName.lowercased() })
        var matchesByLeague: [String: [Match]] = [:]

        // Phase 1: followed leagues get a full week (for Upcoming / Your Teams).
        // Sections render as each league's response lands instead of waiting
        // for the slowest request.
        await withTaskGroup(of: (String, [Match]).self) { group in
            for league in leagues {
                group.addTask {
                    (league.id, (try? await self.service.scoreboards(for: league, starting: Date(), days: 7)) ?? [])
                }
            }
            for await (id, matches) in group {
                guard !matches.isEmpty else { continue }
                matchesByLeague[id] = matches
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
            }
        }

        // Phase 2: sweep the rest of the catalog with a short window so Live
        // Right Now spans all sports without waiting on long schedule fetches.
        // Three days is enough for live games plus the next-games fallback.
        await withTaskGroup(of: (String, [Match]).self) { group in
            for league in League.all where !leagueIDs.contains(league.id) {
                group.addTask {
                    (league.id, (try? await self.service.scoreboards(for: league, starting: Date(), days: 3)) ?? [])
                }
            }
            for await (id, matches) in group {
                guard !matches.isEmpty else { continue }
                matchesByLeague[id] = matches
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
            }
        }

        isLoading = false
        if matchesByLeague.isEmpty {
            errorMessage = "ESPN did not return games for your followed leagues."
        }

        // Phase 3: favorite-team leagues get a long schedule sweep so the home
        // page can show the next announced games even if they are months away.
        let favoriteLeagueIDs = Set(favorites.map(\.leaguePath))
        await withTaskGroup(of: (String, [Match]).self) { group in
            for league in League.all where favoriteLeagueIDs.contains(league.id) {
                group.addTask {
                    (league.id, (try? await self.service.scoreboards(for: league, starting: Date(), days: 365)) ?? [])
                }
            }
            for await (id, matches) in group {
                guard !matches.isEmpty else { continue }
                let existing = matchesByLeague[id] ?? []
                matchesByLeague[id] = mergeMatches(existing + matches)
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
            }
        }

        if notificationsEnabled {
            let allMatchesFlat = matchesByLeague.values.flatMap { $0 }
            await MatchNotificationService.shared.syncNotifications(
                matches: allMatchesFlat,
                favorites: favorites,
                leadTime: notificationLeadTime
            )
            if morningDigestEnabled {
                await MatchNotificationService.shared.scheduleMorningDigest(matches: allMatchesFlat)
            }
        }

        // Phase 4: fetch video highlights from the 3 most recently finished games
        // in the user's followed leagues. Runs after main content is visible.
        let recentlyFinished = matchesByLeague
            .filter { leagueIDs.contains($0.key) }
            .values.flatMap { $0 }
            .filter { $0.state == .final }
            .sorted { $0.date > $1.date }
            .prefix(3)

        if !recentlyFinished.isEmpty {
            var clips: [MatchHighlight] = []
            await withTaskGroup(of: [MatchHighlight].self) { group in
                for match in recentlyFinished {
                    group.addTask { [service] in
                        (try? await service.gameSummary(for: match.league, eventID: match.id))?.highlights ?? []
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
            lastLoadedLeagueIDs = leagueIDs
            lastLoadedAt = Date()
        }
    }

    /// Recomputes the published sections from everything fetched so far.
    private func rebuildSections(matchesByLeague: [String: [Match]], followedIDs: Set<String>, favoriteIDs: Set<String>, favoriteNames: Set<String>) {
        let now = Date()
        let calendar = Calendar.current
        let allMatches = mergeMatches(matchesByLeague.values.flatMap { $0 })
        let followedMatches = mergeMatches(matchesByLeague
            .filter { followedIDs.contains($0.key) }
            .values.flatMap { $0 })

        // Score every match once up front; sorting with primeScore inside the
        // comparator recomputes it O(n log n) times and dominated load time.
        var scores: [String: Int] = [:]
        scores.reserveCapacity(allMatches.count)
        for match in allMatches {
            scores[match.id] = primeScore(match, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        }
        func score(_ match: Match) -> Int { scores[match.id] ?? 0 }

        liveNow = allMatches
            .filter { $0.state == .live }
            .sorted { score($0) > score($1) }
        favoriteTeamLiveMatches = liveNow
            .filter { involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
        favoriteTeamMatchesToday = allMatches
            .filter { calendar.isDateInToday($0.date) && involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
            .sorted { $0.date < $1.date }
        favoriteTeamUpcoming = allMatches
            .filter { $0.state == .pre && $0.date >= now && involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
            .sorted { $0.date < $1.date }
        nextMatchesAcrossSports = allMatches
            .filter { $0.state == .pre && $0.date >= now }
            .sorted { $0.date < $1.date }
            .prefix(3)
            .map { $0 }
        let soonWindow = now.addingTimeInterval(6 * 60 * 60)
        startingSoon = allMatches
            .filter { $0.state == .pre && $0.date > now && $0.date <= soonWindow }
            .sorted { $0.date < $1.date }
            .prefix(8)
            .map { $0 }
        upcoming = followedMatches
            .filter { $0.state == .pre && $0.date >= now }
            .sorted { $0.date < $1.date }
            .prefix(12)
            .map { $0 }
        var syncedFeaturedMatches = Dictionary(uniqueKeysWithValues: featuredPicks.map { ($0.id, $0.streamMatch) })
        for match in allMatches.sorted(by: { score($0) > score($1) }) {
            for pick in featuredCalendar.matchingPicks(for: match) {
                syncedFeaturedMatches[pick.id] = match
            }
        }
        featuredMatchesByPickID = syncedFeaturedMatches
        primeMatch = (liveNow + favoriteTeamUpcoming + upcoming)
            .max { score($0) < score($1) }
    }

    private func mergeMatches(_ matches: [Match]) -> [Match] {
        var seenIDs: Set<String> = []
        var unique: [Match] = []
        for match in matches.sorted(by: { $0.date < $1.date }) where seenIDs.insert(match.id).inserted {
            unique.append(match)
        }
        return unique
    }

    private func primeScore(_ match: Match, favoriteIDs: Set<String> = [], favoriteNames: Set<String> = []) -> Int {
        var score = cachedDemandScore(match)
        if match.state == .live { score += 100 }
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
            if let teamID = side.teamID, favoriteIDs.contains("\(match.league.path)-\(teamID)") {
                return true
            }
            return favoriteNames.contains(side.displayName.lowercased())
        }
    }
}

private struct HomeHeroSection: View {
    let featuredPicks: [FeaturedEventPick]
    let featuredMatchesByPickID: [String: Match]
    let favoriteLiveMatches: [Match]
    let primeMatch: Match?

    private var favoriteLivePages: [Match] {
        let featuredMatchIDs = Set(featuredMatchesByPickID.values.map(\.id))
        return favoriteLiveMatches.filter { !featuredMatchIDs.contains($0.id) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let featuredPick = currentFeaturedPick(now: context.date)
            if let featuredPick {
                FeaturedEventCard(pick: featuredPick, match: featuredMatchesByPickID[featuredPick.id])
            } else if favoriteLivePages.count > 1 {
                TabView {
                    ForEach(favoriteLivePages) { match in
                        FavoriteLiveHeroCard(match: match)
                            .padding(.horizontal, 1)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .frame(height: 172)
            } else if let favoriteMatch = favoriteLivePages.first {
                FavoriteLiveHeroCard(match: favoriteMatch)
            } else if let primeMatch {
                PrimeMatchCard(match: primeMatch)
            }
        }
    }

    private func currentFeaturedPick(now: Date) -> FeaturedEventPick? {
        featuredPicks.first { pick in
            guard let endDate = pick.endDate else { return true }
            return endDate > now
        }
    }
}

private struct FeaturedEventCard: View {
    let pick: FeaturedEventPick
    let match: Match?

    private var isLive: Bool { match?.state == .live }
    private var accentColor: Color { isLive ? Theme.live : Theme.accent }
    private var sourceURL: URL? { URL(string: pick.source) }

    var body: some View {
        Group {
            if let match {
                NavigationLink(value: match) {
                    timelineContent
                }
                .buttonStyle(.plain)
            } else {
                timelineContent
            }
        }
    }

    private var timelineContent: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            cardContent(now: context.date)
        }
    }

    private func cardContent(now: Date) -> some View {
        let cardHeight: CGFloat = 172
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Image("FeaturedHeroBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: cardHeight)
                    .accessibilityHidden(true)

                LinearGradient(
                    colors: [
                        .black.opacity(0.82),
                        .black.opacity(0.56),
                        .black.opacity(0.14)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width, height: cardHeight)

                LinearGradient(
                    colors: [.black.opacity(0.38), .clear, .black.opacity(0.34)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: proxy.size.width, height: cardHeight)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Featured")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(accentColor.opacity(0.9), in: Capsule())
                        Text(pick.league)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    Text(pick.title)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.65), radius: 8, x: 0, y: 2)
                        .frame(maxWidth: min(285, proxy.size.width - 32), alignment: .leading)

                    HStack(spacing: 10) {
                        countdown(now: now)
                        action
                    }
                    .frame(maxWidth: proxy.size.width - 32, alignment: .leading)
                }
                .padding(16)
                .frame(width: proxy.size.width, height: cardHeight, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: cardHeight)
            .clipShape(cardShape)
            .overlay(cardShape.strokeBorder(.white.opacity(0.18)))
        }
        .frame(height: cardHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: Countdown

    @ViewBuilder private func countdown(now: Date) -> some View {
        if isLive, let match {
            HStack(spacing: 7) {
                PulsingLiveDot()
                Text(match.statusDetail)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                Text("\(match.away.score ?? "-")-\(match.home.score ?? "-")")
                    .font(.caption.weight(.black).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.live, in: Capsule())
        } else if let startDate = pick.startDate, startDate > now {
            let seconds = Int(startDate.timeIntervalSince(now))
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            let minutes = (seconds % 3_600) / 60

            premiumCountdown(firstValue: days > 0 ? days : hours,
                             firstUnit: days > 0 ? (days == 1 ? "DAY" : "DAYS") : "HR",
                             secondValue: days > 0 ? hours : minutes,
                             secondUnit: days > 0 ? "HR" : "MIN")
        } else {
            Label(pick.hasKnownStartTime ? timeText : pick.scheduleStatus, systemImage: "bolt.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(accentColor, in: Capsule())
        }
    }

    private func premiumCountdown(firstValue: Int, firstUnit: String, secondValue: Int, secondUnit: String) -> some View {
        HStack(spacing: 7) {
            PulsingClockIcon(color: accentColor)

            Text("STARTS IN")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%02d", firstValue))
                    Text(":")
                        .foregroundStyle(accentColor)
                    Text(String(format: "%02d", secondValue))
                }
                .font(.system(size: 16, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)

                HStack(spacing: 18) {
                    Text(firstUnit)
                    Text(secondUnit)
                }
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color(hex: 0x07101E, alpha: 0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accentColor.opacity(0.42)))
        .shadow(color: accentColor.opacity(0.22), radius: 8, x: 0, y: 0)
    }

    @ViewBuilder private var action: some View {
        if match != nil {
            actionLabel("Streams", systemImage: isLive ? "play.fill" : "arrow.right")
        } else if let sourceURL {
            Link(destination: sourceURL) {
                actionLabel("Info", systemImage: "safari.fill")
            }
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(accentColor.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.22)))
            .shadow(color: accentColor.opacity(0.28), radius: 10, x: 0, y: 0)
    }

    private var timeText: String {
        pick.hasKnownStartTime ? "\(pick.torontoTime) ET" : pick.scheduleStatus
    }
}

private struct PulsingClockIcon: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Image(systemName: "clock.fill")
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(color)
            .scaleEffect(pulsing ? 1.08 : 0.94)
            .opacity(pulsing ? 1 : 0.62)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// Small red dot that softly pulses to signal a live event.
private struct PulsingLiveDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.live)
            .frame(width: 10, height: 10)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

private struct FavoriteLiveHeroCard: View {
    let match: Match

    var body: some View {
        NavigationLink(value: match) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Favorite Team Live", systemImage: "star.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.live)
                    Spacer()
                    Text(match.league.shortName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 14) {
                    team(match.away)
                    Text("\(match.away.score ?? "-") - \(match.home.score ?? "-")")
                        .font(.title2.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 68)
                    team(match.home)
                }

                FlowLayout(spacing: 8) {
                    metadataPill(match.statusDetail, systemImage: "play.fill")
                    if !match.broadcasts.isEmpty {
                        metadataPill(match.broadcasts.prefix(2).joined(separator: ", "), systemImage: "tv")
                    }
                    if let venue = match.venue, !venue.isEmpty {
                        metadataPill(venue, systemImage: "mappin.and.ellipse")
                    }
                }
            }
            .padding(16)
            .background(
                LinearGradient(colors: [Theme.surfaceElevated, Theme.surface, Color(hex: 0x101A2A)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.live.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    private func team(_ side: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: side.logoURL, size: 44)
            Text(side.shortName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func metadataPill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

private struct PrimeMatchCard: View {
    let match: Match

    var body: some View {
        NavigationLink(value: match) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(match.state == .live ? "Prime Live Match" : "Prime Upcoming Match", systemImage: match.state == .live ? "dot.radiowaves.left.and.right" : "sparkles.tv")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(match.state == .live ? Theme.live : Theme.accent)
                    Spacer()
                    Text(match.league.shortName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 14) {
                    team(match.away)
                    Text(match.state == .pre ? "VS" : "\(match.away.score ?? "-") - \(match.home.score ?? "-")")
                        .font(.title2.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 68)
                    team(match.home)
                }

                HStack(spacing: 8) {
                    Text(match.statusDetail)
                    if !match.broadcasts.isEmpty {
                        Text("•")
                        Text(match.broadcasts.prefix(2).joined(separator: ", "))
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .background(
                LinearGradient(colors: [Theme.surfaceElevated, Theme.surface, Color(hex: 0x101A2A)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func team(_ side: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: side.logoURL, size: 44)
            Text(side.shortName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Horizontal strip of recently watched channels.
struct ContinueWatchingSection: View {
    let entries: [WatchHistoryEntry]
    let onPlay: (Channel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Continue Watching")
                Spacer()
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        if let channel = entry.saved.channel {
                            Button {
                                onPlay(channel)
                            } label: {
                                ContinueWatchingCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    let entry: WatchHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.surfaceElevated
                AsyncImage(url: entry.saved.channel?.logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(10)
                    } else {
                        Image(systemName: "play.tv.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .padding(6)
            }

            Text(entry.saved.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(entry.lastWatched.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 150)
    }
}

private struct LiveNowSection: View {
    let matches: [Match]
    let nextMatches: [Match]
    let startingSoon: [Match]
    @Binding var selectedSport: SportGroup?

    private var sports: [SportGroup] {
        SportGroup.allCases.filter { sport in
            matches.contains { $0.league.group == sport }
        }
    }

    private var displayedMatches: [Match] {
        guard let selectedSport else { return matches }
        return matches.filter { $0.league.group == selectedSport }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("Live Right Now")
                Spacer()
                if !matches.isEmpty {
                    Text("\(displayedMatches.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.live)

            if !sports.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        sportChip(title: "All", systemImage: "sportscourt", isSelected: selectedSport == nil) {
                            withAnimation(.snappy) { selectedSport = nil }
                        }
                        ForEach(sports) { sport in
                            sportChip(title: sport.rawValue, systemImage: sport.systemImage, isSelected: selectedSport == sport) {
                                withAnimation(.snappy) { selectedSport = sport }
                            }
                        }
                    }
                }
            }

            if matches.isEmpty {
                if nextMatches.isEmpty {
                    Text("No games are live across ESPN right now.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                } else {
                    startingSoonStrip(matches: startingSoon.isEmpty ? Array(nextMatches.prefix(3)) : startingSoon,
                                      title: "Starting Soon")
                }
            } else if displayedMatches.isEmpty {
                Text("No live games for this sport right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                ForEach(displayedMatches) { match in
                    NavigationLink(value: match) {
                        MatchRow(match: match)
                    }
                    .buttonStyle(.plain)
                }

                if !startingSoon.isEmpty {
                    startingSoonStrip(matches: startingSoon, title: "Starting Soon")
                        .padding(.top, 2)
                }
            }
        }
    }

    private func startingSoonStrip(matches: [Match], title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.fill")
                Text(title.uppercased())
                Spacer()
            }
            .font(.caption.weight(.heavy))
            .foregroundStyle(Color(hex: 0xE0A83D))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(matches) { match in
                        NavigationLink(value: match) {
                            StartingSoonCard(match: match)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sportChip(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Starting Soon

private struct StartingSoonSection: View {
    let matches: [Match]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.fill")
                Text("Starting Soon")
                Spacer()
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Color(hex: 0xE0A83D))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(matches) { match in
                        NavigationLink(value: match) {
                            StartingSoonCard(match: match)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct StartingSoonCard: View {
    let match: Match

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            cardContent(now: context.date)
        }
    }

    private func cardContent(now: Date) -> some View {
        let seconds = max(0, Int(match.date.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                TeamLogo(url: match.away.logoURL, size: 30)
                Text("vs")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5)
                TeamLogo(url: match.home.logoURL, size: 30)
            }

            Text(match.shortName)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 108)

            VStack(spacing: 2) {
                if hours > 0 {
                    Text(String(format: "%dh %02dm", hours, minutes))
                        .font(.system(size: 14, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color(hex: 0xE0A83D))
                } else if minutes > 0 {
                    Text(String(format: "%d:%02d", minutes, secs))
                        .font(.system(size: 14, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(minutes < 10 ? Theme.live : Color(hex: 0xE0A83D))
                } else {
                    Text("SOON")
                        .font(.system(size: 14, weight: .black).monospacedDigit())
                        .foregroundStyle(Theme.live)
                }

                Text(match.league.shortName.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 132)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(seconds < 600 ? Color(hex: 0xE0A83D).opacity(0.5) : Theme.hairline))
    }
}

// MARK: - Recent highlights strip

private struct RecentHighlightsSection: View {
    let highlights: [MatchHighlight]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                Text("Recent Highlights")
                    .font(.headline.weight(.bold))
                Spacer()
            }
            .foregroundStyle(Theme.accent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(highlights) { clip in
                        HighlightCard(clip: clip)
                    }
                }
            }
        }
    }
}

// MARK: - Home section list

private struct HomeSection: View {
    let title: String
    let systemImage: String
    let tint: Color
    let matches: [Match]
    let emptyText: String
    /// Maximum rows to show; nil shows every match.
    var limit: Int? = 5

    private var displayedMatches: [Match] {
        limit.map { Array(matches.prefix($0)) } ?? matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
                if !matches.isEmpty {
                    Text("\(matches.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(tint)

            if matches.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                ForEach(displayedMatches) { match in
                    NavigationLink(value: match) {
                        MatchRow(match: match)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
