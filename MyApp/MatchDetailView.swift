import SwiftUI

struct MatchDetailView: View {
    let match: Match
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showingAllChannels = false
    @State private var playingChannel: Channel?
    @State private var isPickingMultiscreen = false
    @State private var selectedMultiChannelIDs: Set<String> = []
    @State private var multiscreenSession: MultiscreenSession?
    @State private var gameSummary: GameSummary?
    // Ranking a big playlist is expensive, so it runs once off the main thread
    // instead of inside every body evaluation.
    @State private var rankedSources: [RankedSource] = []
    @State private var isRankingSources = true
    @State private var channelQuery = ""
    @State private var selectedGameCenterTeam: GameCenterTeam = .away
    @State private var rosterPreviewByTeamID: [String: [RosterAthlete]] = [:]
    @State private var selectedRosterPosition: String?
    @State private var isShowingFullRosterPreview = false
    @State private var odds: MatchOddsDisplay?
    @State private var isLoadingOdds = false

    private var filteredMatchedSources: [RankedSource] {
        guard showingAllChannels else { return Array(rankedSources.prefix(3)) }
        let trimmed = channelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rankedSources }
        return rankedSources.filter {
            ($0.channel.name + " " + ($0.channel.group ?? "") + " " + $0.channel.playlistName)
                .localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var displayedChannels: [Channel] {
        filteredMatchedSources.map(\.channel)
    }

    private var selectedTeamID: String? {
        (selectedGameCenterTeam == .away ? match.away : match.home).teamID
    }

    private var selectedMultiScreenChannels: [Channel] {
        displayedChannels.filter { selectedMultiChannelIDs.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    scoreboard
                    sourcesSection
                    gameCenterSection
                    inGameStatsSection
                }
                .padding(16)
                .padding(.bottom, isPickingMultiscreen ? 92 : 0)
            }

            if isPickingMultiscreen {
                multiscreenFooter
            }
        }
        .navigationTitle(match.league.name)
        .sheet(item: $playingChannel) { channel in
            PlayerView(channel: channel)
        }
        .sheet(item: $multiscreenSession) { session in
            MultiScreenPlayerView(channels: session.channels)
        }
        .task(id: match.id) {
            await loadGameSummary()
        }
        .task(id: match.id) {
            await loadOdds()
        }
        .task(id: playlists.allChannels.count) {
            await rankSources()
        }
        .task(id: selectedTeamID) {
            selectedRosterPosition = nil
            isShowingFullRosterPreview = false
            await loadRosterPreviewForSelectedTeam()
        }
    }

    /// Scores the playlist channels against this match off the main thread.
    private func rankSources() async {
        let channels = playlists.allChannels
        let match = self.match
        let ranked = await Task.detached(priority: .userInitiated) {
            SourceMatcher.rank(match: match, channels: channels)
        }.value
        rankedSources = Array(ranked.prefix(30))
        isRankingSources = false
    }

    private func loadRosterPreviewForSelectedTeam() async {
        guard let teamID = selectedTeamID, rosterPreviewByTeamID[teamID] == nil else { return }
        let service = ESPNService()
        let groups = (try? await service.roster(for: match.league, teamID: teamID)) ?? []
        rosterPreviewByTeamID[teamID] = groups.flatMap(\.athletes)
    }

    private func loadOdds() async {
        guard AppConfiguration.isOddsEnabled else { return }
        isLoadingOdds = true
        defer { isLoadingOdds = false }
        odds = try? await OddsService().odds(for: match)
    }

    /// Loads boxscore stats once, then keeps polling while the game is live.
    private func loadGameSummary() async {
        guard match.state != .pre else { return }
        let service = ESPNService()
        while !Task.isCancelled {
            if let summary = try? await service.gameSummary(for: match.league, eventID: match.id),
               !summary.isEmpty {
                gameSummary = summary
            }
            guard match.state == .live else { break }
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if Task.isCancelled { break }
        }
    }

    // MARK: Scoreboard header

    private var scoreboard: some View {
        VStack(spacing: 16) {
            statusLine
            HStack(alignment: .center) {
                teamColumn(match.away)
                VStack(spacing: 4) {
                    if match.state == .pre {
                        Text("VS").font(.headline).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("\(match.away.score ?? "-")  –  \(match.home.score ?? "-")")
                            .font(.title.weight(.heavy).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                teamColumn(match.home)
            }
            compactMoneyline
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
            if match.state == .live {
                Circle().fill(Theme.live).frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(.footnote.weight(.bold))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
        }
    }

    private var statusText: String {
        switch match.state {
        case .live: return "LIVE · \(match.statusDetail)"
        case .final: return "FINAL"
        case .pre:
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: match.date)
        }
    }

    private func teamColumn(_ team: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: team.logoURL, size: 56)
            Text(team.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let record = team.record, !record.isEmpty {
                Text(record).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var compactMoneyline: some View {
        if let odds {
            CompactMoneylineOdds(match: match, odds: odds)
        } else if isLoadingOdds {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
                Text("Loading moneyline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, -4)
        }
    }

    private struct CompactMoneylineOdds: View {
        let match: Match
        let odds: MatchOddsDisplay

        private var moneylineColumns: [OddsColumn] {
            var columns = [OddsColumn(label: match.away.abbreviation.isEmpty ? match.away.shortName : match.away.abbreviation, price: odds.awayPrice)]
            if let drawPrice = odds.drawPrice {
                columns.append(OddsColumn(label: "Draw", price: drawPrice))
            }
            columns.append(OddsColumn(label: match.home.abbreviation.isEmpty ? match.home.shortName : match.home.abbreviation, price: odds.homePrice))
            return columns
        }

        var body: some View {
            HStack(spacing: 8) {
                Text("ML")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(moneylineColumns) { column in
                    HStack(spacing: 3) {
                        Text(column.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(format(price: column.price))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary.opacity(0.92))
                            .lineLimit(1)
                    }
                }
                Text(odds.bookmakerName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.11)))
        }

        private func format(price: Int?) -> String {
            guard let price else { return "—" }
            return price > 0 ? "+\(price)" : "\(price)"
        }
    }

    private struct OddsColumn: Identifiable {
        let id = UUID()
        let label: String
        let price: Int?
    }

    // MARK: In-game stats (boxscore + leaders)

    /// The boxscore column for a side, matched by ESPN team id with a
    /// positional fallback (ESPN lists away first).
    private func teamBox(for side: TeamSide, fallbackIndex: Int) -> GameSummary.TeamBox? {
        guard let summary = gameSummary else { return nil }
        if let id = side.teamID, let box = summary.teams.first(where: { $0.id == id }) {
            return box
        }
        return summary.teams.indices.contains(fallbackIndex) ? summary.teams[fallbackIndex] : nil
    }

    @ViewBuilder private var inGameStatsSection: some View {
        if let summary = gameSummary, match.state != .pre, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                    Text(match.state == .live ? "In-Game Stats" : "Game Stats")
                    Spacer()
                    if match.state == .live {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.live)
                    }
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)

                let awayBox = teamBox(for: match.away, fallbackIndex: 0)
                let homeBox = teamBox(for: match.home, fallbackIndex: 1)

                if let awayBox, let homeBox, !awayBox.stats.isEmpty {
                    statComparison(away: awayBox, home: homeBox)
                }

                if !summary.leaders.isEmpty {
                    gameLeaders(summary.leaders)
                }
            }
        }
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
                let homeValue = home.stats.first { $0.label == stat.label }?.displayValue ?? "–"
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
                .overlay(alignment: .top) {
                    Divider().overlay(Theme.hairline)
                }
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
                    if leader.id != leaders.first?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: Game Center (premium ESPN data)

    private var gameCenterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Game Center")
                Spacer()
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)

            Picker("Team", selection: $selectedGameCenterTeam) {
                Text(match.away.shortName).tag(GameCenterTeam.away)
                Text(match.home.shortName).tag(GameCenterTeam.home)
            }
            .pickerStyle(.segmented)

            selectedTeamHub
            MatchStandingsPreview(league: match.league, highlightedTeamIDs: Set([match.away.teamID, match.home.teamID].compactMap { $0 }))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                gameCenterTile(title: "Leaders", subtitle: match.league.shortName, systemImage: "chart.bar.fill") {
                    LeadersView(league: match.league)
                }
                gameCenterTile(title: "Injuries", subtitle: "Report", systemImage: "cross.case.fill") {
                    InjuriesView(league: match.league)
                }
            }
        }
    }

    @ViewBuilder private var selectedTeamHub: some View {
        let team = selectedGameCenterTeam == .away ? match.away : match.home
        if let teamID = team.teamID {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TeamLogo(url: team.logoURL, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.displayName)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let record = team.record, !record.isEmpty {
                            Text(record)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                }

                TeamRosterPreview(league: match.league,
                                  teamID: teamID,
                                  teamName: team.shortName,
                                  athletes: rosterPreviewByTeamID[teamID] ?? [],
                                  selectedPosition: $selectedRosterPosition,
                                  isShowingAll: $isShowingFullRosterPreview)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    gameCenterTile(title: "Players", subtitle: "Roster", systemImage: "person.3.fill") {
                        TeamRosterView(league: match.league, teamID: teamID, teamName: team.shortName)
                    }
                    gameCenterTile(title: "Bios", subtitle: "Profiles", systemImage: "person.text.rectangle") {
                        TeamRosterView(league: match.league, teamID: teamID, teamName: team.shortName)
                    }
                    gameCenterTile(title: "Stats", subtitle: "Season", systemImage: "chart.xyaxis.line") {
                        TeamRosterView(league: match.league, teamID: teamID, teamName: team.shortName)
                    }
                }
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private struct TeamRosterPreview: View {
        let league: League
        let teamID: String
        let teamName: String
        let athletes: [RosterAthlete]
        @Binding var selectedPosition: String?
        @Binding var isShowingAll: Bool

        private var positions: [String] {
            Array(Set(athletes.map(positionLabel))).sorted()
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
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.accent)
                        Text("Loading players")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    positionFilter
                    VStack(spacing: 0) {
                        ForEach(displayedAthletes) { athlete in
                            NavigationLink {
                                PlayerDetailView(league: league, athlete: athlete)
                            } label: {
                                TeamRosterPreviewRow(athlete: athlete, position: positionLabel(for: athlete))
                            }
                            .buttonStyle(.plain)
                            if athlete.id != displayedAthletes.last?.id {
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if filteredAthletes.count > 5 {
                        Button {
                            withAnimation(.snappy) { isShowingAll.toggle() }
                        } label: {
                            HStack {
                                Text(isShowingAll ? "Show fewer" : "More players")
                                    .font(.subheadline.weight(.bold))
                                Spacer()
                                Image(systemName: isShowingAll ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(12)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        private var positionFilter: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    positionChip(title: "All", isSelected: selectedPosition == nil) {
                        selectedPosition = nil
                        isShowingAll = false
                    }
                    ForEach(positions, id: \.self) { position in
                        positionChip(title: position, isSelected: selectedPosition == position) {
                            selectedPosition = position
                            isShowingAll = false
                        }
                    }
                }
            }
        }

        private func positionChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
            }
            .buttonStyle(.plain)
        }

        private func positionLabel(for athlete: RosterAthlete) -> String {
            athlete.position ?? athlete.positionName ?? "Position"
        }
    }

    private struct TeamRosterPreviewRow: View {
        let athlete: RosterAthlete
        let position: String

        var body: some View {
            HStack(spacing: 10) {
                PlayerHeadshot(url: athlete.headshotURL, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(athlete.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let jersey = athlete.jersey, !jersey.isEmpty {
                            Text("#\(jersey)")
                        }
                        Text(position)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if athlete.isInjured {
                    Image(systemName: "cross.case.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.live)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(10)
        }
    }

    private struct TeamPositionPreview: View {
        let sport: SportGroup
        let athletes: [RosterAthlete]

        private var plottedPlayers: [PositionedAthlete] {
            Array(athletes.prefix(14)).enumerated().map { index, athlete in
                PositionedAthlete(athlete: athlete,
                                  point: SportPositionMapper.point(for: athlete, sport: sport, fallbackIndex: index))
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Player Positions", systemImage: sport.systemImage)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(sport.rawValue.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                }

                if athletes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.accent)
                        Text("Loading roster positions")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    VirtualFieldView(sport: sport, players: plottedPlayers)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(fieldAspectRatio, contentMode: .fit)
                }
            }
        }

        private var fieldAspectRatio: CGFloat {
            switch sport {
            case .basketball, .hockey: return 1.58
            case .baseball: return 1.05
            case .football: return 1.9
            case .soccer: return 1.52
            }
        }
    }

    private struct PositionedAthlete: Identifiable {
        let athlete: RosterAthlete
        let point: CGPoint
        var id: String { athlete.id }
    }

    private struct VirtualFieldView: View {
        let sport: SportGroup
        let players: [PositionedAthlete]

        var body: some View {
            GeometryReader { proxy in
                ZStack {
                    fieldBackground
                    fieldMarkings
                    ForEach(players) { player in
                        PlayerPositionToken(athlete: player.athlete)
                            .position(x: player.point.x * proxy.size.width,
                                      y: player.point.y * proxy.size.height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }

        private var fieldBackground: some View {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        }

        private var backgroundColor: Color {
            switch sport {
            case .soccer, .football: return Color(hex: 0x153B2C)
            case .basketball: return Color(hex: 0x5A3520)
            case .baseball: return Color(hex: 0x234329)
            case .hockey: return Color(hex: 0xD7E4EF)
            }
        }

        @ViewBuilder private var fieldMarkings: some View {
            switch sport {
            case .soccer:
                SoccerFieldLines()
            case .football:
                FootballFieldLines()
            case .basketball:
                BasketballCourtLines()
            case .baseball:
                BaseballDiamondLines()
            case .hockey:
                HockeyRinkLines()
            }
        }
    }

    private struct PlayerPositionToken: View {
        let athlete: RosterAthlete

        var body: some View {
            VStack(spacing: 2) {
                Text(initials)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.45)))
                Text(label)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 48)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.58), in: Capsule())
            }
        }

        private var initials: String {
            let parts = athlete.displayName.split(separator: " ")
            let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
            return letters.isEmpty ? (athlete.position ?? "P") : letters.uppercased()
        }

        private var label: String {
            if let jersey = athlete.jersey, !jersey.isEmpty {
                return "#\(jersey) \(position)"
            }
            return position
        }

        private var position: String {
            athlete.position ?? athlete.positionName ?? "POS"
        }
    }

    private enum SportPositionMapper {
        static func point(for athlete: RosterAthlete, sport: SportGroup, fallbackIndex: Int) -> CGPoint {
            let key = ((athlete.position ?? athlete.positionName ?? "") as NSString)
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
            let mapped: CGPoint?
            switch sport {
            case .soccer: mapped = soccerPoint(for: key)
            case .football: mapped = footballPoint(for: key)
            case .basketball: mapped = basketballPoint(for: key)
            case .baseball: mapped = baseballPoint(for: key)
            case .hockey: mapped = hockeyPoint(for: key)
            }
            return jitter(mapped ?? fallbackPoint(for: fallbackIndex), index: fallbackIndex)
        }

        private static func jitter(_ point: CGPoint, index: Int) -> CGPoint {
            let offsets: [CGFloat] = [-0.035, 0.035, 0, -0.02, 0.02]
            let dx = offsets[index % offsets.count]
            let dy = offsets[(index / offsets.count) % offsets.count] * 0.7
            return CGPoint(x: min(0.92, max(0.08, point.x + dx)),
                           y: min(0.9, max(0.1, point.y + dy)))
        }

        private static func fallbackPoint(for index: Int) -> CGPoint {
            let columns: [CGFloat] = [0.2, 0.4, 0.6, 0.8]
            let rows: [CGFloat] = [0.25, 0.42, 0.6, 0.77]
            return CGPoint(x: columns[index % columns.count], y: rows[(index / columns.count) % rows.count])
        }

        private static func soccerPoint(for key: String) -> CGPoint? {
            if key.contains("goal") || key == "gk" { return CGPoint(x: 0.5, y: 0.88) }
            if key.contains("back") || key.contains("def") || ["cb", "lb", "rb", "lwb", "rwb"].contains(key) { return CGPoint(x: 0.5, y: 0.68) }
            if key.contains("mid") || ["cm", "dm", "am", "lm", "rm"].contains(key) { return CGPoint(x: 0.5, y: 0.47) }
            if key.contains("wing") || key.contains("forward") || key.contains("striker") || ["fw", "st", "cf", "lw", "rw"].contains(key) { return CGPoint(x: 0.5, y: 0.24) }
            return nil
        }

        private static func footballPoint(for key: String) -> CGPoint? {
            if key == "qb" || key.contains("quarterback") { return CGPoint(x: 0.5, y: 0.45) }
            if ["rb", "fb"].contains(key) || key.contains("running") { return CGPoint(x: 0.5, y: 0.58) }
            if key == "wr" || key.contains("receiver") { return CGPoint(x: 0.78, y: 0.38) }
            if key == "te" || key.contains("tight") { return CGPoint(x: 0.64, y: 0.42) }
            if ["c", "g", "og", "ot", "t"].contains(key) || key.contains("offensive") { return CGPoint(x: 0.5, y: 0.35) }
            if key.contains("linebacker") || key == "lb" { return CGPoint(x: 0.5, y: 0.62) }
            if key.contains("corner") || key == "cb" { return CGPoint(x: 0.78, y: 0.68) }
            if key.contains("safety") || ["s", "fs", "ss"].contains(key) { return CGPoint(x: 0.5, y: 0.78) }
            if key.contains("defensive") || ["dt", "de", "dl"].contains(key) { return CGPoint(x: 0.5, y: 0.55) }
            if key.contains("kicker") || key == "k" || key == "p" { return CGPoint(x: 0.2, y: 0.82) }
            return nil
        }

        private static func basketballPoint(for key: String) -> CGPoint? {
            if key.contains("point") || key == "pg" { return CGPoint(x: 0.5, y: 0.78) }
            if key.contains("shooting") || key == "sg" { return CGPoint(x: 0.72, y: 0.62) }
            if key.contains("small") || key == "sf" { return CGPoint(x: 0.28, y: 0.62) }
            if key.contains("power") || key == "pf" { return CGPoint(x: 0.68, y: 0.34) }
            if key.contains("center") || key == "c" { return CGPoint(x: 0.5, y: 0.24) }
            if key.contains("guard") { return CGPoint(x: 0.5, y: 0.68) }
            if key.contains("forward") { return CGPoint(x: 0.5, y: 0.38) }
            return nil
        }

        private static func baseballPoint(for key: String) -> CGPoint? {
            if key == "p" || key.contains("pitcher") { return CGPoint(x: 0.5, y: 0.52) }
            if key == "c" || key.contains("catcher") { return CGPoint(x: 0.5, y: 0.84) }
            if key == "1b" || key.contains("first") { return CGPoint(x: 0.72, y: 0.61) }
            if key == "2b" || key.contains("second") { return CGPoint(x: 0.62, y: 0.42) }
            if key == "3b" || key.contains("third") { return CGPoint(x: 0.28, y: 0.61) }
            if key == "ss" || key.contains("shortstop") { return CGPoint(x: 0.38, y: 0.42) }
            if key == "lf" || key.contains("left") { return CGPoint(x: 0.22, y: 0.22) }
            if key == "cf" || key.contains("center") { return CGPoint(x: 0.5, y: 0.14) }
            if key == "rf" || key.contains("right") { return CGPoint(x: 0.78, y: 0.22) }
            if key.contains("designated") || key == "dh" { return CGPoint(x: 0.86, y: 0.8) }
            return nil
        }

        private static func hockeyPoint(for key: String) -> CGPoint? {
            if key.contains("goal") || key == "g" { return CGPoint(x: 0.5, y: 0.86) }
            if key.contains("defense") || key == "d" { return CGPoint(x: 0.5, y: 0.62) }
            if key.contains("center") || key == "c" { return CGPoint(x: 0.5, y: 0.42) }
            if key.contains("left") || key == "lw" { return CGPoint(x: 0.3, y: 0.32) }
            if key.contains("right") || key == "rw" { return CGPoint(x: 0.7, y: 0.32) }
            if key.contains("wing") { return CGPoint(x: 0.5, y: 0.32) }
            return nil
        }
    }

    private struct SoccerFieldLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 16, dy: 12)
                    path.addRect(rect)
                    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    path.addEllipse(in: CGRect(x: rect.midX - 36, y: rect.midY - 36, width: 72, height: 72))
                    path.addRect(CGRect(x: rect.midX - 54, y: rect.maxY - 50, width: 108, height: 50))
                    path.addRect(CGRect(x: rect.midX - 54, y: rect.minY, width: 108, height: 50))
                }
                .stroke(.white.opacity(0.35), lineWidth: 1.2)
            }
        }
    }

    private struct FootballFieldLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 14, dy: 12)
                    path.addRect(rect)
                    for index in 1..<10 {
                        let x = rect.minX + rect.width * CGFloat(index) / 10
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    }
                }
                .stroke(.white.opacity(0.32), lineWidth: 1)
            }
        }
    }

    private struct BasketballCourtLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 16, dy: 12)
                    path.addRect(rect)
                    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    path.addEllipse(in: CGRect(x: rect.midX - 28, y: rect.midY - 28, width: 56, height: 56))
                    path.addRect(CGRect(x: rect.midX - 42, y: rect.minY, width: 84, height: 52))
                    path.addRect(CGRect(x: rect.midX - 42, y: rect.maxY - 52, width: 84, height: 52))
                }
                .stroke(.white.opacity(0.34), lineWidth: 1.2)
            }
        }
    }

    private struct BaseballDiamondLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let w = proxy.size.width
                    let h = proxy.size.height
                    let home = CGPoint(x: w * 0.5, y: h * 0.84)
                    let first = CGPoint(x: w * 0.72, y: h * 0.62)
                    let second = CGPoint(x: w * 0.5, y: h * 0.4)
                    let third = CGPoint(x: w * 0.28, y: h * 0.62)
                    path.move(to: home)
                    path.addLine(to: first)
                    path.addLine(to: second)
                    path.addLine(to: third)
                    path.closeSubpath()
                    path.move(to: home)
                    path.addLine(to: CGPoint(x: w * 0.16, y: h * 0.16))
                    path.move(to: home)
                    path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.16))
                    path.addEllipse(in: CGRect(x: w * 0.44, y: h * 0.46, width: w * 0.12, height: h * 0.08))
                }
                .stroke(.white.opacity(0.36), lineWidth: 1.2)
            }
        }
    }

    private struct HockeyRinkLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 16, dy: 12)
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 28, height: 28))
                    for x in [rect.minX + rect.width * 0.25, rect.midX, rect.minX + rect.width * 0.75] {
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    }
                    path.addEllipse(in: CGRect(x: rect.midX - 24, y: rect.midY - 24, width: 48, height: 48))
                }
                .stroke(Color(hex: 0x2458A6).opacity(0.5), lineWidth: 1.2)
            }
        }
    }

    private func gameCenterTile<Destination: View>(title: String, subtitle: String, systemImage: String,
                                                   @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func gameCenterLink<Destination: View>(title: String, subtitle: String, systemImage: String,
                                                   @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
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

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcesHeader

            if playlists.allChannels.isEmpty {
                noPlaylistsHint
            } else if showingAllChannels {
                channelSearchField
                if filteredMatchedSources.isEmpty {
                    Text("No matched sources fit that search.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredMatchedSources) { source in
                            SourceRow(name: source.channel.name,
                                      subtitle: source.channel.group ?? source.channel.playlistName,
                                      logoURL: source.channel.logoURL,
                                      score: source.score,
                                      isPicking: isPickingMultiscreen,
                                      isSelected: selectedMultiChannelIDs.contains(source.channel.id)) {
                                handleSourceTap(source.channel)
                            }
                        }
                    }
                }
            } else if isRankingSources && rankedSources.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Matching your channels to this game…")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            } else if rankedSources.isEmpty {
                emptyMatches
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredMatchedSources) { source in
                        SourceRow(name: source.channel.name,
                                  subtitle: source.channel.group ?? source.channel.playlistName,
                                  logoURL: source.channel.logoURL,
                                  score: source.score,
                                  isPicking: isPickingMultiscreen,
                                  isSelected: selectedMultiChannelIDs.contains(source.channel.id)) {
                            handleSourceTap(source.channel)
                        }
                    }
                    if rankedSources.count > 3 {
                        Button {
                            withAnimation { showingAllChannels = true }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "ellipsis.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                Text("More sources")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text("\(rankedSources.count - 3)+")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var channelSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search channels", text: $channelQuery)
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
            if !channelQuery.isEmpty {
                Button {
                    channelQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var sourcesHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showingAllChannels ? "More Matched Sources" : "Matched Sources")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Only algorithm-detected game streams are shown here.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if playlists.allChannels.count >= 2 {
                Button {
                    toggleMultiscreenPicking()
                } label: {
                    Image(systemName: isPickingMultiscreen ? "checkmark.rectangle.stack" : "rectangle.grid.2x2")
                        .font(.headline)
                        .foregroundStyle(isPickingMultiscreen ? .white : Theme.accent)
                        .frame(width: 38, height: 34)
                        .background(isPickingMultiscreen ? Theme.accent : Theme.surfaceElevated,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPickingMultiscreen ? "Finish multiscreen selection" : "Select multiscreen sources")
            }
            if rankedSources.count > 3 {
                Button(showingAllChannels ? "Top" : "More") {
                    withAnimation {
                        showingAllChannels.toggle()
                        channelQuery = ""
                        resetMultiscreenSelection()
                    }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private var multiscreenFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label("\(selectedMultiScreenChannels.count)/4", systemImage: "rectangle.grid.2x2")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Select at least two sources")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { resetMultiscreenSelection() }
                }
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    startMultiscreen()
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .foregroundStyle(.white)
                .background(canStartMultiscreen ? Theme.accent : Theme.accent.opacity(0.36),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(!canStartMultiscreen)
            }
        }
        .padding(12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var canStartMultiscreen: Bool {
        selectedMultiScreenChannels.count >= 2
    }

    private func toggleMultiscreenPicking() {
        withAnimation {
            if isPickingMultiscreen {
                resetMultiscreenSelection()
            } else {
                isPickingMultiscreen = true
                selectedMultiChannelIDs = Set(displayedChannels.prefix(2).map(\.id))
            }
        }
    }

    private func handleSourceTap(_ channel: Channel) {
        if isPickingMultiscreen {
            toggleSelected(channel)
        } else {
            playingChannel = channel
        }
    }

    private func toggleSelected(_ channel: Channel) {
        if selectedMultiChannelIDs.contains(channel.id) {
            selectedMultiChannelIDs.remove(channel.id)
        } else if selectedMultiChannelIDs.count < 4 {
            selectedMultiChannelIDs.insert(channel.id)
        }
    }

    private func startMultiscreen() {
        let channels = Array(selectedMultiScreenChannels.prefix(4))
        guard channels.count >= 2 else { return }
        multiscreenSession = MultiscreenSession(channels: channels)
        resetMultiscreenSelection()
    }

    private func resetMultiscreenSelection() {
        isPickingMultiscreen = false
        selectedMultiChannelIDs.removeAll()
    }

    private var noPlaylistsHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.and.film")
                .font(.title)
                .foregroundStyle(Theme.textSecondary)
            Text("Add an M3U or Xtream playlist in the Playlists tab to unlock streaming sources.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var emptyMatches: some View {
        VStack(spacing: 8) {
            Text("No channels matched this game automatically.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Browse all channels") { withAnimation { showingAllChannels = true } }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private enum GameCenterTeam: String, Hashable {
    case away
    case home
}

private struct MatchStandingsPreview: View {
    let league: League
    let highlightedTeamIDs: Set<String>
    @State private var groups: [StandingsGroup] = []
    @State private var isLoading = true
    private let service = ESPNService()

    private var previewRows: [StandingRow] {
        let allRows = groups.flatMap(\.rows)
        let highlighted = allRows.filter { highlightedTeamIDs.contains($0.teamID) }
        let topRows = allRows.prefix(5).filter { !highlightedTeamIDs.contains($0.teamID) }
        return Array((highlighted + topRows).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.number")
                Text("Standings")
                Spacer()
                NavigationLink("Full Table") {
                    StandingsView(league: league)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.textPrimary)

            if isLoading && previewRows.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Loading table")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if previewRows.isEmpty {
                Text("Standings are not available for this league right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    standingsHeader
                    ForEach(Array(previewRows.enumerated()), id: \.element.id) { index, row in
                        MatchStandingPreviewRow(rank: rank(for: row), row: row, isHighlighted: highlightedTeamIDs.contains(row.teamID))
                        if index < previewRows.count - 1 {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
        .task { await load() }
    }

    private var standingsHeader: some View {
        HStack {
            Text("TEAM")
            Spacer()
            Text("W-L")
                .frame(width: 58, alignment: .trailing)
            Text("PCT")
                .frame(width: 50, alignment: .trailing)
        }
        .font(.caption2.weight(.heavy))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated)
    }

    private func rank(for row: StandingRow) -> Int {
        let allRows = groups.flatMap(\.rows)
        guard let index = allRows.firstIndex(where: { $0.teamID == row.teamID }) else { return 0 }
        return index + 1
    }

    private func load() async {
        isLoading = true
        groups = (try? await service.standings(for: league)) ?? []
        isLoading = false
    }
}

private struct MatchStandingPreviewRow: View {
    let rank: Int
    let row: StandingRow
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(rank > 0 ? "\(rank)" : "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(isHighlighted ? Theme.accent : Theme.textSecondary)
                .frame(width: 22, alignment: .trailing)
            TeamLogo(url: row.logoURL, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.abbreviation.isEmpty ? row.displayName : row.abbreviation)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let streak = row.streak, !streak.isEmpty {
                    Text(streak)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Text(row.record)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 58, alignment: .trailing)
            Text(row.winPercent ?? row.gamesBack ?? "-")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHighlighted ? Theme.accent.opacity(0.12) : Color.clear)
    }
}

private struct MultiscreenSession: Identifiable {
    let id = UUID()
    let channels: [Channel]
}

// MARK: - Source row

private struct SourceRow: View {
    let name: String
    let subtitle: String
    let logoURL: URL?
    let score: Int?
    let isPicking: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncImage(url: logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "play.tv")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if let score, !isPicking {
                    MatchStrengthBadge(score: score)
                }
                trailingIcon
            }
            .padding(12)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailingIcon: some View {
        if isPicking {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
        } else {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
        }
    }

    private var rowBackground: Color {
        isSelected ? Theme.accent.opacity(0.15) : Theme.surface
    }

    private var rowBorder: Color {
        isSelected ? Theme.accent : Theme.hairline
    }
}

/// Shows how confident the matcher is about a source.
private struct MatchStrengthBadge: View {
    let score: Int

    private var label: String {
        switch score {
        case 100...: return "Best"
        case 50..<100: return "Strong"
        case 25..<50: return "Likely"
        default: return "Possible"
        }
    }

    private var color: Color {
        switch score {
        case 100...: return Theme.accent
        case 50..<100: return Color(hex: 0x3DBE6B)
        default: return Theme.textSecondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}
