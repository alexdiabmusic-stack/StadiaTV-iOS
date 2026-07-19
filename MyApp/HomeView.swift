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
            await viewModel.load(leagues: prefs.followedLeagues, favorites: prefs.favoriteTeams, notificationsEnabled: prefs.matchNotificationsEnabled, notificationLeadTime: prefs.matchReminderLeadTime)
        }
        .refreshable {
            await viewModel.load(leagues: prefs.followedLeagues, favorites: prefs.favoriteTeams, notificationsEnabled: prefs.matchNotificationsEnabled, notificationLeadTime: prefs.matchReminderLeadTime, force: true)
        }
    }

    private var loadPreferencesKey: String {
        [
            prefs.followedLeagues.map(\.id).sorted().joined(separator: ","),
            prefs.favoriteTeams.map(\.id).sorted().joined(separator: ","),
            prefs.matchNotificationsEnabled ? "notifications-on" : "notifications-off",
            "lead-\(prefs.matchReminderLeadTime.rawValue)"
        ].joined(separator: "|")
    }

    @ViewBuilder private var content: some View {
        if viewModel.isLoading && viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            ProgressView().tint(Theme.accent)
        } else if let message = viewModel.errorMessage, viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42))
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
                        featuredPick: viewModel.featuredPick,
                        featuredMatch: viewModel.featuredMatch,
                        favoriteLiveMatches: viewModel.favoriteTeamLiveMatches,
                        primeMatch: viewModel.primeMatch
                    )

                    HomeSection(title: "Your Teams Today", systemImage: "star.fill", tint: Theme.accent, matches: viewModel.favoriteTeamMatchesToday, emptyText: prefs.favoriteTeams.isEmpty ? "Favorite teams in setup or settings to see them here." : "No games today for your favorite teams.")
                    LiveNowSection(matches: viewModel.liveNow, selectedSport: $selectedLiveSport)
                    HomeSection(title: "Upcoming Games", systemImage: "calendar", tint: Color(hex: 0x3DBE6B), matches: viewModel.upcoming, emptyText: "No upcoming games found for your followed leagues.")

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
    @Published private(set) var upcoming: [Match] = []
    @Published private(set) var featuredPick: FeaturedEventPick?
    @Published private(set) var featuredMatch: Match?
    @Published private(set) var primeMatch: Match?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service = ESPNService()
    private let featuredCalendar = FeaturedEventCalendar.shared

    // Cache bookkeeping so revisiting the tab doesn't refetch everything.
    private var lastLoadedLeagueIDs: Set<String> = []
    private var lastLoadedAt: Date?
    private let cacheLifetime: TimeInterval = 120

    func load(leagues: [League], favorites: [FavoriteTeam], notificationsEnabled: Bool = false, notificationLeadTime: MatchReminderLeadTime = .thirty, force: Bool = false) async {
        let leagueIDs = Set(leagues.map(\.id))
        featuredPick = featuredCalendar.pick()
        let hasData = !(liveNow.isEmpty && upcoming.isEmpty && favoriteTeamMatchesToday.isEmpty)
        if !force, hasData, leagueIDs == lastLoadedLeagueIDs,
           let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < cacheLifetime {
            return
        }
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
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
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteNames: favoriteNames)
            }
        }

        isLoading = false
        if matchesByLeague.isEmpty {
            errorMessage = "ESPN did not return games for your followed leagues."
        }

        // Phase 2: sweep the rest of the catalog for today's games in the
        // background so Live Right Now spans all sports.
        await withTaskGroup(of: (String, [Match]).self) { group in
            for league in League.all where !leagueIDs.contains(league.id) {
                group.addTask {
                    (league.id, (try? await self.service.scoreboard(for: league, on: Date())) ?? [])
                }
            }
            for await (id, matches) in group {
                guard !matches.isEmpty else { continue }
                matchesByLeague[id] = matches
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteNames: favoriteNames)
            }
        }

        if notificationsEnabled {
            await MatchNotificationService.shared.syncNotifications(
                matches: matchesByLeague.values.flatMap { $0 },
                favorites: favorites,
                leadTime: notificationLeadTime
            )
        }

        if !Task.isCancelled, !matchesByLeague.isEmpty {
            errorMessage = nil
            lastLoadedLeagueIDs = leagueIDs
            lastLoadedAt = Date()
        }
    }

    /// Recomputes the published sections from everything fetched so far.
    private func rebuildSections(matchesByLeague: [String: [Match]], followedIDs: Set<String>, favoriteNames: Set<String>) {
        let calendar = Calendar.current
        let allMatches = matchesByLeague.values.flatMap { $0 }
        let followedMatches = matchesByLeague
            .filter { followedIDs.contains($0.key) }
            .values.flatMap { $0 }

        liveNow = allMatches
            .filter { $0.state == .live }
            .sorted { primeScore($0, favoriteNames: favoriteNames) > primeScore($1, favoriteNames: favoriteNames) }
        favoriteTeamLiveMatches = liveNow
            .filter { involvesFavorite($0, favoriteNames: favoriteNames) }
        favoriteTeamMatchesToday = followedMatches
            .filter { match in
                calendar.isDateInToday(match.date) && involvesFavorite(match, favoriteNames: favoriteNames)
            }
            .sorted { $0.date < $1.date }
        upcoming = followedMatches
            .filter { $0.state == .pre && $0.date >= Date() }
            .sorted { primeScore($0, favoriteNames: favoriteNames) > primeScore($1, favoriteNames: favoriteNames) }
            .prefix(12)
            .map { $0 }
        featuredMatch = allMatches
            .filter { featuredCalendar.matchingPick(for: $0) != nil }
            .sorted { primeScore($0, favoriteNames: favoriteNames) > primeScore($1, favoriteNames: favoriteNames) }
            .first
        primeMatch = (liveNow + favoriteTeamMatchesToday + upcoming)
            .sorted { primeScore($0, favoriteNames: favoriteNames) > primeScore($1, favoriteNames: favoriteNames) }
            .first
    }

    private func primeScore(_ match: Match, favoriteNames: Set<String> = []) -> Int {
        var score = eventDemandScore(match)
        if match.state == .live { score += 100 }
        if involvesFavorite(match, favoriteNames: favoriteNames) { score += 50 }
        if !match.broadcasts.isEmpty { score += 20 }
        score -= max(0, Int(match.date.timeIntervalSinceNow / 3600))
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

    private func involvesFavorite(_ match: Match, favoriteNames: Set<String>) -> Bool {
        guard !favoriteNames.isEmpty else { return false }
        return favoriteNames.contains(match.home.displayName.lowercased()) || favoriteNames.contains(match.away.displayName.lowercased())
    }
}

private struct HomeHeroSection: View {
    let featuredPick: FeaturedEventPick?
    let featuredMatch: Match?
    let favoriteLiveMatches: [Match]
    let primeMatch: Match?

    private var favoriteLivePages: [Match] {
        favoriteLiveMatches.filter { $0.id != featuredMatch?.id }
    }

    var body: some View {
        let pageCount = (featuredPick == nil ? 0 : 1) + favoriteLivePages.count

        if pageCount > 1 {
            TabView {
                if let featuredPick {
                    FeaturedEventCard(pick: featuredPick, match: featuredMatch)
                        .padding(.horizontal, 1)
                }

                ForEach(favoriteLivePages) { match in
                    FavoriteLiveHeroCard(match: match)
                        .padding(.horizontal, 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 172)
        } else if let featuredPick {
            FeaturedEventCard(pick: featuredPick, match: featuredMatch)
        } else if let favoriteMatch = favoriteLivePages.first {
            FavoriteLiveHeroCard(match: favoriteMatch)
        } else if let primeMatch {
            PrimeMatchCard(match: primeMatch)
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

            HStack(spacing: 5) {
                if days > 0 {
                    countdownBlock(days, days == 1 ? "DAY" : "DAYS", color: Color(hex: 0xF5B84B))
                }
                countdownBlock(hours, "HR", color: accentColor)
                countdownBlock(minutes, "MIN", color: Color(hex: 0x37C871))
            }
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

    private func countdownBlock(_ value: Int, _ unit: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(String(format: "%02d", value))
                .font(.system(size: 15, weight: .black, design: .rounded).monospacedDigit())
            Text(unit)
                .font(.system(size: 8, weight: .black))
                .baselineOffset(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(color, in: Capsule())
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
            .foregroundStyle(accentColor)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(accentColor.opacity(0.3)))
    }

    private var timeText: String {
        pick.hasKnownStartTime ? "\(pick.torontoTime) ET" : pick.scheduleStatus
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
                Text("No games are live across ESPN right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
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
