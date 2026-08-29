import SwiftUI

// MARK: - Sport-aware Game Centre routing

enum GameCentreArchetype: String, CaseIterable, Hashable {
    case teamSport
    case golf
    case motorsport
    case tennis
    case combatSport

    init(match: Match) {
        switch match.league.group {
        case .golf:
            self = .golf
        case .racing:
            self = .motorsport
        case .tennis:
            self = .tennis
        case .wrestling:
            self = .combatSport
        default:
            let text = "\(match.league.name) \(match.league.shortName) \(match.name) \(match.shortName)"
                .lowercased()
            if text.contains("ufc") || text.contains("mma") || text.contains("boxing") || text.contains("fight") {
                self = .combatSport
            } else {
                self = .teamSport
            }
        }
    }

    var title: String {
        switch self {
        case .teamSport, .tennis: return "Game Centre"
        case .golf: return "Tournament Centre"
        case .motorsport: return "Race Centre"
        case .combatSport: return "Event Centre"
        }
    }

    var systemImage: String {
        switch self {
        case .teamSport: return "sportscourt.fill"
        case .golf: return "flag.fill"
        case .motorsport: return "flag.checkered"
        case .tennis: return "figure.tennis"
        case .combatSport: return "figure.boxing"
        }
    }

    var usesHeadToHeadParticipantUI: Bool {
        switch self {
        case .teamSport, .tennis: return true
        case .golf, .motorsport, .combatSport: return false
        }
    }
}

struct GameCentreContainerView: View {
    let match: Match
    let gameSummary: GameSummary?
    let golfTournament: StadiaGolfTournament?
    let isLoadingGolfTournament: Bool
    let didAttemptGolfTournamentLoad: Bool
    let isLoadingGameSummary: Bool
    let didAttemptGameSummaryLoad: Bool
    let isPremium: Bool
    @Binding var showPaywall: Bool
    let reloadGameSummary: () -> Void

    private var archetype: GameCentreArchetype { GameCentreArchetype(match: match) }

    var body: some View {
        Group {
            if isPremium {
                content
            } else {
                ZStack {
                    content
                        .blur(radius: 8)
                        .allowsHitTesting(false)
                    PremiumGateOverlay(
                        icon: archetype.systemImage,
                        title: archetype.title,
                        description: premiumDescription,
                        showPaywall: $showPaywall
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch archetype {
        case .teamSport:
            TeamSportGameCentre(match: match,
                                gameSummary: gameSummary,
                                isLoadingGameSummary: isLoadingGameSummary,
                                didAttemptGameSummaryLoad: didAttemptGameSummaryLoad,
                                reloadGameSummary: reloadGameSummary)
        case .golf:
            GolfGameCentre(match: match,
                           tournament: golfTournament,
                           isLoadingTournament: isLoadingGolfTournament,
                           didAttemptTournamentLoad: didAttemptGolfTournamentLoad)
        case .motorsport:
            MotorsportGameCentre(match: match)
        case .tennis:
            TennisGameCentre(match: match,
                             gameSummary: gameSummary,
                             isLoadingGameSummary: isLoadingGameSummary,
                             didAttemptGameSummaryLoad: didAttemptGameSummaryLoad,
                             reloadGameSummary: reloadGameSummary)
        case .combatSport:
            CombatGameCentre(match: match, gameSummary: gameSummary)
        }
    }

    private var premiumDescription: String {
        switch archetype {
        case .teamSport:
            return "Players, live stats, standings and deep team analytics."
        case .golf:
            return "Tournament leaderboard, field and course context."
        case .motorsport:
            return "Classification, driver field and live timing context."
        case .tennis:
            return "Match state, player stats and tournament context."
        case .combatSport:
            return "Fight card, event details and bout context."
        }
    }
}

struct GameCentreEventHeader: View {
    let match: Match
    let gameSummary: GameSummary?
    let golfTournament: StadiaGolfTournament?
    let spoilerFreeMode: Bool
    let spoilerRevealed: Bool
    let revealScore: () -> Void

    private var archetype: GameCentreArchetype { GameCentreArchetype(match: match) }

    var body: some View {
        switch archetype {
        case .golf:
            GolfTournamentHero(match: match, tournament: golfTournament)
        case .motorsport:
            MotorsportEventHero(match: match)
        case .combatSport:
            CombatEventHero(match: match)
        case .teamSport, .tennis:
            TeamSportEventHero(match: match,
                               spoilerFreeMode: spoilerFreeMode,
                               spoilerRevealed: spoilerRevealed,
                               revealScore: revealScore)
        }
    }
}

// MARK: - Shared components

struct GameCentreSegmentedPicker<Tab: RawRepresentable & Hashable & Identifiable>: View where Tab.RawValue == String {
    let tabs: [Tab]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.snappy) { selection = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == tab ? .white : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(selection == tab ? Theme.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct GameCentreEmptyState: View {
    let systemImage: String
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct GameCentreLoadingState: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct GameCentreLinkTile<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Event headers

private struct TeamSportEventHero: View {
    let match: Match
    let spoilerFreeMode: Bool
    let spoilerRevealed: Bool
    let revealScore: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            statusLine
            HStack(alignment: .center) {
                teamColumn(match.away)
                VStack(spacing: 4) {
                    if match.state == .pre {
                        Text("VS").font(.headline).foregroundStyle(Theme.textSecondary)
                    } else if spoilerFreeMode && match.state == .final && !spoilerRevealed {
                        VStack(spacing: 6) {
                            Text("? - ?")
                                .font(.title.weight(.heavy).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                            Button("Reveal Score", action: revealScore)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.accent)
                        }
                    } else {
                        Text("\(match.away.score ?? "-")  -  \(match.home.score ?? "-")")
                            .font(.title.weight(.heavy).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                teamColumn(match.home)
            }
            if let venue = match.venue {
                Label(venue, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !match.broadcasts.isEmpty {
                Label(match.broadcasts.joined(separator: ", "), systemImage: "tv")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if match.state == .live { Circle().fill(Theme.live).frame(width: 7, height: 7) }
            Text(match.statusDetail)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func teamColumn(_ side: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: side.logoURL, size: 56)
            Text(side.shortName)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GolfTournamentHero: View {
    let match: Match
    let tournament: StadiaGolfTournament?

    private var leaderboard: [GolfLeaderboardEntry] {
        GolfTournamentData(match: match, tournament: tournament).leaderboard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                if match.state == .live { Circle().fill(Theme.live).frame(width: 7, height: 7) }
                Text(statusText)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
                Spacer()
            }

            Text(tournament?.tournamentName ?? (match.name.isEmpty ? match.league.name : match.name))
                .font(.headline.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            if leaderboard.isEmpty {
                Text(match.state == .pre ? "Leaderboard will appear when tournament scoring is available." : "Leaderboard is not available yet.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(leaderboard.prefix(3).enumerated()), id: \.element.id) { index, entry in
                        GolfLeaderboardCompactRow(entry: entry)
                        if index < min(leaderboard.count, 3) - 1 { Divider().overlay(Theme.hairline) }
                    }
                }
            }

            let metadata = heroMetadata
            if !metadata.isEmpty {
                Text(metadata.joined(separator: "  •  "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var statusText: String {
        switch match.state {
        case .live: return "LIVE · \(roundLabel)"
        case .final: return "FINAL"
        case .pre: return match.statusDetail.isEmpty ? "UPCOMING" : match.statusDetail.uppercased()
        }
    }

    private var roundLabel: String {
        let upper = match.statusDetail.uppercased()
        if upper.contains("ROUND") { return upper }
        return upper.isEmpty ? "IN PROGRESS" : upper
    }

    private var heroMetadata: [String] {
        var values: [String] = []
        if let cutLine = tournament?.cutLine, !cutLine.isEmpty { values.append("CUT \(cutLine)") }
        if let par = tournament?.course?.par { values.append("PAR \(par)") }
        if let venue = tournament?.course?.name ?? match.venue, !venue.isEmpty { values.append(venue) }
        if let broadcast = tournament?.broadcasts.first?.network ?? match.broadcasts.first, !broadcast.isEmpty { values.append(broadcast) }
        return values
    }
}

private struct MotorsportEventHero: View {
    let match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(match.state == .live ? "LIVE · \(match.statusDetail)" : match.statusDetail, systemImage: "flag.checkered")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
            Text(match.name.isEmpty ? match.league.name : match.name)
                .font(.title3.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if !match.broadcasts.isEmpty {
                Label(match.broadcasts.joined(separator: ", "), systemImage: "tv")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct CombatEventHero: View {
    let match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(match.statusDetail, systemImage: "figure.boxing")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
            Text(match.name.isEmpty ? match.league.name : match.name)
                .font(.title3.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if !match.broadcasts.isEmpty {
                Label(match.broadcasts.joined(separator: ", "), systemImage: "tv")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Team sports

private enum TeamSportGameCentreTab: String, CaseIterable, Identifiable {
    case players = "Players"
    case gameStats = "Game Stats"
    case standings = "Standings"
    var id: String { rawValue }

    static func initial(for match: Match) -> TeamSportGameCentreTab {
        match.state == .pre ? .players : .gameStats
    }
}

private enum GameCentreTeamSide: String, Hashable {
    case away
    case home
}

private struct TeamSportGameCentre: View {
    let match: Match
    let gameSummary: GameSummary?
    let isLoadingGameSummary: Bool
    let didAttemptGameSummaryLoad: Bool
    let reloadGameSummary: () -> Void

    @State private var selectedTab: TeamSportGameCentreTab
    @State private var selectedTeam: GameCentreTeamSide = .away
    @State private var rosterPreviewByTeamID: [String: [RosterAthlete]] = [:]
    @State private var selectedRosterPosition: String?
    @State private var isShowingFullRosterPreview = false

    init(match: Match, gameSummary: GameSummary?, isLoadingGameSummary: Bool, didAttemptGameSummaryLoad: Bool, reloadGameSummary: @escaping () -> Void) {
        self.match = match
        self.gameSummary = gameSummary
        self.isLoadingGameSummary = isLoadingGameSummary
        self.didAttemptGameSummaryLoad = didAttemptGameSummaryLoad
        self.reloadGameSummary = reloadGameSummary
        _selectedTab = State(initialValue: TeamSportGameCentreTab.initial(for: match))
    }

    private var selectedSide: TeamSide { selectedTeam == .away ? match.away : match.home }
    private var selectedTeamID: String? { selectedSide.teamID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Game Centre", systemImage: "sportscourt.fill")
            GameCentreSegmentedPicker(tabs: TeamSportGameCentreTab.allCases, selection: $selectedTab)
            switch selectedTab {
            case .players:
                playersTab
            case .gameStats:
                TeamSportStatsTab(match: match,
                                  gameSummary: gameSummary,
                                  isLoadingGameSummary: isLoadingGameSummary,
                                  didAttemptGameSummaryLoad: didAttemptGameSummaryLoad,
                                  reloadGameSummary: reloadGameSummary)
            case .standings:
                MatchStandingsPreview(
                    league: match.league,
                    highlightedTeamIDs: Set([match.away.teamID, match.home.teamID].compactMap { $0 })
                )
            }
        }
        .task(id: selectedTeamID) { await loadSelectedRoster() }
    }

    @ViewBuilder
    private var playersTab: some View {
        Picker("Team", selection: $selectedTeam) {
            Text(match.away.shortName).tag(GameCentreTeamSide.away)
            Text(match.home.shortName).tag(GameCentreTeamSide.home)
        }
        .pickerStyle(.segmented)

        if let teamID = selectedTeamID {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TeamLogo(url: selectedSide.logoURL, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedSide.displayName)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let record = selectedSide.record, !record.isEmpty {
                            Text(record)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                }

                GameCentreTeamRosterPreview(league: match.league,
                                            teamID: teamID,
                                            teamName: selectedSide.shortName,
                                            athletes: rosterPreviewByTeamID[teamID] ?? [],
                                            selectedPosition: $selectedRosterPosition,
                                            isShowingAll: $isShowingFullRosterPreview)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    GameCentreLinkTile(title: "Players", subtitle: "Roster", systemImage: "person.3.fill") {
                        TeamRosterView(league: match.league, teamID: teamID, teamName: selectedSide.shortName)
                    }
                    GameCentreLinkTile(title: "Leaders", subtitle: match.league.shortName, systemImage: "chart.bar.fill") {
                        LeadersView(league: match.league)
                    }
                    GameCentreLinkTile(title: "Injuries", subtitle: "Report", systemImage: "cross.case.fill") {
                        InjuriesView(league: match.league)
                    }
                }
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        } else {
            GameCentreEmptyState(systemImage: "person.3.sequence", message: "Team roster data is not available for this event.")
        }
    }

    private func loadSelectedRoster() async {
        selectedRosterPosition = nil
        isShowingFullRosterPreview = false
        guard let teamID = selectedTeamID, rosterPreviewByTeamID[teamID] == nil else { return }
        rosterPreviewByTeamID[teamID] = (try? await SportsRepository.shared.legacyRoster(for: match.league, teamID: teamID).flatMap(\.athletes)) ?? []
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
        }
        .font(.headline.weight(.bold))
        .foregroundStyle(Theme.accent)
    }
}

private struct TeamSportStatsTab: View {
    let match: Match
    let gameSummary: GameSummary?
    let isLoadingGameSummary: Bool
    let didAttemptGameSummaryLoad: Bool
    let reloadGameSummary: () -> Void

    var body: some View {
        if let summary = gameSummary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let awayBox, let homeBox, !awayBox.stats.isEmpty {
                    statComparison(away: awayBox, home: homeBox)
                }
                if !summary.leaders.isEmpty {
                    gameLeaders(summary.leaders)
                }
            }
        } else if match.state == .pre {
            GameCentreEmptyState(systemImage: "chart.bar.xaxis", message: "Stats available once the game begins")
        } else if isLoadingGameSummary && !didAttemptGameSummaryLoad {
            GameCentreLoadingState(message: "Loading stats...")
        } else {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(Theme.textSecondary)
                Text(match.state == .live ? "Stats are not available yet." : "Stats are not available for this game.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Try Again", action: reloadGameSummary)
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private var awayBox: GameSummary.TeamBox? { teamBox(for: match.away, fallbackIndex: 0) }
    private var homeBox: GameSummary.TeamBox? { teamBox(for: match.home, fallbackIndex: 1) }

    private func teamBox(for side: TeamSide, fallbackIndex: Int) -> GameSummary.TeamBox? {
        guard let gameSummary else { return nil }
        if let id = side.teamID, let box = gameSummary.teams.first(where: { $0.id == id }) { return box }
        return gameSummary.teams.indices.contains(fallbackIndex) ? gameSummary.teams[fallbackIndex] : nil
    }

    private func statComparison(away: GameSummary.TeamBox, home: GameSummary.TeamBox) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(away.abbreviation.isEmpty ? match.away.abbreviation : away.abbreviation)
                    .frame(width: 74, alignment: .leading)
                Spacer()
                Text(home.abbreviation.isEmpty ? match.home.abbreviation : home.abbreviation)
                    .frame(width: 74, alignment: .trailing)
            }
            .font(.caption.weight(.heavy))
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, 8)

            ForEach(Array(away.stats.prefix(14)), id: \.label) { stat in
                let homeValue = home.stats.first { $0.label == stat.label }?.displayValue ?? "-"
                HStack {
                    Text(stat.displayValue)
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 74, alignment: .leading)
                    Spacer()
                    Text(stat.label)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(homeValue)
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 74, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func gameLeaders(_ leaders: [GameSummary.GameLeader]) -> some View {
        VStack(spacing: 0) {
            ForEach(leaders) { leader in
                HStack(spacing: 10) {
                    Text(leader.category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(1)
                    Text(leader.athleteName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let team = leader.teamAbbreviation, !team.isEmpty {
                        Text(team)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text(leader.displayValue)
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    if leader.id != leaders.first?.id { Divider().overlay(Theme.hairline) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct GameCentreTeamRosterPreview: View {
    let league: League
    let teamID: String
    let teamName: String
    let athletes: [RosterAthlete]
    @Binding var selectedPosition: String?
    @Binding var isShowingAll: Bool

    private var positions: [String] {
        Array(Set(athletes.map { positionLabel(for: $0) })).sorted()
    }

    private var filteredAthletes: [RosterAthlete] {
        guard let selectedPosition else { return athletes }
        return athletes.filter { positionLabel(for: $0) == selectedPosition }
    }

    private var displayedAthletes: [RosterAthlete] {
        isShowingAll ? filteredAthletes : Array(filteredAthletes.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Players", systemImage: "person.3.fill")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                NavigationLink("Full Roster") {
                    TeamRosterView(league: league, teamID: teamID, teamName: teamName)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
            }

            if athletes.isEmpty {
                GameCentreLoadingState(message: "Loading players")
            } else {
                if positions.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            PlayerPositionToken(title: "All", isSelected: selectedPosition == nil) { selectedPosition = nil }
                            ForEach(positions, id: \.self) { position in
                                PlayerPositionToken(title: position, isSelected: selectedPosition == position) { selectedPosition = position }
                            }
                        }
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(displayedAthletes.enumerated()), id: \.element.id) { index, athlete in
                        NavigationLink {
                            PlayerDetailView(league: league, athlete: athlete)
                        } label: {
                            RosterPreviewRow(athlete: athlete)
                        }
                        .buttonStyle(.plain)
                        if index < displayedAthletes.count - 1 { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if filteredAthletes.count > 5 {
                    Button(isShowingAll ? "Show fewer" : "Show more") { withAnimation(.snappy) { isShowingAll.toggle() } }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func positionLabel(for athlete: RosterAthlete) -> String {
        athlete.position ?? athlete.positionName ?? "Other"
    }
}

private struct PlayerPositionToken: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

private struct RosterPreviewRow: View {
    let athlete: RosterAthlete

    var body: some View {
        HStack(spacing: 10) {
            PlayerHeadshot(url: athlete.headshotURL, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(athlete.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let jersey = athlete.jersey, !jersey.isEmpty { Text("#\(jersey)") }
                    if let pos = athlete.position, !pos.isEmpty { Text(pos) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Golf

private enum GolfGameCentreTab: String, CaseIterable, Identifiable {
    case leaderboard = "Leaderboard"
    case players = "Players"
    case course = "Course"
    var id: String { rawValue }
}

private struct GolfGameCentre: View {
    let match: Match
    let tournament: StadiaGolfTournament?
    let isLoadingTournament: Bool
    let didAttemptTournamentLoad: Bool
    @State private var selectedTab: GolfGameCentreTab = .leaderboard

    private var data: GolfTournamentData { GolfTournamentData(match: match, tournament: tournament) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader
            GameCentreSegmentedPicker(tabs: GolfGameCentreTab.allCases, selection: $selectedTab)
            if isLoadingTournament && !didAttemptTournamentLoad {
                GameCentreLoadingState(message: "Loading tournament")
            }
            switch selectedTab {
            case .leaderboard:
                GolfLeaderboardTab(match: match, data: data)
            case .players:
                GolfPlayersTab(match: match, data: data)
            case .course:
                GolfCourseTab(match: match, data: data)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.fill")
            Text("Tournament Centre")
            Spacer()
        }
        .font(.headline.weight(.bold))
        .foregroundStyle(Theme.accent)
    }
}

private struct GolfTournamentData: Hashable {
    let match: Match
    let tournament: StadiaGolfTournament?

    var leaderboard: [GolfLeaderboardEntry] {
        (tournament?.leaderboard ?? []).map { entry in
            GolfLeaderboardEntry(
                id: entry.id.rawValue,
                position: entry.position,
                playerName: entry.playerName,
                today: entry.todayScore,
                thru: entry.thru ?? entry.status,
                total: entry.totalScore ?? "-",
                status: entry.status,
                rounds: entry.rounds.map { round in GolfRound(number: round.number, score: round.score ?? round.scoreToPar) }
            )
        }
    }

    var courseName: String? { tournament?.course?.name ?? match.venue }
    var courseLocation: String? { tournament?.course?.location }
    var coursePar: Int? { tournament?.course?.par }
    var courseYardage: Int? { tournament?.course?.yardage }

    var tournamentCards: [GolfTournamentCardModel] {
        var cards: [GolfTournamentCardModel] = []
        if let cutLine = tournament?.cutLine, !cutLine.isEmpty {
            cards.append(GolfTournamentCardModel(title: "Cut Line", value: cutLine, detail: nil))
        }
        if let leader = leaderboard.first {
            cards.append(GolfTournamentCardModel(title: match.state == .final ? "Winner" : "Leader", value: leader.playerName, detail: leader.total))
        }
        if let bestToday = leaderboard.compactMap({ entry -> GolfLeaderboardEntry? in
            guard entry.today != nil else { return nil }
            return entry
        }).min(by: { GolfScoreFormatter.sortValue($0.today ?? "") < GolfScoreFormatter.sortValue($1.today ?? "") }) {
            cards.append(GolfTournamentCardModel(title: "Best Round", value: bestToday.today ?? "", detail: bestToday.playerName))
        }
        if let broadcast = tournament?.broadcasts.first?.network ?? match.broadcasts.first, !broadcast.isEmpty {
            cards.append(GolfTournamentCardModel(title: "Broadcast", value: broadcast, detail: nil))
        }
        return cards
    }
}

private struct GolfLeaderboardEntry: Identifiable, Hashable {
    let id: String
    let position: String?
    let playerName: String
    let today: String?
    let thru: String?
    let total: String
    let status: String?
    let rounds: [GolfRound]

    func withPosition(_ value: String) -> GolfLeaderboardEntry {
        GolfLeaderboardEntry(id: id, position: value, playerName: playerName, today: today, thru: thru, total: total, status: status, rounds: rounds)
    }
}

private struct GolfRound: Identifiable, Hashable {
    let number: Int
    let score: String?
    var id: Int { number }
}

private struct GolfTournamentCardModel: Identifiable, Hashable {
    let title: String
    let value: String
    let detail: String?
    var id: String { title + value }
}

private enum GolfScoreFormatter {
    static func format(raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "-" }
        if cleaned == "0" { return "E" }
        if let value = Int(cleaned.replacingOccurrences(of: "+", with: "")) {
            if value == 0 { return "E" }
            return value > 0 ? "+\(value)" : "\(value)"
        }
        return cleaned
    }

    static func sortValue(_ value: String) -> Int {
        let cleaned = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == "E" { return 0 }
        if cleaned == "WD" || cleaned == "CUT" || cleaned == "DQ" || cleaned == "DNS" { return Int.max }
        return Int(cleaned.replacingOccurrences(of: "+", with: "")) ?? Int.max - 1
    }
}

private struct GolfLeaderboardTab: View {
    let match: Match
    let data: GolfTournamentData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Leaderboard")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if data.leaderboard.count > 8 {
                    NavigationLink("Full") { GolfFullLeaderboardView(match: match, data: data) }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }

            if data.leaderboard.isEmpty {
                GameCentreEmptyState(systemImage: "list.number", message: match.state == .pre ? "Leaderboard will appear when tournament scoring starts." : "Leaderboard is not available for this tournament yet.")
            } else {
                GolfLeaderboardTable(entries: Array(data.leaderboard.prefix(8)), showHeader: true)
            }

            if !data.tournamentCards.isEmpty {
                GolfTournamentCards(cards: data.tournamentCards)
            }
        }
    }
}

private struct GolfPlayersTab: View {
    let match: Match
    let data: GolfTournamentData
    @State private var query = ""

    private var filteredEntries: [GolfLeaderboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return data.leaderboard }
        return data.leaderboard.filter { $0.playerName.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search golfers", text: $query)
                .textFieldStyle(.roundedBorder)
            if filteredEntries.isEmpty {
                GameCentreEmptyState(systemImage: "person.3.sequence", message: data.leaderboard.isEmpty ? "Tournament field is not available yet." : "No golfers match that search.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredEntries.prefix(30).enumerated()), id: \.element.id) { index, entry in
                        NavigationLink { GolfPlayerTournamentDetailView(entry: entry, match: match) } label: {
                            GolfPlayerFieldRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        if index < min(filteredEntries.count, 30) - 1 { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }
}

private struct GolfCourseTab: View {
    let match: Match
    let data: GolfTournamentData

    var body: some View {
        if let course = data.courseName, !course.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(course)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                if let location = data.courseLocation, !location.isEmpty {
                    Text(location)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 10) {
                    if let par = data.coursePar {
                        Text("Par \(par)")
                    }
                    if let yardage = data.courseYardage {
                        Text("\(yardage) yards")
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                GameCentreEmptyState(systemImage: "map", message: "Hole-by-hole course data is not available from the current provider yet.")
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        } else {
            GameCentreEmptyState(systemImage: "map", message: "Course data is not available from the current provider yet.")
        }
    }
}

private struct GolfLeaderboardTable: View {
    let entries: [GolfLeaderboardEntry]
    var showHeader: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HStack(spacing: 8) {
                    Text("POS").frame(width: 34, alignment: .leading)
                    Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
                    Text("TODAY").frame(width: 48, alignment: .trailing)
                    Text("THRU").frame(width: 42, alignment: .trailing)
                    Text("TOTAL").frame(width: 54, alignment: .trailing)
                }
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceElevated)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                NavigationLink { GolfPlayerTournamentDetailView(entry: entry, match: nil) } label: {
                    GolfLeaderboardRow(entry: entry)
                }
                .buttonStyle(.plain)
                if index < entries.count - 1 { Divider().overlay(Theme.hairline) }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct GolfLeaderboardCompactRow: View {
    let entry: GolfLeaderboardEntry

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.position ?? "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, alignment: .leading)
            Text(entry.playerName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(entry.total)
                .font(.subheadline.weight(.heavy).monospacedDigit())
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 7)
    }
}

private struct GolfLeaderboardRow: View {
    let entry: GolfLeaderboardEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.position ?? "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, alignment: .leading)
            Text(entry.playerName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.today ?? "-")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48, alignment: .trailing)
            Text(entry.thru ?? "-")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 42, alignment: .trailing)
            Text(entry.total)
                .font(.subheadline.weight(.heavy).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct GolfPlayerFieldRow: View {
    let entry: GolfLeaderboardEntry

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.position ?? "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.playerName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let today = entry.today { Text("Today \(today)") }
                    if let thru = entry.thru { Text("Thru \(thru)") }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(entry.total)
                .font(.subheadline.weight(.heavy).monospacedDigit())
                .foregroundStyle(Theme.accent)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct GolfTournamentCards: View {
    let cards: [GolfTournamentCardModel]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.title.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                    Text(card.value)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let detail = card.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }
}

private struct GolfFullLeaderboardView: View {
    let match: Match
    let data: GolfTournamentData

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                GolfLeaderboardTable(entries: data.leaderboard, showHeader: true)
                    .padding(16)
            }
        }
        .navigationTitle("Leaderboard")
        .inlineNavigationTitle()
    }
}

private struct GolfPlayerTournamentDetailView: View {
    let entry: GolfLeaderboardEntry
    let match: Match?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.playerName)
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 8) {
                            Text(entry.position ?? "-")
                            Text(entry.total)
                            if let today = entry.today { Text("Today \(today)") }
                            if let thru = entry.thru { Text("Thru \(thru)") }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))

                    if entry.rounds.isEmpty {
                        GameCentreEmptyState(systemImage: "tablecells", message: "Round-by-round scorecard data is not available from the current provider yet.")
                    } else {
                        GolfRoundTable(rounds: entry.rounds, total: entry.total)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(entry.playerName)
        .inlineNavigationTitle()
    }
}

private struct GolfRoundTable: View {
    let rounds: [GolfRound]
    let total: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(rounds) { round in
                    Text("R\(round.number)")
                        .frame(maxWidth: .infinity)
                }
                Text("Total").frame(maxWidth: .infinity)
            }
            .font(.caption2.weight(.heavy))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 8)
            .background(Theme.surfaceElevated)
            HStack {
                ForEach(rounds) { round in
                    Text(round.score ?? "-").frame(maxWidth: .infinity)
                }
                Text(total).frame(maxWidth: .infinity)
            }
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, 10)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Motorsport

private enum MotorsportGameCentreTab: String, CaseIterable, Identifiable {
    case classification = "Classification"
    case drivers = "Drivers"
    case timing = "Timing"
    var id: String { rawValue }
}

private struct MotorsportGameCentre: View {
    let match: Match
    @State private var selectedTab: MotorsportGameCentreTab = .classification

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                Text("Race Centre")
                Spacer()
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)
            GameCentreSegmentedPicker(tabs: MotorsportGameCentreTab.allCases, selection: $selectedTab)
            switch selectedTab {
            case .classification, .drivers:
                RacersSection(league: match.league)
            case .timing:
                GameCentreEmptyState(systemImage: "timer", message: "Live timing data is not available from the current provider yet.")
            }
        }
    }
}

// MARK: - Tennis

private enum TennisGameCentreTab: String, CaseIterable, Identifiable {
    case match = "Match"
    case stats = "Stats"
    case draw = "Draw"
    var id: String { rawValue }
}

private struct TennisGameCentre: View {
    let match: Match
    let gameSummary: GameSummary?
    let isLoadingGameSummary: Bool
    let didAttemptGameSummaryLoad: Bool
    let reloadGameSummary: () -> Void
    @State private var selectedTab: TennisGameCentreTab = .match

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "figure.tennis")
                Text("Game Centre")
                Spacer()
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)
            GameCentreSegmentedPicker(tabs: TennisGameCentreTab.allCases, selection: $selectedTab)
            switch selectedTab {
            case .match:
                TennisMatchTab(match: match)
            case .stats:
                TeamSportStatsTab(match: match,
                                  gameSummary: gameSummary,
                                  isLoadingGameSummary: isLoadingGameSummary,
                                  didAttemptGameSummaryLoad: didAttemptGameSummaryLoad,
                                  reloadGameSummary: reloadGameSummary)
            case .draw:
                GameCentreEmptyState(systemImage: "square.grid.3x3", message: "Draw data is not available from the current provider yet.")
            }
        }
    }
}

private struct TennisMatchTab: View {
    let match: Match

    var body: some View {
        VStack(spacing: 0) {
            tennisPlayerRow(match.away)
            Divider().overlay(Theme.hairline)
            tennisPlayerRow(match.home)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func tennisPlayerRow(_ side: TeamSide) -> some View {
        HStack(spacing: 12) {
            TeamLogo(url: side.logoURL, size: 34)
            Text(side.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(side.score ?? "-")
                .font(.title3.weight(.heavy).monospacedDigit())
                .foregroundStyle(Theme.accent)
        }
        .padding(12)
    }
}

// MARK: - Combat

private enum CombatGameCentreTab: String, CaseIterable, Identifiable {
    case fightCard = "Fight Card"
    case event = "Event"
    case rankings = "Rankings"
    var id: String { rawValue }
}

private struct CombatGameCentre: View {
    let match: Match
    let gameSummary: GameSummary?
    @State private var selectedTab: CombatGameCentreTab = .fightCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "figure.boxing")
                Text("Event Centre")
                Spacer()
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)
            GameCentreSegmentedPicker(tabs: CombatGameCentreTab.allCases, selection: $selectedTab)
            switch selectedTab {
            case .fightCard:
                GameCentreEmptyState(systemImage: "list.bullet.rectangle", message: "Fight-card data is not available from the current provider yet.")
            case .event:
                CombatEventDetails(match: match, gameSummary: gameSummary)
            case .rankings:
                GameCentreEmptyState(systemImage: "list.number", message: "Rankings are not available from the current provider yet.")
            }
        }
    }
}

private struct CombatEventDetails: View {
    let match: Match
    let gameSummary: GameSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(match.name.isEmpty ? match.league.name : match.name)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
            if let venue = match.venue, !venue.isEmpty {
                Label(venue, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if gameSummary?.isEmpty == false {
                Text("Provider event details are available, but bout-level mapping is not normalized yet.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}
