import Foundation
import Combine

@MainActor
final class FantasyStore: ObservableObject {
    static let shared = FantasyStore()

    @Published private(set) var connectionState: FantasyConnectionState = .disconnected
    @Published private(set) var contentState: FantasyContentState = .disconnected
    @Published private(set) var settings = FantasySettings()
    @Published private(set) var leagues: [FantasyLeague] = []
    @Published private(set) var selectedLeague: FantasyLeague?
    @Published private(set) var userRoster: FantasyRoster?
    @Published private(set) var matchup: FantasyMatchup?
    @Published private(set) var standings: [FantasyStanding] = []
    @Published private(set) var players: [FantasyPlayer] = []
    @Published private(set) var playerResolutions: [String: FantasyPlayerResolution] = [:]
    @Published private(set) var playerGames: [FantasyPlayerGame] = []
    @Published private(set) var fantasyGamesByEventID: [String: [FantasyPlayerGame]] = [:]
    @Published private(set) var fantasyGamesByChannelID: [String: [FantasyPlayerGame]] = [:]
    @Published private(set) var fantasyEventContextsByEventID: [String: FantasyEventContext] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var isStale = false

    private let providerRegistry: FantasyProviderRegistry
    private let persistence: FantasyPersistenceStore
    private let resolver: FantasyPlayerResolver
    private let eventLinker: any FantasyEventLinking
    private let cachePolicy = FantasyCachePolicy()
    private var restoreTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(
        providerRegistry: FantasyProviderRegistry = FantasyProviderRegistry(),
        persistence: FantasyPersistenceStore = .shared,
        resolver: FantasyPlayerResolver = FantasyPlayerResolver(),
        eventLinker: (any FantasyEventLinking)? = nil
    ) {
        self.providerRegistry = providerRegistry
        self.persistence = persistence
        self.resolver = resolver
        self.eventLinker = eventLinker ?? FantasyEventLinker()
        self.restoreTask = Task { [weak self] in
            guard let self else { return }
            await self.restoreCachedSnapshot()
        }
    }

    var liveContext: FantasyLiveContext {
        FantasyLiveContext(
            connection: currentConnection,
            selectedLeague: selectedLeague,
            userRoster: userRoster,
            matchup: matchup,
            standings: standings,
            players: players,
            playerResolutions: playerResolutions,
            playerGames: playerGames,
            gamesByEventID: fantasyGamesByEventID,
            eventContextsByEventID: fantasyEventContextsByEventID,
            refreshedAt: refreshedAt,
            stale: isStale,
            unresolvedPlayerIDs: playerResolutions.compactMap { key, value in
                if case .unresolved = value { return key }
                if case .ambiguous = value { return key }
                return nil
            }
        )
    }

    var currentConnection: FantasyConnection? {
        switch connectionState {
        case .connected(let connection), .offlineWithCachedData(let connection): return connection
        default: return nil
        }
    }

    var diagnostics: FantasyDiagnostics {
        FantasyDiagnostics(
            provider: currentConnection?.provider,
            connectionState: connectionState,
            contentState: contentState,
            selectedLeagueID: selectedLeague?.id,
            leagueCount: leagues.count,
            rosterPlayerCount: players.count,
            linkedGameCount: playerGames.filter { $0.event != nil }.count,
            unresolvedPlayerCount: liveContext.unresolvedPlayerIDs.count,
            watchableGameCount: playerGames.filter { $0.watchAvailable }.count,
            refreshedAt: refreshedAt,
            isStale: isStale
        )
    }

    func connect(provider: FantasyProvider, usernameOrUserID: String, channels: [Channel] = [], preferredLanguages: Set<String> = []) async {
        await awaitInitialRestore()
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        connectionState = .connecting
        contentState = .loading
        lastError = nil
        do {
            let service = try providerRegistry.service(for: provider)
            let connection = try await service.connect(usernameOrUserID: usernameOrUserID)
            connectionState = .connected(connection)
            var snapshot = await persistence.loadSnapshot()
            snapshot.connection = connection
            await persistence.saveSnapshot(snapshot)
            await refresh(channels: channels, preferredLanguages: preferredLanguages, force: true)
        } catch {
            connectionState = .providerUnavailable(error.localizedDescription)
            contentState = .providerUnavailable(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func connectSleeper(usernameOrUserID: String, channels: [Channel] = [], preferredLanguages: Set<String> = []) async {
        await connect(provider: .sleeper, usernameOrUserID: usernameOrUserID, channels: channels, preferredLanguages: preferredLanguages)
    }

    func connectESPNFantasy(
        sport: FantasySport,
        leagueID: String,
        seasonID: Int,
        teamID: Int?,
        espnS2: String? = nil,
        swid: String? = nil,
        channels: [Channel] = [],
        preferredLanguages: Set<String> = []
    ) async {
        let trimmedLeagueID = leagueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeagueID.isEmpty else {
            lastError = FantasyProviderError.invalidIdentifier.localizedDescription
            return
        }
        if let espnS2 = espnS2?.trimmingCharacters(in: .whitespacesAndNewlines),
           let swid = swid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !espnS2.isEmpty,
           !swid.isEmpty,
           let service = try? providerRegistry.service(for: .espn) as? any ESPNFantasyCredentialSaving {
            do {
                try await service.saveESPNFantasyCredentials(espnS2: espnS2, swid: swid, sport: sport, leagueID: trimmedLeagueID, seasonID: seasonID)
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        let identifier = [sport.rawValue, trimmedLeagueID, String(seasonID), teamID.map(String.init)]
            .compactMap { $0 }
            .joined(separator: ":")
        await connect(provider: .espn, usernameOrUserID: identifier, channels: channels, preferredLanguages: preferredLanguages)
    }

    func connectESPNHockey(
        leagueID: String,
        seasonID: Int,
        teamID: Int?,
        espnS2: String? = nil,
        swid: String? = nil,
        channels: [Channel] = [],
        preferredLanguages: Set<String> = []
    ) async {
        await connectESPNFantasy(sport: .nhl, leagueID: leagueID, seasonID: seasonID, teamID: teamID, espnS2: espnS2, swid: swid, channels: channels, preferredLanguages: preferredLanguages)
    }

    func reconnectFromStoredIdentity(channels: [Channel] = [], preferredLanguages: Set<String> = []) async {
        guard let connection = currentConnection else { return }
        await connect(provider: connection.provider, usernameOrUserID: connection.providerUserID, channels: channels, preferredLanguages: preferredLanguages)
    }

    func refresh(channels: [Channel] = [], preferredLanguages: Set<String> = [], force: Bool = false) async {
        await awaitInitialRestore()
        guard let connection = currentConnection else {
            contentState = .disconnected
            playerGames = []
            rebuildFantasyIndexes(from: [])
            return
        }
        guard (try? providerRegistry.service(for: connection.provider)) != nil else {
            contentState = .providerUnavailable(FantasyProviderError.unsupportedProvider.localizedDescription)
            lastError = FantasyProviderError.unsupportedProvider.localizedDescription
            return
        }

        if !force, cachePolicy.isFresh(refreshedAt, lifetime: cachePolicy.matchupTTL), contentState != .loading {
            return
        }

        if let existingTask = refreshTask {
            if force {
                refreshGeneration += 1
                existingTask.cancel()
                refreshTask = nil
            } else {
                await existingTask.value
                return
            }
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        guard let service = try? providerRegistry.service(for: connection.provider) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(service: service, connection: connection, channels: channels, preferredLanguages: preferredLanguages, force: force, generation: generation)
        }
        refreshTask = task
        await task.value
        if refreshGeneration == generation {
            refreshTask = nil
        }
    }

    func setSelectedLeagueID(_ leagueID: String?) async {
        await awaitInitialRestore()
        settings.selectedLeagueID = leagueID
        selectedLeague = leagueID.flatMap { id in leagues.first { $0.id == id } } ?? leagues.first
        var snapshot = await persistence.loadSnapshot()
        snapshot.settings = settings
        await persistence.saveSnapshot(snapshot)
    }

    func selectLeague(id leagueID: String, channels: [Channel] = [], preferredLanguages: Set<String> = []) async {
        await setSelectedLeagueID(leagueID)
        await refresh(channels: channels, preferredLanguages: preferredLanguages, force: true)
    }

    func setShowFantasyOnHome(_ enabled: Bool) async {
        await awaitInitialRestore()
        settings.showFantasyOnHome = enabled
        await persistSettings()
    }

    func setShowFantasyIndicatorsInLive(_ enabled: Bool) async {
        await awaitInitialRestore()
        settings.showFantasyIndicatorsInLive = enabled
        await persistSettings()
    }

    func setShowFantasyIndicatorsInGuide(_ enabled: Bool) async {
        await awaitInitialRestore()
        settings.showFantasyIndicatorsInGuide = enabled
        await persistSettings()
    }

    func setShowFantasyPlayerOverlay(_ enabled: Bool) async {
        await awaitInitialRestore()
        settings.showFantasyPlayerOverlay = enabled
        await persistSettings()
    }

    func disconnect(provider: FantasyProvider? = nil) async {
        await awaitInitialRestore()
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        guard let connection = currentConnection else { return }
        guard provider == nil || provider == connection.provider else { return }
        if let service = try? providerRegistry.service(for: connection.provider) {
            await service.disconnect(connection: connection)
        }
        await persistence.removeConnectionAndCaches(provider: connection.provider)
        connectionState = .disconnected
        contentState = .disconnected
        settings = FantasySettings()
        leagues = []
        selectedLeague = nil
        userRoster = nil
        matchup = nil
        standings = []
        players = []
        playerResolutions = [:]
        playerGames = []
        fantasyGamesByEventID = [:]
        fantasyGamesByChannelID = [:]
        fantasyEventContextsByEventID = [:]
        refreshedAt = nil
        isStale = false
        lastError = nil
    }

    func disconnectSleeper() async {
        await disconnect(provider: .sleeper)
    }

    private func awaitInitialRestore() async {
        guard let task = restoreTask else { return }
        await task.value
        restoreTask = nil
    }

    private func restoreCachedSnapshot() async {
        let snapshot = await persistence.loadSnapshot()
        settings = snapshot.settings
        leagues = snapshot.leagues
        selectedLeague = settings.selectedLeagueID.flatMap { id in leagues.first { $0.id == id } } ?? leagues.first
        standings = selectedLeague.flatMap { snapshot.standingsByLeagueID[$0.id] } ?? []
        players = Array(snapshot.lightweightPlayersByID.values).sorted { $0.fullName < $1.fullName }
        playerGames = selectedLeague.flatMap { snapshot.cachedPlayerGamesByLeagueID[$0.id] }?.compactMap { $0.toDomain() } ?? []
        rebuildFantasyIndexes(from: playerGames)
        if let connection = snapshot.connection {
            connectionState = .connected(connection)
            contentState = leagues.isEmpty ? .loading : contentState(for: selectedLeague, matchup: matchup, playerGames: playerGames)
        } else {
            connectionState = .disconnected
            contentState = .disconnected
        }
    }

    private func performRefresh(service: any FantasyProviderService, connection: FantasyConnection, channels: [Channel], preferredLanguages: Set<String>, force: Bool, generation: Int) async {
        guard generation == refreshGeneration else { return }
        contentState = .loading
        isStale = false
        lastError = nil
        var snapshot = await persistence.loadSnapshot()

        do {
            let seasonState = try await service.currentSeasonState(for: connection)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let loadedLeagues = try await service.leagues(for: connection, season: seasonState.seasonForLeagueLookup)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            leagues = loadedLeagues
            snapshot.leagues = loadedLeagues

            guard !loadedLeagues.isEmpty else {
                selectedLeague = nil
                contentState = .noLeagues
                await persistence.saveSnapshot(snapshot)
                return
            }

            let league = settings.selectedLeagueID.flatMap { id in loadedLeagues.first { $0.id == id } } ?? loadedLeagues.first!
            selectedLeague = league
            settings.selectedLeagueID = league.id
            snapshot.settings = settings

            switch league.status {
            case .preDraft, .drafting:
                contentState = .preDraft
            case .complete:
                contentState = .seasonComplete
            default:
                break
            }

            let leagueUsers = try await service.leagueUsers(leagueID: league.id)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let rosters = try await service.leagueRosters(leagueID: league.id, teams: leagueUsers)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            guard let ownedRoster = service.userRoster(in: rosters, connection: connection) else {
                throw FantasyProviderError.noConnectedUserRoster
            }

            let rosterTeams = rosters.compactMap(\.team)
            let standings = try await service.standings(leagueID: league.id, rosters: rosters)
            let activeWeek = seasonState.activeWeek
            let matchup = activeWeek == nil ? nil : try await service.matchup(
                leagueID: league.id,
                week: activeWeek!,
                userRosterID: ownedRoster.rosterID,
                teams: rosterTeams
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }

            let playerIDs = Set(ownedRoster.slots.map(\.playerID) + (matchup?.userTeam.players ?? []))
            let playerMap = try await service.players(ids: playerIDs, sport: league.sport)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let loadedPlayers = playerIDs.compactMap { playerMap[$0] }.sorted { $0.fullName < $1.fullName }
            let resolutions = await resolver.resolve(players: loadedPlayers)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let linkedGames = await eventLinker.linkPlayerGames(
                players: loadedPlayers,
                resolutions: resolutions,
                matchup: matchup,
                channels: channels,
                preferredLanguages: preferredLanguages,
                knownMatches: nil
            )
            let games = enrich(linkedGames, with: ownedRoster)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }

            self.userRoster = ownedRoster
            self.matchup = matchup
            self.standings = standings
            self.players = loadedPlayers
            self.playerResolutions = resolutions
            self.playerGames = games
            rebuildFantasyIndexes(from: games)
            self.refreshedAt = Date()
            self.contentState = contentState(for: league, matchup: matchup, playerGames: games)

            snapshot.connection = FantasyConnection(
                provider: connection.provider,
                providerUserID: connection.providerUserID,
                username: connection.username,
                displayName: connection.displayName,
                avatarID: connection.avatarID,
                connectedAt: connection.connectedAt,
                refreshedAt: refreshedAt
            )
            snapshot.leagueUsersByLeagueID[league.id] = rosterTeams
            snapshot.rostersByLeagueID[league.id] = rosters
            if let matchup, let activeWeek {
                snapshot.matchupsByLeagueAndWeek["\(league.id)-\(activeWeek)"] = matchup
            }
            snapshot.standingsByLeagueID[league.id] = standings
            snapshot.lightweightPlayersByID = playerMap
            snapshot.cachedPlayerGamesByLeagueID[league.id] = games.map(CachedFantasyPlayerGame.init(game:))
            snapshot.updatedAtByKey["league:\(league.id)"] = refreshedAt
            await persistence.saveSnapshot(snapshot)
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            lastError = error.localizedDescription
            if let cachedConnection = snapshot.connection {
                connectionState = .offlineWithCachedData(cachedConnection)
                contentState = snapshot.leagues.isEmpty ? .providerUnavailable(error.localizedDescription) : .offlineWithCachedData
                isStale = !snapshot.leagues.isEmpty
                leagues = snapshot.leagues
                selectedLeague = snapshot.settings.selectedLeagueID.flatMap { id in snapshot.leagues.first { $0.id == id } } ?? snapshot.leagues.first
                standings = selectedLeague.flatMap { snapshot.standingsByLeagueID[$0.id] } ?? []
                players = Array(snapshot.lightweightPlayersByID.values).sorted { $0.fullName < $1.fullName }
                playerGames = selectedLeague.flatMap { snapshot.cachedPlayerGamesByLeagueID[$0.id] }?.map { $0.toDomain(channels: channels) } ?? []
                rebuildFantasyIndexes(from: playerGames)
            } else {
                connectionState = .providerUnavailable(error.localizedDescription)
                contentState = .providerUnavailable(error.localizedDescription)
            }
        }
    }

    func fantasyGames(for match: Match) -> [FantasyPlayerGame] {
        fantasyGamesByEventID[match.id] ?? []
    }

    func fantasyIndicatorCount(for programme: EPGProgramme, channel: CanonicalChannel) -> Int {
        guard settings.showFantasyIndicatorsInGuide else { return 0 }
        let ids = channel.allStreams.map(\.providerChannelId) + [channel.id]
        for id in ids {
            guard let games = fantasyGamesByChannelID[id] else { continue }
            let overlapping = games.filter { game in
                guard let event = game.event else { return false }
                return event.date >= programme.start.addingTimeInterval(-2 * 3600)
                    && event.date < programme.end.addingTimeInterval(2 * 3600)
            }
            if !overlapping.isEmpty { return overlapping.count }
        }
        return 0
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

    var livePlayerGames: [FantasyPlayerGame] {
        playerGames.filter { $0.gameState == .live }
    }

    var todayPlayerGames: [FantasyPlayerGame] {
        playerGames.filter { game in
            guard let date = game.event?.date else { return false }
            return Calendar.current.isDateInToday(date) && game.gameState != .final
        }
    }

    var scheduledPlayerGames: [FantasyPlayerGame] {
        playerGames.filter { $0.gameState == .upcoming }
    }

    var liveEventContexts: [FantasyEventContext] {
        fantasyEventContextsByEventID.values
            .filter(\.isLive)
            .sorted { $0.event.date < $1.event.date }
    }

    var todayEventContexts: [FantasyEventContext] {
        fantasyEventContextsByEventID.values
            .filter { Calendar.current.isDateInToday($0.event.date) && $0.event.state != .final }
            .sorted { $0.event.date < $1.event.date }
    }

    var upcomingEventContexts: [FantasyEventContext] {
        fantasyEventContextsByEventID.values
            .filter(\.isUpcoming)
            .sorted { $0.event.date < $1.event.date }
    }

    func fantasyEventContext(for match: Match) -> FantasyEventContext? {
        fantasyEventContextsByEventID[match.id]
    }

    func fantasyGames(for channelID: String) -> [FantasyPlayerGame] {
        fantasyGamesByChannelID[channelID] ?? []
    }

    private func enrich(_ games: [FantasyPlayerGame], with roster: FantasyRoster) -> [FantasyPlayerGame] {
        let slotByPlayerID = Dictionary(grouping: roster.slots, by: \.playerID)
        return games.map { game in
            guard let slot = slotByPlayerID[game.fantasyPlayer.id]?.first else { return game }
            return FantasyPlayerGame(
                id: game.id,
                fantasyPlayer: game.fantasyPlayer,
                stadiaPlayer: game.stadiaPlayer,
                event: game.event,
                opponent: game.opponent,
                gameState: game.gameState,
                fantasyPoints: game.fantasyPoints,
                projectedPoints: game.projectedPoints,
                matchedChannel: game.matchedChannel,
                rosterSlotKind: slot.kind,
                lineupPosition: slot.lineupPosition
            )
        }
    }

    private func rebuildFantasyIndexes(from games: [FantasyPlayerGame]) {
        fantasyGamesByEventID = Dictionary(grouping: games.filter { $0.event != nil }, by: { $0.event!.id })
        fantasyGamesByChannelID = Dictionary(grouping: games.filter { $0.matchedChannel != nil }, by: { $0.matchedChannel!.channel.id })
        fantasyEventContextsByEventID = Dictionary(uniqueKeysWithValues: fantasyGamesByEventID.compactMap { eventID, games in
            guard let event = games.first?.event else { return nil }
            let matchedChannel = games.compactMap(\.matchedChannel).sorted { $0.score > $1.score }.first
            return (eventID, FantasyEventContext(event: event, playerGames: games, matchedChannel: matchedChannel))
        })
    }


    private func contentState(for league: FantasyLeague?, matchup: FantasyMatchup?, playerGames: [FantasyPlayerGame]) -> FantasyContentState {
        guard let league else { return .noLeagues }
        switch league.status {
        case .preDraft, .drafting: return .preDraft
        case .complete: return .seasonComplete
        case .inSeason:
            if matchup == nil { return .noCurrentMatchup }
            if playerGames.contains(where: { $0.gameState == .live }) { return .playersLive }
            if playerGames.contains(where: { $0.gameState == .upcoming }) { return .playersScheduled }
            return .noFantasyPlayersToday
        case .offSeason: return .offSeason
        case .unknown: return matchup == nil ? .partialData("League state is unknown") : .inSeason
        }
    }

    private func persistSettings() async {
        var snapshot = await persistence.loadSnapshot()
        snapshot.settings = settings
        await persistence.saveSnapshot(snapshot)
    }
}
