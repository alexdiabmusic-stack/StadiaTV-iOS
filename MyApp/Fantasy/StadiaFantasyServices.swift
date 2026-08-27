import Foundation

protocol StadiaSportsDataProvider: Sendable {
    func currentPlayers(for sport: FantasySport) async throws -> [StadiaFantasyAvailablePlayer]
    func currentSchedule(for sport: FantasySport, starting date: Date, days: Int) async throws -> [Match]
    func statLines(for sport: FantasySport, playerIDs: Set<String>, from start: Date, to end: Date) async throws -> [String: StadiaFantasyStatLine]
}

struct StadiaFantasyAvailablePlayer: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let fullName: String
    let teamAbbreviation: String?
    let position: String?
    let eligibleSlots: [StadiaFantasyRosterSlot]
    let injuryStatus: String?
}

struct ESPNSportsDataProvider: StadiaSportsDataProvider {
    private let service: ESPNService

    init(service: ESPNService = ESPNService()) {
        self.service = service
    }

    func currentPlayers(for sport: FantasySport) async throws -> [StadiaFantasyAvailablePlayer] {
        // Stadia already resolves canonical players through ESPNService in player/detail flows.
        // Full sport-specific player pool endpoints can be wired here without changing native Fantasy UI.
        []
    }

    func currentSchedule(for sport: FantasySport, starting date: Date, days: Int) async throws -> [Match] {
        guard let league = sport.stadiaLeague else { return [] }
        return try await service.scoreboards(for: league, starting: date, days: days)
    }

    func statLines(for sport: FantasySport, playerIDs: Set<String>, from start: Date, to end: Date) async throws -> [String: StadiaFantasyStatLine] {
        // Live scoring ingestion belongs here once the existing sport box-score/stat model exposes
        // stable per-athlete game totals. The scoring engine is isolated from SwiftUI.
        [:]
    }
}

typealias ESPNHockeySportsDataProvider = ESPNSportsDataProvider

protocol StadiaFantasyBackendService: Sendable {
    func loadMyLeagues(userID: String) async throws -> [StadiaFantasyLeagueBundle]
    func createLeague(_ request: StadiaFantasyCreateLeagueRequest, commissionerUserID: String) async throws -> StadiaFantasyLeagueBundle
    func joinLeague(_ request: StadiaFantasyJoinLeagueRequest, userID: String) async throws -> StadiaFantasyLeagueBundle
    func draftPlayer(leagueID: String, teamID: String, player: StadiaFantasyAvailablePlayer, availablePlayers: [StadiaFantasyAvailablePlayer]) async throws -> StadiaFantasyLeagueBundle
    func moveLineupSlot(leagueID: String, teamID: String, scoringDate: Date, playerEntryID: String, to slot: StadiaFantasyRosterSlot) async throws -> StadiaFantasyLineup
    func addFreeAgent(leagueID: String, teamID: String, player: StadiaFantasyAvailablePlayer, dropPlayerEntryID: String?) async throws -> StadiaFantasyLeagueBundle
    func dropPlayer(leagueID: String, teamID: String, playerEntryID: String) async throws -> StadiaFantasyLeagueBundle
    func exportData() async throws -> StadiaFantasyPersistenceEnvelope
    func resetLocalData() async throws
    func disconnect() async
}

enum StadiaFantasyBackendError: LocalizedError, Sendable {
    case leagueNotFound
    case leagueFull
    case teamNotFound
    case playerAlreadyRostered
    case playerNotRostered
    case invalidLineup(String)
    case draftNotActive
    case notCurrentPick

    var errorDescription: String? {
        switch self {
        case .leagueNotFound: return "League not found. Check the invite code and try again."
        case .leagueFull: return "This league is already full."
        case .teamNotFound: return "Fantasy team not found."
        case .playerAlreadyRostered: return "That player is already rostered in this league."
        case .playerNotRostered: return "That player is not on this roster."
        case .invalidLineup(let reason): return reason
        case .draftNotActive: return "The draft is not active."
        case .notCurrentPick: return "It is not your pick."
        }
    }
}

actor LocalStadiaFantasyBackendService: StadiaFantasyBackendService {
    static let shared = LocalStadiaFantasyBackendService()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileURL: URL
    private var bundles: [StadiaFantasyLeagueBundle] = []
    private var didLoad = false

    init(fileManager: FileManager = .default) {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("StadiaFantasy", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("native-leagues.json")
    }

    func loadMyLeagues(userID: String) async throws -> [StadiaFantasyLeagueBundle] {
        try loadIfNeeded()
        return bundles.filter { bundle in
            bundle.memberships.contains { $0.userID == userID }
        }
    }

    func createLeague(_ request: StadiaFantasyCreateLeagueRequest, commissionerUserID: String) async throws -> StadiaFantasyLeagueBundle {
        try loadIfNeeded()
        let now = Date()
        let leagueID = UUID().uuidString
        let userTeamID = UUID().uuidString
        let teamCount = request.mode == .personalTeam ? 1 : request.maxTeams
        let membership = StadiaFantasyMembership(
            id: UUID().uuidString,
            leagueID: leagueID,
            userID: commissionerUserID,
            displayName: request.teamName,
            role: .commissioner,
            joinedAt: now
        )
        let userTeam = StadiaFantasyTeam(
            id: userTeamID,
            leagueID: leagueID,
            ownerUserID: commissionerUserID,
            displayName: request.teamName,
            abbreviation: Self.abbreviation(for: request.teamName),
            avatarID: nil
        )
        let seasonYear = Calendar.current.component(.year, from: now)
        var draftSettings = request.draftSettings
        let cpuTeams = request.mode == .simulatedLeague ? Self.cpuTeams(leagueID: leagueID, count: max(0, teamCount - 1)) : []
        let teams = [userTeam] + cpuTeams
        draftSettings.draftOrderTeamIDs = teams.map(\.id)
        let league = StadiaFantasyLeague(
            id: leagueID,
            name: request.leagueName,
            source: .native,
            mode: request.mode,
            sport: request.sport,
            season: StadiaFantasySeason(id: "\(request.sport.rawValue)-\(seasonYear)", year: seasonYear, startsAt: nil, endsAt: nil, scoringPeriodDays: FantasySportConfiguration.configuration(for: request.sport).lineupFrequency == .daily ? 1 : 7),
            phase: .lobby,
            visibility: request.mode == .personalTeam ? .private : request.visibility,
            inviteCode: Self.inviteCode(),
            commissionerUserID: commissionerUserID,
            maxTeams: teamCount,
            rosterConfiguration: request.rosterConfiguration,
            scoringRules: request.scoringRules,
            draftSettings: draftSettings,
            waiverSettings: request.mode == .personalTeam ? StadiaFantasyWaiverSettings(type: .freeAgency, waiverPeriodHours: 0, usesFAAB: false, faabBudget: nil) : request.waiverSettings,
            tradeSettings: request.tradeSettings,
            playoffSettings: request.playoffSettings,
            createdAt: now
        )
        let rosters = teams.map { StadiaFantasyRoster(leagueID: leagueID, teamID: $0.id, entries: []) }
        let standings = request.mode == .personalTeam ? [] : teams.enumerated().map { index, team in
            StadiaFantasyStanding(leagueID: leagueID, teamID: team.id, rank: index + 1, wins: 0, losses: 0, ties: 0, pointsFor: nil, pointsAgainst: nil)
        }
        let draft = StadiaFantasyDraft(
            id: UUID().uuidString,
            leagueID: leagueID,
            status: .lobby,
            currentPickOverall: 1,
            picks: Self.snakeDraftPicks(leagueID: leagueID, teamIDs: draftSettings.draftOrderTeamIDs, rounds: Self.draftRounds(for: request.rosterConfiguration))
        )
        let bundle = StadiaFantasyLeagueBundle(
            league: league,
            memberships: [membership],
            teams: teams,
            rosters: rosters,
            lineups: [],
            matchups: Self.matchups(leagueID: leagueID, teams: teams, start: now, periods: request.playoffSettings.regularSeasonPeriods),
            standings: standings,
            transactions: [],
            draft: draft
        )
        bundles.append(bundle)
        try save()
        return bundle
    }

    func joinLeague(_ request: StadiaFantasyJoinLeagueRequest, userID: String) async throws -> StadiaFantasyLeagueBundle {
        try loadIfNeeded()
        guard let index = bundles.firstIndex(where: { $0.league.inviteCode.caseInsensitiveCompare(request.inviteCode) == .orderedSame }) else {
            throw StadiaFantasyBackendError.leagueNotFound
        }
        guard bundles[index].teams.count < bundles[index].league.maxTeams else { throw StadiaFantasyBackendError.leagueFull }
        if let existing = bundles[index].team(for: userID) { return bundles[index].copySelecting(teamID: existing.id) }
        let now = Date()
        let teamID = UUID().uuidString
        bundles[index].memberships.append(StadiaFantasyMembership(id: UUID().uuidString, leagueID: bundles[index].league.id, userID: userID, displayName: request.teamName, role: .manager, joinedAt: now))
        bundles[index].teams.append(StadiaFantasyTeam(id: teamID, leagueID: bundles[index].league.id, ownerUserID: userID, displayName: request.teamName, abbreviation: String(request.teamName.prefix(3)).uppercased(), avatarID: nil))
        bundles[index].rosters.append(StadiaFantasyRoster(leagueID: bundles[index].league.id, teamID: teamID, entries: []))
        bundles[index].standings.append(StadiaFantasyStanding(leagueID: bundles[index].league.id, teamID: teamID, rank: bundles[index].standings.count + 1, wins: 0, losses: 0, ties: 0, pointsFor: nil, pointsAgainst: nil))
        try save()
        return bundles[index]
    }

    func draftPlayer(leagueID: String, teamID: String, player: StadiaFantasyAvailablePlayer, availablePlayers: [StadiaFantasyAvailablePlayer]) async throws -> StadiaFantasyLeagueBundle {
        try loadIfNeeded()
        guard let leagueIndex = bundles.firstIndex(where: { $0.league.id == leagueID }) else { throw StadiaFantasyBackendError.leagueNotFound }
        guard let rosterIndex = bundles[leagueIndex].rosters.firstIndex(where: { $0.teamID == teamID }) else { throw StadiaFantasyBackendError.teamNotFound }
        guard !isPlayerRostered(player.id, in: bundles[leagueIndex]) else { throw StadiaFantasyBackendError.playerAlreadyRostered }
        if var draft = bundles[leagueIndex].draft, draft.picks.contains(where: { $0.canonicalPlayerID == nil }) {
            guard draft.picks.first(where: { $0.overallPick == draft.currentPickOverall })?.teamID == teamID else { throw StadiaFantasyBackendError.notCurrentPick }
            draftPick(player, teamID: teamID, leagueIndex: leagueIndex, draft: &draft)
            autoDraftCPUSelections(leagueIndex: leagueIndex, draft: &draft, availablePlayers: availablePlayers)
            bundles[leagueIndex].draft = advanceDraft(draft, in: bundles[leagueIndex])
        } else {
            let entry = rosterEntry(for: player, leagueID: leagueID, teamID: teamID)
            bundles[leagueIndex].rosters[rosterIndex].entries.append(entry)
            bundles[leagueIndex].transactions.insert(Self.transaction(leagueID: leagueID, teamID: teamID, type: .draftPick, playerEntryIDs: [entry.id], description: "Drafted \(player.fullName)"), at: 0)
        }
        try save()
        return bundles[leagueIndex]
    }

    func moveLineupSlot(leagueID: String, teamID: String, scoringDate: Date, playerEntryID: String, to slot: StadiaFantasyRosterSlot) async throws -> StadiaFantasyLineup {
        try loadIfNeeded()
        guard let leagueIndex = bundles.firstIndex(where: { $0.league.id == leagueID }) else { throw StadiaFantasyBackendError.leagueNotFound }
        guard let roster = bundles[leagueIndex].rosters.first(where: { $0.teamID == teamID }) else { throw StadiaFantasyBackendError.teamNotFound }
        guard roster.entries.contains(where: { $0.id == playerEntryID }) else { throw StadiaFantasyBackendError.playerNotRostered }
        let day = Calendar.current.startOfDay(for: scoringDate)
        let lineupID = "\(leagueID)-\(teamID)-\(Int(day.timeIntervalSince1970))"
        let slotID = "\(lineupID)-\(playerEntryID)"
        let existingIndex = bundles[leagueIndex].lineups.firstIndex { $0.id == lineupID }
        if let existingIndex {
            if let playerSlotIndex = bundles[leagueIndex].lineups[existingIndex].slots.firstIndex(where: { $0.playerEntryID == playerEntryID }) {
                bundles[leagueIndex].lineups[existingIndex].slots[playerSlotIndex].slot = slot
            } else {
                bundles[leagueIndex].lineups[existingIndex].slots.append(StadiaFantasyLineupSlot(id: slotID, playerEntryID: playerEntryID, slot: slot, lockedAt: nil))
            }
            try validate(lineup: bundles[leagueIndex].lineups[existingIndex], league: bundles[leagueIndex].league, roster: roster)
            try save()
            return bundles[leagueIndex].lineups[existingIndex]
        } else {
            let lineup = StadiaFantasyLineup(id: lineupID, leagueID: leagueID, teamID: teamID, scoringDate: day, slots: [StadiaFantasyLineupSlot(id: slotID, playerEntryID: playerEntryID, slot: slot, lockedAt: nil)])
            try validate(lineup: lineup, league: bundles[leagueIndex].league, roster: roster)
            bundles[leagueIndex].lineups.append(lineup)
            try save()
            return lineup
        }
    }

    func addFreeAgent(leagueID: String, teamID: String, player: StadiaFantasyAvailablePlayer, dropPlayerEntryID: String?) async throws -> StadiaFantasyLeagueBundle {
        try loadIfNeeded()
        guard let leagueIndex = bundles.firstIndex(where: { $0.league.id == leagueID }) else { throw StadiaFantasyBackendError.leagueNotFound }
        guard let rosterIndex = bundles[leagueIndex].rosters.firstIndex(where: { $0.teamID == teamID }) else { throw StadiaFantasyBackendError.teamNotFound }
        var droppedIDs: [String] = []
        if let dropPlayerEntryID {
            guard bundles[leagueIndex].rosters[rosterIndex].entries.contains(where: { $0.id == dropPlayerEntryID }) else { throw StadiaFantasyBackendError.playerNotRostered }
            bundles[leagueIndex].rosters[rosterIndex].entries.removeAll { $0.id == dropPlayerEntryID }
            bundles[leagueIndex].lineups.removeAll { lineup in lineup.slots.contains { $0.playerEntryID == dropPlayerEntryID } }
            droppedIDs.append(dropPlayerEntryID)
        }
        guard !isPlayerRostered(player.id, in: bundles[leagueIndex]) else { throw StadiaFantasyBackendError.playerAlreadyRostered }
        let entry = rosterEntry(for: player, leagueID: leagueID, teamID: teamID)
        bundles[leagueIndex].rosters[rosterIndex].entries.append(entry)
        let type: StadiaFantasyTransactionType = dropPlayerEntryID == nil ? .add : .addDrop
        bundles[leagueIndex].transactions.insert(Self.transaction(leagueID: leagueID, teamID: teamID, type: type, playerEntryIDs: [entry.id] + droppedIDs, description: dropPlayerEntryID == nil ? "Added \(player.fullName)" : "Added \(player.fullName) and dropped a player"), at: 0)
        try save()
        return bundles[leagueIndex]
    }

    func dropPlayer(leagueID: String, teamID: String, playerEntryID: String) async throws -> StadiaFantasyLeagueBundle {
        try loadIfNeeded()
        guard let leagueIndex = bundles.firstIndex(where: { $0.league.id == leagueID }) else { throw StadiaFantasyBackendError.leagueNotFound }
        guard let rosterIndex = bundles[leagueIndex].rosters.firstIndex(where: { $0.teamID == teamID }) else { throw StadiaFantasyBackendError.teamNotFound }
        guard let entry = bundles[leagueIndex].rosters[rosterIndex].entries.first(where: { $0.id == playerEntryID }) else { throw StadiaFantasyBackendError.playerNotRostered }
        bundles[leagueIndex].rosters[rosterIndex].entries.removeAll { $0.id == playerEntryID }
        bundles[leagueIndex].lineups.removeAll { lineup in lineup.slots.contains { $0.playerEntryID == playerEntryID } }
        bundles[leagueIndex].transactions.insert(Self.transaction(leagueID: leagueID, teamID: teamID, type: .drop, playerEntryIDs: [playerEntryID], description: "Dropped \(entry.playerName)"), at: 0)
        try save()
        return bundles[leagueIndex]
    }

    func exportData() async throws -> StadiaFantasyPersistenceEnvelope {
        try loadIfNeeded()
        return StadiaFantasyPersistenceEnvelope(schemaVersion: StadiaFantasyPersistenceEnvelope.currentSchemaVersion, bundles: bundles)
    }

    func resetLocalData() async throws {
        try loadIfNeeded()
        bundles = []
        try save()
    }

    func disconnect() async {}

    private func validate(lineup: StadiaFantasyLineup, league: StadiaFantasyLeague, roster: StadiaFantasyRoster) throws {
        let rosterEntryIDs = Set(roster.entries.map(\.id))
        let lineupEntryIDs = lineup.slots.map(\.playerEntryID)
        guard Set(lineupEntryIDs).count == lineupEntryIDs.count else {
            throw StadiaFantasyBackendError.invalidLineup("A player can only occupy one lineup slot.")
        }
        for playerEntryID in lineupEntryIDs where !rosterEntryIDs.contains(playerEntryID) {
            throw StadiaFantasyBackendError.invalidLineup("Lineup contains a player that is not on this roster.")
        }
        let entriesByID = Dictionary(uniqueKeysWithValues: roster.entries.map { ($0.id, $0) })
        for slot in lineup.slots {
            guard league.rosterConfiguration.slotCounts[slot.slot, default: 0] > 0 else {
                throw StadiaFantasyBackendError.invalidLineup("\(slot.slot.displayAbbreviation) is not part of this roster configuration.")
            }
            if let entry = entriesByID[slot.playerEntryID], !Self.isEligible(entry: entry, for: slot.slot) {
                throw StadiaFantasyBackendError.invalidLineup("\(entry.playerName) is not eligible for \(slot.slot.displayAbbreviation).")
            }
        }
        let counts = Dictionary(grouping: lineup.slots, by: \.slot).mapValues(\.count)
        for (slot, count) in counts {
            let allowed = league.rosterConfiguration.slotCounts[slot] ?? 0
            guard count <= allowed else {
                throw StadiaFantasyBackendError.invalidLineup("Too many players in \(slot.displayAbbreviation).")
            }
        }
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        if let envelope = try? decoder.decode(StadiaFantasyPersistenceEnvelope.self, from: data), envelope.schemaVersion <= StadiaFantasyPersistenceEnvelope.currentSchemaVersion {
            bundles = envelope.bundles
        } else {
            bundles = (try? decoder.decode([StadiaFantasyLeagueBundle].self, from: data)) ?? []
        }
    }

    private func save() throws {
        let envelope = StadiaFantasyPersistenceEnvelope(schemaVersion: StadiaFantasyPersistenceEnvelope.currentSchemaVersion, bundles: bundles)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func isPlayerRostered(_ canonicalPlayerID: String, in bundle: StadiaFantasyLeagueBundle) -> Bool {
        bundle.rosters.flatMap(\.entries).contains { $0.canonicalPlayerID == canonicalPlayerID }
    }

    private func rosterEntry(for player: StadiaFantasyAvailablePlayer, leagueID: String, teamID: String) -> StadiaFantasyPlayerEntry {
        StadiaFantasyPlayerEntry(
            id: UUID().uuidString,
            leagueID: leagueID,
            teamID: teamID,
            canonicalPlayerID: player.id,
            playerName: player.fullName,
            nhlTeamAbbreviation: player.teamAbbreviation,
            primaryPosition: player.position,
            eligibleSlots: player.eligibleSlots,
            injuryStatus: player.injuryStatus,
            acquiredAt: Date()
        )
    }

    private func draftPick(_ player: StadiaFantasyAvailablePlayer, teamID: String, leagueIndex: Int, draft: inout StadiaFantasyDraft) {
        let leagueID = bundles[leagueIndex].league.id
        let entry = rosterEntry(for: player, leagueID: leagueID, teamID: teamID)
        if let rosterIndex = bundles[leagueIndex].rosters.firstIndex(where: { $0.teamID == teamID }) {
            bundles[leagueIndex].rosters[rosterIndex].entries.append(entry)
        }
        if let pickIndex = draft.picks.firstIndex(where: { $0.overallPick == draft.currentPickOverall }) {
            draft.picks[pickIndex].canonicalPlayerID = player.id
            draft.picks[pickIndex].playerName = player.fullName
            draft.picks[pickIndex].madeAt = Date()
        }
        bundles[leagueIndex].transactions.insert(Self.transaction(leagueID: leagueID, teamID: teamID, type: .draftPick, playerEntryIDs: [entry.id], description: "Drafted \(player.fullName)"), at: 0)
    }

    private func autoDraftCPUSelections(leagueIndex: Int, draft: inout StadiaFantasyDraft, availablePlayers: [StadiaFantasyAvailablePlayer]) {
        let userTeamIDs = Set(bundles[leagueIndex].memberships.map(\.userID)).compactMap { userID in
            bundles[leagueIndex].teams.first { $0.ownerUserID == userID }?.id
        }
        while let currentPick = draft.picks.first(where: { $0.overallPick == draft.currentPickOverall && $0.canonicalPlayerID == nil }), !userTeamIDs.contains(currentPick.teamID) {
            let roster = bundles[leagueIndex].rosters.first { $0.teamID == currentPick.teamID }
            let draftedIDs = Set(bundles[leagueIndex].rosters.flatMap(\.entries).map(\.canonicalPlayerID))
            guard let player = Self.bestCPUPlayer(from: availablePlayers.filter { !draftedIDs.contains($0.id) }, roster: roster, configuration: bundles[leagueIndex].league.rosterConfiguration) else { break }
            draftPick(player, teamID: currentPick.teamID, leagueIndex: leagueIndex, draft: &draft)
            guard let next = draft.picks.filter({ $0.canonicalPlayerID == nil }).map(\.overallPick).min() else { break }
            draft.currentPickOverall = next
        }
    }

    private func advanceDraft(_ draft: StadiaFantasyDraft, in bundle: StadiaFantasyLeagueBundle) -> StadiaFantasyDraft {
        var updated = draft
        if let next = updated.picks.filter({ $0.canonicalPlayerID == nil }).map(\.overallPick).min() {
            updated.currentPickOverall = next
            updated.status = .drafting
        } else {
            updated.status = .complete
            if let index = bundles.firstIndex(where: { $0.league.id == bundle.league.id }) {
                bundles[index].league.phase = .inSeason
            }
        }
        return updated
    }

    private static func abbreviation(for name: String) -> String {
        let letters = name.split(separator: " ").compactMap(\.first)
        let abbreviation = letters.isEmpty ? String(name.prefix(3)) : String(letters.prefix(3))
        return abbreviation.uppercased()
    }

    private static func cpuTeams(leagueID: String, count: Int) -> [StadiaFantasyTeam] {
        let names = ["Ice Breakers", "Goal Line", "Fast Break", "Diamond Club", "Power Play", "Red Zone", "Baseline", "Bullpen", "North Stars", "City Skaters", "Sunday Squad", "Late Shift"]
        return (0..<count).map { index in
            let name = names[index % names.count]
            return StadiaFantasyTeam(id: UUID().uuidString, leagueID: leagueID, ownerUserID: "cpu-\(leagueID)-\(index + 1)", displayName: name, abbreviation: abbreviation(for: name), avatarID: nil)
        }
    }

    private static func draftRounds(for rosterConfiguration: StadiaFantasyRosterConfiguration) -> Int {
        rosterConfiguration.slotCounts
            .filter { slot, _ in slot != .injuredReserve && slot != .injuredList }
            .map(\.value)
            .reduce(0, +)
    }

    private static func snakeDraftPicks(leagueID: String, teamIDs: [String], rounds: Int) -> [StadiaFantasyDraftPick] {
        guard !teamIDs.isEmpty, rounds > 0 else { return [] }
        var picks: [StadiaFantasyDraftPick] = []
        for round in 1...rounds {
            let order = round.isMultiple(of: 2) ? Array(teamIDs.reversed()) : teamIDs
            for (index, teamID) in order.enumerated() {
                let overall = picks.count + 1
                picks.append(StadiaFantasyDraftPick(id: UUID().uuidString, leagueID: leagueID, teamID: teamID, round: round, pickInRound: index + 1, overallPick: overall, canonicalPlayerID: nil, playerName: nil, madeAt: nil))
            }
        }
        return picks
    }

    private static func bestCPUPlayer(from players: [StadiaFantasyAvailablePlayer], roster: StadiaFantasyRoster?, configuration: StadiaFantasyRosterConfiguration) -> StadiaFantasyAvailablePlayer? {
        guard !players.isEmpty else { return nil }
        let currentSlots = roster?.entries.flatMap(\.eligibleSlots) ?? []
        let filledCounts = Dictionary(grouping: currentSlots, by: { $0 }).mapValues(\.count)
        return players.max { lhs, rhs in
            scoreCPUPlayer(lhs, filledCounts: filledCounts, configuration: configuration) < scoreCPUPlayer(rhs, filledCounts: filledCounts, configuration: configuration)
        }
    }

    private static func scoreCPUPlayer(_ player: StadiaFantasyAvailablePlayer, filledCounts: [StadiaFantasyRosterSlot: Int], configuration: StadiaFantasyRosterConfiguration) -> Double {
        let needScore = player.eligibleSlots.map { slot -> Double in
            let target = configuration.slotCounts[slot] ?? 0
            guard target > 0 else { return 0 }
            let filled = filledCounts[slot] ?? 0
            return max(0, Double(target - filled)) / Double(target)
        }.max() ?? 0
        let positionBonus = player.eligibleSlots.contains(.goalie) || player.eligibleSlots.contains(.quarterback) || player.eligibleSlots.contains(.startingPitcher) ? 0.15 : 0
        let injuryPenalty = player.injuryStatus == nil ? 0 : -0.35
        return needScore + positionBonus + injuryPenalty + Double(stableTieBreaker(for: player.id) % 100) / 10_000
    }

    private static func stableTieBreaker(for id: String) -> Int {
        id.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 10_000 }
    }

    private static func matchups(leagueID: String, teams: [StadiaFantasyTeam], start: Date, periods: Int) -> [StadiaFantasyMatchup] {
        guard teams.count > 1 else { return [] }
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        var generated: [StadiaFantasyMatchup] = []
        for period in 1...max(1, periods) {
            let periodStart = calendar.date(byAdding: .day, value: (period - 1) * 7, to: startDay) ?? startDay
            let periodEnd = calendar.date(byAdding: .day, value: 7, to: periodStart) ?? periodStart.addingTimeInterval(7 * 24 * 3600)
            for pairIndex in stride(from: 0, to: teams.count - 1, by: 2) {
                let home = teams[pairIndex]
                let away = teams[(pairIndex + period) % teams.count]
                guard home.id != away.id else { continue }
                generated.append(StadiaFantasyMatchup(
                    id: "\(leagueID)-period-\(period)-\(home.id)-\(away.id)",
                    leagueID: leagueID,
                    matchupPeriod: period,
                    startsAt: periodStart,
                    endsAt: periodEnd,
                    home: StadiaFantasyMatchupSide(teamID: home.id, points: nil, categoryValues: [:], categoryWins: nil),
                    away: StadiaFantasyMatchupSide(teamID: away.id, points: nil, categoryValues: [:], categoryWins: nil),
                    winnerTeamID: nil
                ))
            }
        }
        return generated
    }

    private static func isEligible(entry: StadiaFantasyPlayerEntry, for slot: StadiaFantasyRosterSlot) -> Bool {
        if slot == .bench { return true }
        if slot == .injuredReserve || slot == .injuredList { return entry.injuryStatus != nil }
        return entry.eligibleSlots.contains(slot) || entry.eligibleSlots.contains(.utility) && slot == .utility || entry.eligibleSlots.contains(.flex) && slot == .flex
    }

    private static func transaction(leagueID: String, teamID: String?, type: StadiaFantasyTransactionType, playerEntryIDs: [String], description: String) -> StadiaFantasyTransaction {
        StadiaFantasyTransaction(id: UUID().uuidString, leagueID: leagueID, teamID: teamID, type: type, playerEntryIDs: playerEntryIDs, description: description, createdAt: Date())
    }

    private static func inviteCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }
}

private extension StadiaFantasyLeagueBundle {
    func copySelecting(teamID: String) -> StadiaFantasyLeagueBundle { self }
}

protocol FantasySportScoringStrategy: Sendable {
    func score(statLine: StadiaFantasyStatLine, rules: StadiaFantasyScoringRules) -> StadiaFantasyPlayerScore
}

struct DefaultFantasySportScoringStrategy: FantasySportScoringStrategy {
    func score(statLine: StadiaFantasyStatLine, rules: StadiaFantasyScoringRules) -> StadiaFantasyPlayerScore {
        switch rules.type {
        case .headToHeadPoints:
            let points = rules.rules.reduce(0) { partial, rule in
                partial + statLine[rule.stat] * rule.points
            }
            return StadiaFantasyPlayerScore(playerEntryID: "", points: points, categoryValues: [:])
        case .headToHeadCategories, .rotisserie:
            var values: [StadiaFantasyStat: Double] = [:]
            for rule in rules.rules where rule.enabledForCategories {
                values[rule.stat] = statLine[rule.stat]
            }
            return StadiaFantasyPlayerScore(playerEntryID: "", points: nil, categoryValues: values)
        }
    }
}

struct NFLFantasyScoringStrategy: FantasySportScoringStrategy { private let base = DefaultFantasySportScoringStrategy(); func score(statLine: StadiaFantasyStatLine, rules: StadiaFantasyScoringRules) -> StadiaFantasyPlayerScore { base.score(statLine: statLine, rules: rules) } }
struct NHLFantasyScoringStrategy: FantasySportScoringStrategy { private let base = DefaultFantasySportScoringStrategy(); func score(statLine: StadiaFantasyStatLine, rules: StadiaFantasyScoringRules) -> StadiaFantasyPlayerScore { base.score(statLine: statLine, rules: rules) } }
struct NBAFantasyScoringStrategy: FantasySportScoringStrategy { private let base = DefaultFantasySportScoringStrategy(); func score(statLine: StadiaFantasyStatLine, rules: StadiaFantasyScoringRules) -> StadiaFantasyPlayerScore { base.score(statLine: statLine, rules: rules) } }
struct MLBFantasyScoringStrategy: FantasySportScoringStrategy { private let base = DefaultFantasySportScoringStrategy(); func score(statLine: StadiaFantasyStatLine, rules: StadiaFantasyScoringRules) -> StadiaFantasyPlayerScore { base.score(statLine: statLine, rules: rules) } }

struct FantasyScoringEngine: Sendable {
    func score(statLine: StadiaFantasyStatLine, rules: StadiaFantasyScoringRules, sport: FantasySport = .nhl) -> StadiaFantasyPlayerScore {
        strategy(for: sport).score(statLine: statLine, rules: rules)
    }

    func points(for entries: [StadiaFantasyPlayerEntry], statLines: [String: StadiaFantasyStatLine], rules: StadiaFantasyScoringRules, sport: FantasySport = .nhl) -> [String: StadiaFantasyPlayerScore] {
        Dictionary(uniqueKeysWithValues: entries.map { entry in
            var score = score(statLine: statLines[entry.canonicalPlayerID] ?? StadiaFantasyStatLine(values: [:], appearances: 0), rules: rules, sport: sport)
            score = StadiaFantasyPlayerScore(playerEntryID: entry.id, points: score.points, categoryValues: score.categoryValues)
            return (entry.id, score)
        })
    }

    func categoryWinner(home: Double, away: Double, stat: StadiaFantasyStat) -> Int {
        if home == away { return 0 }
        if stat.lowerIsBetter { return home < away ? 1 : -1 }
        return home > away ? 1 : -1
    }

    private func strategy(for sport: FantasySport) -> any FantasySportScoringStrategy {
        switch sport {
        case .nfl: NFLFantasyScoringStrategy()
        case .nhl: NHLFantasyScoringStrategy()
        case .nba: NBAFantasyScoringStrategy()
        case .mlb: MLBFantasyScoringStrategy()
        }
    }
}
