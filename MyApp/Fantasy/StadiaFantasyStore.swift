import Foundation
import Combine

@MainActor
final class StadiaFantasyStore: ObservableObject {
    static let shared = StadiaFantasyStore()

    @Published private(set) var leagues: [StadiaFantasyLeagueBundle] = []
    @Published private(set) var selectedLeagueID: String?
    @Published private(set) var availablePlayers: [StadiaFantasyAvailablePlayer] = []
    @Published private(set) var fantasyEventContextsByEventID: [String: FantasyEventContext] = [:]
    @Published private(set) var fantasyGamesByChannelID: [String: [FantasyPlayerGame]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let backend: any StadiaFantasyBackendService
    private let sportsDataProvider: any StadiaSportsDataProvider
    private let userIDKey = "stadiatv.nativeFantasy.localUserID.v1"
    private let selectedLeagueKey = "stadiatv.nativeFantasy.selectedLeagueID.v1"

    init(
        backend: (any StadiaFantasyBackendService)? = nil,
        sportsDataProvider: (any StadiaSportsDataProvider)? = nil
    ) {
        self.backend = backend ?? LocalStadiaFantasyBackendService.shared
        self.sportsDataProvider = sportsDataProvider ?? ESPNSportsDataProvider()
        self.selectedLeagueID = UserDefaults.standard.string(forKey: selectedLeagueKey)
    }

    var currentUserID: String {
        if let existing = UserDefaults.standard.string(forKey: userIDKey), !existing.isEmpty { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: userIDKey)
        return created
    }

    var selectedBundle: StadiaFantasyLeagueBundle? {
        selectedLeagueID.flatMap { id in leagues.first { $0.league.id == id } } ?? leagues.first
    }

    var selectedTeam: StadiaFantasyTeam? {
        selectedBundle?.team(for: currentUserID)
    }

    var selectedRoster: StadiaFantasyRoster? {
        guard let selectedBundle, let selectedTeam else { return nil }
        return selectedBundle.rosters.first { $0.teamID == selectedTeam.id }
    }

    var nativeLeagueCount: Int { leagues.count }

    func load() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            leagues = try await backend.loadMyLeagues(userID: currentUserID)
            if selectedLeagueID == nil || leagues.contains(where: { $0.league.id == selectedLeagueID }) == false {
                selectedLeagueID = leagues.first?.league.id
                persistSelectedLeague()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectLeague(id: String) {
        selectedLeagueID = id
        persistSelectedLeague()
    }

    func createLeague(_ request: StadiaFantasyCreateLeagueRequest) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let bundle = try await backend.createLeague(request, commissionerUserID: currentUserID)
            upsert(bundle)
            selectedLeagueID = bundle.league.id
            persistSelectedLeague()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func joinLeague(_ request: StadiaFantasyJoinLeagueRequest) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let bundle = try await backend.joinLeague(request, userID: currentUserID)
            upsert(bundle)
            selectedLeagueID = bundle.league.id
            persistSelectedLeague()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadAvailablePlayers() async {
        let sport = selectedBundle?.league.sport ?? .nhl
        do {
            let loaded = try await sportsDataProvider.currentPlayers(for: sport)
            if !loaded.isEmpty {
                availablePlayers = loaded
            } else if availablePlayers.isEmpty {
                availablePlayers = Self.developmentPlayerPool(for: sport)
            }
        } catch {
            if availablePlayers.isEmpty { availablePlayers = Self.developmentPlayerPool(for: sport) }
        }
    }

    func refreshEventContexts(channels: [Channel], preferredLanguages: Set<String>) async {
        guard let bundle = selectedBundle, let roster = selectedRoster else {
            fantasyEventContextsByEventID = [:]
            fantasyGamesByChannelID = [:]
            return
        }
        let sport = bundle.league.sport
        let start = Calendar.current.startOfDay(for: Date())
        let matches = (try? await sportsDataProvider.currentSchedule(for: sport, starting: start, days: 8)) ?? []
        let games = roster.entries.map { entry -> FantasyPlayerGame in
            let match = Self.match(for: entry, in: matches)
            let opponent = match.flatMap { Self.opponent(for: entry, match: $0) }
            let ranked = match.map { SourceMatcher.rank(match: $0, channels: channels, preferredLanguages: preferredLanguages) } ?? []
            let player = FantasyPlayer(
                id: "native-\(entry.id)",
                provider: .stadia,
                sport: sport,
                firstName: nil,
                lastName: nil,
                fullName: entry.playerName,
                teamAbbreviation: entry.nhlTeamAbbreviation,
                position: entry.primaryPosition,
                fantasyPositions: entry.eligibleSlots.map(\.rawValue),
                status: nil,
                injuryStatus: entry.injuryStatus,
                jerseyNumber: nil,
                externalIDs: FantasyPlayerExternalIDs(espnID: entry.canonicalPlayerID, sportradarID: nil, yahooID: nil, fantasyDataID: nil, statsID: nil, rotowireID: nil)
            )
            return FantasyPlayerGame(
                id: "native-\(entry.id)-\(match?.id ?? "none")",
                fantasyPlayer: player,
                stadiaPlayer: StadiaPlayerIdentity(id: entry.canonicalPlayerID, leaguePath: sport.stadiaLeaguePath, displayName: entry.playerName, teamAbbreviation: entry.nhlTeamAbbreviation, position: entry.primaryPosition, espnAthleteID: entry.canonicalPlayerID, source: "stadia.nativeFantasy"),
                event: match,
                opponent: opponent,
                gameState: match.map { Self.gameLinkState(for: $0) } ?? .noGame,
                fantasyPoints: nil,
                projectedPoints: nil,
                matchedChannel: ranked.first,
                rosterSlotKind: nil,
                lineupPosition: entry.primaryPosition
            )
        }
        rebuildIndexes(from: games)
    }

    func fantasyEventContext(for match: Match) -> FantasyEventContext? {
        fantasyEventContextsByEventID[match.id]
    }

    func fantasyGames(for channelID: String) -> [FantasyPlayerGame] {
        fantasyGamesByChannelID[channelID] ?? []
    }

    func fantasyGames(for programme: EPGProgramme, channel: CanonicalChannel) -> [FantasyPlayerGame] {
        let ids = channel.allStreams.map(\.providerChannelId) + [channel.id]
        for id in ids {
            guard let games = fantasyGamesByChannelID[id] else { continue }
            let overlapping = games.filter { game in
                guard let event = game.event else { return false }
                return event.date >= programme.start.addingTimeInterval(-2 * 3600)
                    && event.date < programme.end.addingTimeInterval(2 * 3600)
            }
            if !overlapping.isEmpty { return overlapping }
        }
        return []
    }

    func fantasyIndicatorCount(for programme: EPGProgramme, channel: CanonicalChannel) -> Int {
        fantasyGames(for: programme, channel: channel).count
    }

    var liveEventContexts: [FantasyEventContext] {
        fantasyEventContextsByEventID.values.filter(\.isLive).sorted { $0.event.date < $1.event.date }
    }

    var todayEventContexts: [FantasyEventContext] {
        fantasyEventContextsByEventID.values
            .filter { Calendar.current.isDateInToday($0.event.date) && $0.event.state != .final }
            .sorted { $0.event.date < $1.event.date }
    }

    func draft(player: StadiaFantasyAvailablePlayer) async {
        guard let selectedBundle, let selectedTeam else { return }
        do {
            let bundle = try await backend.draftPlayer(leagueID: selectedBundle.league.id, teamID: selectedTeam.id, player: player, availablePlayers: availablePlayers)
            upsert(bundle)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func add(player: StadiaFantasyAvailablePlayer, dropPlayerEntryID: String? = nil) async {
        guard let selectedBundle, let selectedTeam else { return }
        do {
            let bundle = try await backend.addFreeAgent(leagueID: selectedBundle.league.id, teamID: selectedTeam.id, player: player, dropPlayerEntryID: dropPlayerEntryID)
            upsert(bundle)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func drop(playerEntryID: String) async {
        guard let selectedBundle, let selectedTeam else { return }
        do {
            let bundle = try await backend.dropPlayer(leagueID: selectedBundle.league.id, teamID: selectedTeam.id, playerEntryID: playerEntryID)
            upsert(bundle)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportData() async -> StadiaFantasyPersistenceEnvelope? {
        do {
            return try await backend.exportData()
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func resetLocalData() async {
        do {
            try await backend.resetLocalData()
            leagues = []
            selectedLeagueID = nil
            fantasyEventContextsByEventID = [:]
            fantasyGamesByChannelID = [:]
            persistSelectedLeague()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func moveLineup(playerEntryID: String, to slot: StadiaFantasyRosterSlot, scoringDate: Date = Date()) async {
        guard let selectedBundle, let selectedTeam else { return }
        do {
            _ = try await backend.moveLineupSlot(leagueID: selectedBundle.league.id, teamID: selectedTeam.id, scoringDate: scoringDate, playerEntryID: playerEntryID, to: slot)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rebuildIndexes(from games: [FantasyPlayerGame]) {
        let byEvent = Dictionary(grouping: games.filter { $0.event != nil }, by: { $0.event!.id })
        fantasyEventContextsByEventID = Dictionary(uniqueKeysWithValues: byEvent.compactMap { eventID, games in
            guard let event = games.first?.event else { return nil }
            let matched = games.compactMap(\.matchedChannel).sorted { $0.score > $1.score }.first
            return (eventID, FantasyEventContext(event: event, playerGames: games, matchedChannel: matched))
        })
        fantasyGamesByChannelID = Dictionary(grouping: games.filter { $0.matchedChannel != nil }, by: { $0.matchedChannel!.channel.id })
    }

    private static func match(for entry: StadiaFantasyPlayerEntry, in matches: [Match]) -> Match? {
        guard let team = entry.nhlTeamAbbreviation else { return nil }
        return matches
            .filter { $0.home.abbreviation.caseInsensitiveCompare(team) == .orderedSame || $0.away.abbreviation.caseInsensitiveCompare(team) == .orderedSame }
            .sorted { lhs, rhs in
                switch (lhs.state, rhs.state) {
                case (.live, .live): return lhs.date < rhs.date
                case (.live, _): return true
                case (_, .live): return false
                default: return lhs.date < rhs.date
                }
            }
            .first
    }

    private static func opponent(for entry: StadiaFantasyPlayerEntry, match: Match) -> TeamSide? {
        guard let team = entry.nhlTeamAbbreviation else { return nil }
        if match.home.abbreviation.caseInsensitiveCompare(team) == .orderedSame { return match.away }
        if match.away.abbreviation.caseInsensitiveCompare(team) == .orderedSame { return match.home }
        return nil
    }

    private static func gameLinkState(for match: Match) -> FantasyGameLinkState {
        switch match.state {
        case .pre: return .upcoming
        case .live: return .live
        case .final: return .final
        }
    }

    private func upsert(_ bundle: StadiaFantasyLeagueBundle) {
        if let index = leagues.firstIndex(where: { $0.league.id == bundle.league.id }) {
            leagues[index] = bundle
        } else {
            leagues.append(bundle)
        }
    }

    private func persistSelectedLeague() {
        UserDefaults.standard.set(selectedLeagueID, forKey: selectedLeagueKey)
    }

    private static func developmentPlayerPool(for sport: FantasySport) -> [StadiaFantasyAvailablePlayer] {
        switch sport {
        case .nfl:
            return [
                StadiaFantasyAvailablePlayer(id: "espn-nfl-3139477", fullName: "Patrick Mahomes", teamAbbreviation: "KC", position: "QB", eligibleSlots: [.quarterback], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-nfl-4242335", fullName: "Justin Jefferson", teamAbbreviation: "MIN", position: "WR", eligibleSlots: [.wideReceiver, .flex], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-nfl-3117251", fullName: "Christian McCaffrey", teamAbbreviation: "SF", position: "RB", eligibleSlots: [.runningBack, .flex], injuryStatus: nil)
            ]
        case .nhl:
            return [
                StadiaFantasyAvailablePlayer(id: "espn-nhl-4024123", fullName: "Auston Matthews", teamAbbreviation: "TOR", position: "C", eligibleSlots: [.center, .forward, .utility], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-nhl-3895074", fullName: "Connor McDavid", teamAbbreviation: "EDM", position: "C", eligibleSlots: [.center, .forward, .utility], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-nhl-4233563", fullName: "Cale Makar", teamAbbreviation: "COL", position: "D", eligibleSlots: [.defense, .utility], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-nhl-4063262", fullName: "Jake Oettinger", teamAbbreviation: "DAL", position: "G", eligibleSlots: [.goalie], injuryStatus: nil)
            ]
        case .nba:
            return [
                StadiaFantasyAvailablePlayer(id: "espn-nba-1966", fullName: "LeBron James", teamAbbreviation: "LAL", position: "SF", eligibleSlots: [.smallForward, .forward, .utility], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-nba-3975", fullName: "Stephen Curry", teamAbbreviation: "GS", position: "PG", eligibleSlots: [.pointGuard, .comboGuard, .utility], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-nba-203999", fullName: "Nikola Jokic", teamAbbreviation: "DEN", position: "C", eligibleSlots: [.center, .utility], injuryStatus: nil)
            ]
        case .mlb:
            return [
                StadiaFantasyAvailablePlayer(id: "espn-mlb-39832", fullName: "Shohei Ohtani", teamAbbreviation: "LAD", position: "UTIL", eligibleSlots: [.utility], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-mlb-33192", fullName: "Aaron Judge", teamAbbreviation: "NYY", position: "OF", eligibleSlots: [.outfield, .utility], injuryStatus: nil),
                StadiaFantasyAvailablePlayer(id: "espn-mlb-39878", fullName: "Corbin Burnes", teamAbbreviation: "ARI", position: "SP", eligibleSlots: [.startingPitcher, .pitcher], injuryStatus: nil)
            ]
        }
    }
}
