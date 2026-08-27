#if os(tvOS)
import SwiftUI

struct TVFollowingView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @StateObject private var viewModel = MatchesViewModel()

    @State private var selectedEntityID: String = "all"

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if !hasFollowingContent && fantasyStore.currentConnection == nil {
                    TVEmptyState(
                        systemImage: "star.circle",
                        title: "Nothing followed yet",
                        subtitle: "Go to Settings to follow teams and leagues or connect ESPN Fantasy."
                    )
                } else if viewModel.isLoadingFollowing && viewModel.allFollowedMatches.isEmpty && selectedEntityID != "fantasy" {
                    ProgressView().tint(Theme.accent).scaleEffect(2)
                } else {
                    mainContent
                }
            }
            .navigationTitle("Following")
            .navigationDestination(for: Match.self) { TVMatchDetailView(match: $0) }
        }
        .tint(Theme.accent)
        .task(id: loadKey) {
            await viewModel.loadFollowing(
                leagues: prefs.explicitlyFollowedLeagues,
                favorites: prefs.favoriteTeams
            )
            viewModel.startAutoRefresh()
        }
        .onDisappear { viewModel.stopAutoRefresh() }
        .onChange(of: prefs.favoriteTeams) { _, _ in
            withAnimation(.snappy) { selectedEntityID = "all" }
        }
    }

    private var hasFollowingContent: Bool {
        !prefs.favoriteTeams.isEmpty || !prefs.explicitlyFollowedLeagues.isEmpty
    }

    private var loadKey: String {
        [
            prefs.explicitlyFollowedLeagues.map(\.id).sorted().joined(separator: ","),
            prefs.favoriteTeams.map(\.id).sorted().joined(separator: ",")
        ].joined(separator: "|")
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 48) {
                entitySelectorRow

                if selectedEntityID == "fantasy" {
                    TVFantasyDashboardSection()
                        .padding(.horizontal, 48)
                } else {
                    sportsSummaryRow
                        .padding(.horizontal, 48)

                    if let live = liveMatches.first {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("Live Now", systemImage: "dot.radiowaves.left.and.right")
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(Theme.live)
                            .padding(.horizontal, 52)
                        NavigationLink(value: live) {
                            TVFollowingLiveHero(match: live)
                        }
                        .buttonStyle(.card)
                        .padding(.horizontal, 48)
                    }
                } else if let next = nextUpcoming {
                    upNextHero(for: next)
                        .padding(.horizontal, 48)
                }

                if upcomingMatches.count > (nextUpcoming != nil ? 1 : 0) {
                    let remaining = nextUpcoming != nil ? Array(upcomingMatches.dropFirst()) : upcomingMatches
                    if !remaining.isEmpty {
                        TVShelfRow(title: "Coming Up", systemImage: "calendar", tint: Color(hex: 0x3DBE6B)) {
                            ForEach(remaining.prefix(12)) { match in
                                NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                            }
                        }
                    }
                }

                if !recentResults.isEmpty {
                    TVShelfRow(title: "Recent Results", systemImage: "flag.checkered", tint: Theme.textSecondary) {
                        ForEach(recentResults.prefix(10)) { match in
                            NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                        }
                    }
                }

                    if selectedMatches.isEmpty && !viewModel.isLoadingFollowing {
                        TVEmptyState(
                            systemImage: "calendar.badge.exclamationmark",
                            title: "No matches found",
                            subtitle: "No upcoming or recent matches for this selection."
                        )
                    }
                }
            }
            .padding(.vertical, 40)
        }
    }

    // MARK: - Entity Selector Row

    private var entitySelectorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                entityChip(title: "All", id: "all", logoURL: nil)
                entityChip(title: "Fantasy", id: "fantasy", logoURL: nil)
                ForEach(prefs.favoriteTeams) { team in
                    let abbr = team.abbreviation.isEmpty
                        ? String(team.displayName.prefix(3)).uppercased()
                        : team.abbreviation
                    entityChip(title: abbr, id: "team-\(team.id)", logoURL: team.logoURL)
                }
                ForEach(leagueChips) { league in
                    entityChip(title: league.shortName, id: "league-\(league.id)", logoURL: nil)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 8)
        }
    }

    private func entityChip(title: String, id: String, logoURL: URL?) -> some View {
        let selected = selectedEntityID == id
        return Button {
            withAnimation(.snappy) { selectedEntityID = id }
        } label: {
            HStack(spacing: 6) {
                if let logoURL {
                    TVTeamLogo(url: logoURL, size: 22)
                }
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(selected ? .white : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                selected ? Theme.accent : Theme.surface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sports Summary Row

    private var sportsSummaryRow: some View {
        HStack(spacing: 0) {
            summaryItem(
                icon: liveMatches.isEmpty ? "circle" : "circle.fill",
                value: "\(liveMatches.count)",
                label: "Live",
                tint: liveMatches.isEmpty ? Theme.textTertiary : Theme.live,
                prominent: !liveMatches.isEmpty
            )
            summaryDivider
            summaryItem(
                icon: "calendar",
                value: "\(todayMatches.count)",
                label: "Today",
                tint: Theme.upcoming,
                prominent: false
            )
            summaryDivider
            summaryItem(
                icon: "bell",
                value: "\(thisWeekMatches.count)",
                label: "This Week",
                tint: Theme.starting,
                prominent: false
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }

    private func summaryItem(icon: String, value: String, label: String, tint: Color, prominent: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(prominent ? tint : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(prominent ? tint : Theme.textPrimary)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 20)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 32)
    }

    // MARK: - Up Next Hero

    private func upNextHero(for match: Match) -> some View {
        NavigationLink(value: match) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.surface, Theme.surfaceElevated],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.25))
                    )

                HStack(spacing: 0) {
                    upNextTeam(side: match.away)

                    VStack(spacing: 14) {
                        Text("UP NEXT")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.accent)
                            .tracking(1.5)

                        Text("VS")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))

                        Text(match.league.shortName.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                            .tracking(1)

                        Text(match.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)

                        Label("Match Centre", systemImage: "arrow.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 11)
                            .background(Theme.accent, in: Capsule())
                    }
                    .frame(maxWidth: 300)

                    upNextTeam(side: match.home)
                }
                .padding(.vertical, 44)
                .padding(.horizontal, 40)
            }
        }
        .buttonStyle(.card)
    }

    private func upNextTeam(side: TeamSide) -> some View {
        VStack(spacing: 12) {
            TVTeamLogo(url: side.logoURL, size: 90)
            Text(side.displayName)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let record = side.record {
                Text(record)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived Data

    private var selectedMatches: [Match] {
        if selectedEntityID == "all" { return viewModel.allFollowedMatches }
        if let team = prefs.favoriteTeams.first(where: { "team-\($0.id)" == selectedEntityID }) {
            return viewModel.allFollowedMatches.filter { matchIncludes($0, team: team) }
        }
        if let league = League.all.first(where: { "league-\($0.id)" == selectedEntityID }) {
            return viewModel.allFollowedMatches.filter { $0.league.id == league.id }
        }
        return viewModel.allFollowedMatches
    }

    private var liveMatches: [Match] {
        selectedMatches.filter { $0.state == .live }
    }

    private var upcomingMatches: [Match] {
        selectedMatches
            .filter { $0.state == .pre && $0.date >= Date() && !isTBDMatch($0) }
            .sorted { $0.date < $1.date }
    }

    private var nextUpcoming: Match? {
        upcomingMatches.first
    }

    private var recentResults: [Match] {
        selectedMatches
            .filter { $0.state == .final }
            .sorted { $0.date > $1.date }
    }

    private var todayMatches: [Match] {
        selectedMatches.filter { Calendar.current.isDateInToday($0.date) && $0.state != .final }
    }

    private var thisWeekMatches: [Match] {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return selectedMatches.filter { $0.state == .pre && $0.date >= Date() && $0.date <= end }
    }

    private var leagueChips: [League] {
        let favLeagueIDs = Set(prefs.favoriteTeams.map(\.leaguePath))
        return League.all.filter {
            prefs.isLeagueSelected($0) && !favLeagueIDs.contains($0.id)
        }.prefix(6).map { $0 }
    }

    private func isTBDMatch(_ match: Match) -> Bool {
        let a = match.away.displayName.lowercased().trimmingCharacters(in: .whitespaces)
        let h = match.home.displayName.lowercased().trimmingCharacters(in: .whitespaces)
        return (a == "tbd" || a.isEmpty) && (h == "tbd" || h.isEmpty)
    }

    private func matchIncludes(_ match: Match, team: FavoriteTeam) -> Bool {
        guard match.league.path == team.leaguePath else { return false }
        return [match.home, match.away].contains { side in
            if let tid = side.teamID, !tid.isEmpty, !team.teamID.isEmpty {
                return tid == team.teamID
            }
            let sideNames = [side.displayName, side.shortName, side.abbreviation]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            let favNames = [team.displayName, team.abbreviation]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return sideNames.contains { s in favNames.contains { f in s == f } }
        }
    }
}

// MARK: - Following Live Hero (TV)

private struct TVFollowingLiveHero: View {
    let match: Match

    private var isRacing: Bool { match.league.group == .racing }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(
                            stops: [
                                .init(color: Theme.live.opacity(0.18), location: 0),
                                .init(color: .clear, location: 0.65)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.live.opacity(0.3))
                )

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TVLiveBadge()
                        Text(match.league.shortName.uppercased())
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.textSecondary)
                            .tracking(0.5)
                    }

                    if isRacing {
                        Text(match.name)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(match.statusDetail)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.live)
                    } else {
                        HStack(spacing: 0) {
                            VStack(spacing: 10) {
                                TVTeamLogo(url: match.away.logoURL, size: 64)
                                Text(match.away.shortName)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 6) {
                                HStack(spacing: 14) {
                                    Text(match.away.score ?? "-")
                                    Text("–").foregroundStyle(Theme.textTertiary)
                                    Text(match.home.score ?? "-")
                                }
                                .font(.system(size: 48, weight: .black, design: .rounded).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)

                                Text(match.statusDetail)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.live)
                                    .lineLimit(1)
                            }

                            VStack(spacing: 10) {
                                TVTeamLogo(url: match.home.logoURL, size: 64)
                                Text(match.home.shortName)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Text("Open Match Centre →")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.live.opacity(0.75))
                        .padding(.top, 4)
                }
                .padding(36)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TVFantasyDashboardSection: View {
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Label("Fantasy", systemImage: "star.circle.fill")
                .font(.title2.weight(.heavy))
                .foregroundStyle(Theme.accent)

            if fantasyStore.currentConnection == nil {
                TVEmptyState(
                    systemImage: "star.bubble.fill",
                    title: "Connect ESPN Fantasy",
                    subtitle: "Open Settings → Fantasy to connect an ESPN Fantasy league."
                )
            } else {
                HStack(spacing: 18) {
                    summaryCard(title: "League", value: fantasyStore.selectedLeague?.name ?? fantasyStore.currentConnection?.provider.displayName ?? "Fantasy", systemImage: "trophy.fill", tint: Theme.accent)
                    summaryCard(title: "Roster", value: "\(fantasyStore.players.count) players", systemImage: "person.3.fill", tint: Theme.upcoming)
                    summaryCard(title: "Watchable", value: "\(fantasyStore.diagnostics.watchableGameCount) games", systemImage: "play.tv.fill", tint: Theme.live)
                }

                if !fantasyStore.livePlayerGames.isEmpty {
                    TVShelfRow(title: "Players Live", systemImage: "dot.radiowaves.left.and.right", tint: Theme.live) {
                        ForEach(fantasyStore.livePlayerGames.prefix(8)) { game in
                            TVFantasyPlayerCard(game: game)
                        }
                    }
                } else if !fantasyStore.todayPlayerGames.isEmpty {
                    TVShelfRow(title: "Today", systemImage: "calendar", tint: Theme.upcoming) {
                        ForEach(fantasyStore.todayPlayerGames.prefix(8)) { game in
                            TVFantasyPlayerCard(game: game)
                        }
                    }
                } else {
                    TVEmptyState(
                        systemImage: "calendar",
                        title: "No Fantasy games today",
                        subtitle: fantasyStore.isStale ? "Showing cached Fantasy information." : "Your linked roster has no games today."
                    )
                }
            }
        }
        .task {
            await fantasyStore.refresh(channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages)
        }
    }

    private func summaryCard(title: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(title.uppercased())
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 260, height: 140, alignment: .leading)
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct TVFantasyPlayerCard: View {
    let game: FantasyPlayerGame

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(game.fantasyPlayer.fullName)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if let event = game.event {
                Text(event.statusDetail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(game.gameState == .live ? Theme.live : Theme.textTertiary)
            }
            Spacer()
            Text(game.watchAvailable ? "Watch available" : "No channel")
                .font(.caption.weight(.bold))
                .foregroundStyle(game.watchAvailable ? Theme.live : Theme.textSecondary)
        }
        .frame(width: 280, height: 150, alignment: .leading)
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(game.gameState == .live ? Theme.live.opacity(0.35) : Theme.hairline))
    }

    private var subtitle: String {
        [game.fantasyPlayer.teamAbbreviation, game.fantasyPlayer.position].compactMap { $0 }.joined(separator: " · ")
    }
}
#endif
