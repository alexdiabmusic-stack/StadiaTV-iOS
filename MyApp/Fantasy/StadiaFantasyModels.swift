import Foundation

// MARK: - Native Stadia Fantasy Domain

enum StadiaFantasyLeagueSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case importedESPN
    case importedSleeper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native: return "Stadia"
        case .importedESPN: return "ESPN Fantasy"
        case .importedSleeper: return "Sleeper"
        }
    }
}

enum StadiaFantasyVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case `public`
    case `private`

    var id: String { rawValue }
    var displayName: String { self == .public ? "Public" : "Private" }
}

enum StadiaFantasyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case personalTeam
    case simulatedLeague

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .personalTeam: return "Personal Team"
        case .simulatedLeague: return "Simulated League"
        }
    }
}

enum StadiaFantasyScoringType: String, Codable, CaseIterable, Identifiable, Sendable {
    case headToHeadPoints
    case headToHeadCategories
    case rotisserie

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .headToHeadPoints: return "Head-to-Head Points"
        case .headToHeadCategories: return "Head-to-Head Categories"
        case .rotisserie: return "Rotisserie"
        }
    }
}

enum StadiaFantasyDraftType: String, Codable, CaseIterable, Identifiable, Sendable {
    case snake

    var id: String { rawValue }
    var displayName: String { "Snake Draft" }
}

enum StadiaFantasyLeaguePhase: String, Codable, Sendable {
    case lobby
    case drafting
    case inSeason
    case playoffs
    case complete
}

enum StadiaFantasyMembershipRole: String, Codable, Sendable {
    case commissioner
    case manager
}

enum StadiaFantasyRosterSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case center = "C"
    case leftWing = "LW"
    case rightWing = "RW"
    case forward = "F"
    case defense = "D"
    case goalie = "G"
    case utility = "UTIL"
    case bench = "BN"
    case injuredReserve = "IR"
    case quarterback = "QB"
    case runningBack = "RB"
    case wideReceiver = "WR"
    case tightEnd = "TE"
    case flex = "FLEX"
    case kicker = "K"
    case defenseSpecialTeams = "DST"
    case pointGuard = "PG"
    case shootingGuard = "SG"
    case smallForward = "SF"
    case powerForward = "PF"
    case comboGuard = "GARD"
    case firstBase = "1B"
    case secondBase = "2B"
    case thirdBase = "3B"
    case shortstop = "SS"
    case outfield = "OF"
    case startingPitcher = "SP"
    case reliefPitcher = "RP"
    case pitcher = "P"
    case injuredList = "IL"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .center: return "Center"
        case .leftWing: return "Left Wing"
        case .rightWing: return "Right Wing"
        case .forward: return "Forward"
        case .defense: return "Defense"
        case .goalie: return "Goalie"
        case .utility: return "Utility"
        case .bench: return "Bench"
        case .injuredReserve: return "IR"
        case .quarterback: return "Quarterback"
        case .runningBack: return "Running Back"
        case .wideReceiver: return "Wide Receiver"
        case .tightEnd: return "Tight End"
        case .flex: return "Flex"
        case .kicker: return "Kicker"
        case .defenseSpecialTeams: return "Defense/Special Teams"
        case .pointGuard: return "Point Guard"
        case .shootingGuard: return "Shooting Guard"
        case .smallForward: return "Small Forward"
        case .powerForward: return "Power Forward"
        case .comboGuard: return "Guard"
        case .firstBase: return "First Base"
        case .secondBase: return "Second Base"
        case .thirdBase: return "Third Base"
        case .shortstop: return "Shortstop"
        case .outfield: return "Outfield"
        case .startingPitcher: return "Starting Pitcher"
        case .reliefPitcher: return "Relief Pitcher"
        case .pitcher: return "Pitcher"
        case .injuredList: return "IL"
        }
    }

    var displayAbbreviation: String {
        self == .comboGuard ? "G" : rawValue
    }

    var isActive: Bool { self != .bench && self != .injuredReserve && self != .injuredList }
}

enum StadiaFantasyStat: String, Codable, CaseIterable, Identifiable, Sendable {
    case goals
    case assists
    case plusMinus
    case penaltyMinutes
    case powerPlayPoints
    case shortHandedPoints
    case shotsOnGoal
    case hits
    case blockedShots
    case goalieWins
    case saves
    case goalsAgainst
    case shutouts
    case overtimeLosses
    case goalsAgainstAverage
    case savePercentage
    case passingYards
    case passingTouchdowns
    case interceptions
    case completions
    case rushingYards
    case rushingTouchdowns
    case receptions
    case receivingYards
    case receivingTouchdowns
    case fieldGoalsMade
    case extraPointsMade
    case defensiveSacks
    case defensiveTakeaways
    case points
    case rebounds
    case steals
    case threePointersMade
    case fieldGoalPercentage
    case freeThrowPercentage
    case turnovers
    case runs
    case homeRuns
    case runsBattedIn
    case stolenBases
    case battingAverage
    case onBasePercentage
    case hitsAllowed
    case totalBases
    case pitcherWins
    case savesPitching
    case strikeouts
    case earnedRunAverage
    case walksHitsPerInningPitched
    case inningsPitched
    case qualityStarts

    var id: String { rawValue }

    var abbreviation: String {
        switch self {
        case .goals: return "G"
        case .assists: return "A"
        case .plusMinus: return "+/-"
        case .penaltyMinutes: return "PIM"
        case .powerPlayPoints: return "PPP"
        case .shortHandedPoints: return "SHP"
        case .shotsOnGoal: return "SOG"
        case .hits: return "HIT"
        case .blockedShots: return "BLK"
        case .goalieWins: return "W"
        case .saves: return "SV"
        case .goalsAgainst: return "GA"
        case .shutouts: return "SO"
        case .overtimeLosses: return "OTL"
        case .goalsAgainstAverage: return "GAA"
        case .savePercentage: return "SV%"
        case .passingYards: return "PaYd"
        case .passingTouchdowns: return "PaTD"
        case .interceptions: return "INT"
        case .completions: return "CMP"
        case .rushingYards: return "RuYd"
        case .rushingTouchdowns: return "RuTD"
        case .receptions: return "REC"
        case .receivingYards: return "ReYd"
        case .receivingTouchdowns: return "ReTD"
        case .fieldGoalsMade: return "FGM"
        case .extraPointsMade: return "XPM"
        case .defensiveSacks: return "SACK"
        case .defensiveTakeaways: return "TAKE"
        case .points: return "PTS"
        case .rebounds: return "REB"
        case .steals: return "STL"
        case .threePointersMade: return "3PM"
        case .fieldGoalPercentage: return "FG%"
        case .freeThrowPercentage: return "FT%"
        case .turnovers: return "TO"
        case .runs: return "R"
        case .homeRuns: return "HR"
        case .runsBattedIn: return "RBI"
        case .stolenBases: return "SB"
        case .battingAverage: return "AVG"
        case .onBasePercentage: return "OBP"
        case .hitsAllowed: return "H"
        case .totalBases: return "TB"
        case .pitcherWins: return "W"
        case .savesPitching: return "SV"
        case .strikeouts: return "K"
        case .earnedRunAverage: return "ERA"
        case .walksHitsPerInningPitched: return "WHIP"
        case .inningsPitched: return "IP"
        case .qualityStarts: return "QS"
        }
    }

    var lowerIsBetter: Bool { [.goalsAgainstAverage, .goalsAgainst, .turnovers, .earnedRunAverage, .walksHitsPerInningPitched].contains(self) }
    var isRatio: Bool { [.goalsAgainstAverage, .savePercentage, .fieldGoalPercentage, .freeThrowPercentage, .battingAverage, .onBasePercentage, .earnedRunAverage, .walksHitsPerInningPitched].contains(self) }
}

struct StadiaFantasySeason: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let year: Int
    let startsAt: Date?
    let endsAt: Date?
    let scoringPeriodDays: Int
}

struct StadiaFantasyScoringRule: Identifiable, Codable, Hashable, Sendable {
    var id: String { stat.rawValue }
    let stat: StadiaFantasyStat
    var points: Double
    var enabledForCategories: Bool
}

struct StadiaFantasyScoringRules: Codable, Hashable, Sendable {
    var type: StadiaFantasyScoringType
    var rules: [StadiaFantasyScoringRule]

    static func stadiaDefault(sport: FantasySport, type: StadiaFantasyScoringType = .headToHeadPoints) -> StadiaFantasyScoringRules {
        FantasySportConfiguration.configuration(for: sport).defaultScoring(type: type)
    }

    static func stadiaDefault(type: StadiaFantasyScoringType = .headToHeadPoints) -> StadiaFantasyScoringRules {
        stadiaDefault(sport: .nhl, type: type)
    }
}

struct StadiaFantasyRosterConfiguration: Codable, Hashable, Sendable {
    var slotCounts: [StadiaFantasyRosterSlot: Int]

    static func standard(for sport: FantasySport) -> StadiaFantasyRosterConfiguration {
        FantasySportConfiguration.configuration(for: sport).defaultRoster
    }

    static let standard = StadiaFantasyRosterConfiguration.standard(for: .nhl)
}

enum FantasyLineupFrequency: String, Codable, Sendable {
    case weekly
    case daily
}

enum FantasyMatchupStructure: String, Codable, Sendable {
    case weekly
    case dailyScoringPeriods
    case seasonLong
}

enum FantasyLockRule: String, Codable, Sendable {
    case gameStart
    case scoringPeriodStart
}

struct FantasySportConfiguration: Hashable, Sendable {
    let sport: FantasySport
    let eligiblePositions: [StadiaFantasyRosterSlot]
    let defaultRoster: StadiaFantasyRosterConfiguration
    let availableScoringCategories: [StadiaFantasyStat]
    let lineupFrequency: FantasyLineupFrequency
    let matchupStructure: FantasyMatchupStructure
    let lockRule: FantasyLockRule
    let relevantLiveStatistics: [StadiaFantasyStat]

    func defaultScoring(type: StadiaFantasyScoringType = .headToHeadPoints) -> StadiaFantasyScoringRules {
        StadiaFantasyScoringRules(type: type, rules: availableScoringCategories.map { stat in
            StadiaFantasyScoringRule(stat: stat, points: Self.defaultPointValue(for: stat), enabledForCategories: true)
        })
    }

    static func configuration(for sport: FantasySport) -> FantasySportConfiguration {
        switch sport {
        case .nfl: return football
        case .nhl: return hockey
        case .nba: return basketball
        case .mlb: return baseball
        }
    }

    private static let football = FantasySportConfiguration(
        sport: .nfl,
        eligiblePositions: [.quarterback, .runningBack, .wideReceiver, .tightEnd, .flex, .kicker, .defenseSpecialTeams, .bench, .injuredReserve],
        defaultRoster: StadiaFantasyRosterConfiguration(slotCounts: [.quarterback: 1, .runningBack: 2, .wideReceiver: 2, .tightEnd: 1, .flex: 1, .kicker: 1, .defenseSpecialTeams: 1, .bench: 6, .injuredReserve: 2]),
        availableScoringCategories: [.passingYards, .passingTouchdowns, .interceptions, .rushingYards, .rushingTouchdowns, .receptions, .receivingYards, .receivingTouchdowns, .fieldGoalsMade, .extraPointsMade, .defensiveSacks, .defensiveTakeaways],
        lineupFrequency: .weekly,
        matchupStructure: .weekly,
        lockRule: .gameStart,
        relevantLiveStatistics: [.passingYards, .passingTouchdowns, .rushingYards, .rushingTouchdowns, .receptions, .receivingYards, .receivingTouchdowns]
    )

    private static let hockey = FantasySportConfiguration(
        sport: .nhl,
        eligiblePositions: [.center, .leftWing, .rightWing, .forward, .defense, .goalie, .utility, .bench, .injuredReserve],
        defaultRoster: StadiaFantasyRosterConfiguration(slotCounts: [.center: 2, .leftWing: 2, .rightWing: 2, .defense: 4, .goalie: 2, .utility: 1, .bench: 5, .injuredReserve: 2]),
        availableScoringCategories: [.goals, .assists, .plusMinus, .penaltyMinutes, .powerPlayPoints, .shortHandedPoints, .shotsOnGoal, .hits, .blockedShots, .goalieWins, .saves, .goalsAgainst, .shutouts, .overtimeLosses, .goalsAgainstAverage, .savePercentage],
        lineupFrequency: .daily,
        matchupStructure: .dailyScoringPeriods,
        lockRule: .gameStart,
        relevantLiveStatistics: [.goals, .assists, .shotsOnGoal, .hits, .blockedShots, .saves]
    )

    private static let basketball = FantasySportConfiguration(
        sport: .nba,
        eligiblePositions: [.pointGuard, .shootingGuard, .smallForward, .powerForward, .center, .comboGuard, .forward, .utility, .bench, .injuredReserve],
        defaultRoster: StadiaFantasyRosterConfiguration(slotCounts: [.pointGuard: 1, .shootingGuard: 1, .smallForward: 1, .powerForward: 1, .center: 1, .comboGuard: 1, .forward: 1, .utility: 2, .bench: 5, .injuredReserve: 2]),
        availableScoringCategories: [.points, .rebounds, .assists, .steals, .blockedShots, .threePointersMade, .fieldGoalPercentage, .freeThrowPercentage, .turnovers],
        lineupFrequency: .daily,
        matchupStructure: .dailyScoringPeriods,
        lockRule: .gameStart,
        relevantLiveStatistics: [.points, .rebounds, .assists, .steals, .blockedShots, .threePointersMade]
    )

    private static let baseball = FantasySportConfiguration(
        sport: .mlb,
        eligiblePositions: [.center, .firstBase, .secondBase, .thirdBase, .shortstop, .outfield, .utility, .startingPitcher, .reliefPitcher, .pitcher, .bench, .injuredList],
        defaultRoster: StadiaFantasyRosterConfiguration(slotCounts: [.center: 1, .firstBase: 1, .secondBase: 1, .thirdBase: 1, .shortstop: 1, .outfield: 3, .utility: 1, .startingPitcher: 2, .reliefPitcher: 2, .pitcher: 2, .bench: 5, .injuredList: 2]),
        availableScoringCategories: [.runs, .homeRuns, .runsBattedIn, .stolenBases, .battingAverage, .onBasePercentage, .hitsAllowed, .totalBases, .pitcherWins, .savesPitching, .strikeouts, .earnedRunAverage, .walksHitsPerInningPitched, .inningsPitched, .qualityStarts],
        lineupFrequency: .daily,
        matchupStructure: .dailyScoringPeriods,
        lockRule: .gameStart,
        relevantLiveStatistics: [.runs, .homeRuns, .runsBattedIn, .stolenBases, .pitcherWins, .savesPitching, .strikeouts]
    )

    private static func defaultPointValue(for stat: StadiaFantasyStat) -> Double {
        switch stat {
        case .goals: return 3
        case .assists: return 2
        case .shotsOnGoal: return 0.4
        case .hits: return 0.2
        case .blockedShots: return 0.5
        case .powerPlayPoints: return 0.5
        case .shortHandedPoints: return 1
        case .goalieWins: return 4
        case .saves: return 0.2
        case .goalsAgainst: return -1
        case .shutouts: return 3
        case .overtimeLosses: return 1
        case .passingYards, .rushingYards, .receivingYards: return 0.04
        case .passingTouchdowns: return 4
        case .rushingTouchdowns, .receivingTouchdowns: return 6
        case .interceptions, .turnovers: return -2
        case .receptions: return 0.5
        case .fieldGoalsMade: return 3
        case .extraPointsMade: return 1
        case .defensiveSacks: return 1
        case .defensiveTakeaways: return 2
        case .points: return 1
        case .rebounds: return 1.2
        case .steals: return 3
        case .threePointersMade: return 1
        case .runs, .runsBattedIn: return 1
        case .homeRuns: return 4
        case .stolenBases: return 2
        case .totalBases: return 1
        case .pitcherWins, .savesPitching, .qualityStarts: return 5
        case .strikeouts: return 1
        case .inningsPitched: return 3
        case .goalsAgainstAverage, .savePercentage, .fieldGoalPercentage, .freeThrowPercentage, .battingAverage, .onBasePercentage, .earnedRunAverage, .walksHitsPerInningPitched, .plusMinus, .penaltyMinutes, .completions, .hitsAllowed:
            return 0
        }
    }
}

struct StadiaFantasyDraftSettings: Codable, Hashable, Sendable {
    var type: StadiaFantasyDraftType
    var scheduledAt: Date?
    var pickTimerSeconds: Int
    var draftOrderTeamIDs: [String]

    static let standard = StadiaFantasyDraftSettings(type: .snake, scheduledAt: nil, pickTimerSeconds: 90, draftOrderTeamIDs: [])
}

struct StadiaFantasyWaiverSettings: Codable, Hashable, Sendable {
    enum WaiverType: String, Codable, CaseIterable, Identifiable, Sendable {
        case freeAgency
        case rollingPriority
        case faab
        var id: String { rawValue }
    }

    var type: WaiverType
    var waiverPeriodHours: Int
    var usesFAAB: Bool
    var faabBudget: Int?

    static let standard = StadiaFantasyWaiverSettings(type: .rollingPriority, waiverPeriodHours: 24, usesFAAB: false, faabBudget: nil)
}

struct StadiaFantasyTradeSettings: Codable, Hashable, Sendable {
    enum ReviewType: String, Codable, CaseIterable, Identifiable, Sendable {
        case none
        case commissioner
        case leagueVote
        var id: String { rawValue }
    }

    var deadline: Date?
    var reviewType: ReviewType
}

struct StadiaFantasyPlayoffSettings: Codable, Hashable, Sendable {
    var regularSeasonPeriods: Int
    var playoffTeams: Int
    var playoffRounds: Int
    var championshipPeriod: Int?
}

struct StadiaFantasyLeague: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var source: StadiaFantasyLeagueSource
    var mode: StadiaFantasyMode?
    var sport: FantasySport
    var season: StadiaFantasySeason
    var phase: StadiaFantasyLeaguePhase
    var visibility: StadiaFantasyVisibility
    var inviteCode: String
    var commissionerUserID: String
    var maxTeams: Int
    var rosterConfiguration: StadiaFantasyRosterConfiguration
    var scoringRules: StadiaFantasyScoringRules
    var draftSettings: StadiaFantasyDraftSettings
    var waiverSettings: StadiaFantasyWaiverSettings
    var tradeSettings: StadiaFantasyTradeSettings
    var playoffSettings: StadiaFantasyPlayoffSettings
    var createdAt: Date
}

struct StadiaFantasyMembership: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let userID: String
    var displayName: String
    var role: StadiaFantasyMembershipRole
    var joinedAt: Date
}

struct StadiaFantasyTeam: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let ownerUserID: String
    var displayName: String
    var abbreviation: String
    var avatarID: String?
}

struct StadiaFantasyPlayerEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let teamID: String
    let canonicalPlayerID: String
    var playerName: String
    var nhlTeamAbbreviation: String?
    var primaryPosition: String?
    var eligibleSlots: [StadiaFantasyRosterSlot]
    var injuryStatus: String?
    var acquiredAt: Date
}

struct StadiaFantasyRoster: Identifiable, Codable, Hashable, Sendable {
    var id: String { teamID }
    let leagueID: String
    let teamID: String
    var entries: [StadiaFantasyPlayerEntry]
}

struct StadiaFantasyLineupSlot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let playerEntryID: String
    var slot: StadiaFantasyRosterSlot
    var lockedAt: Date?
}

struct StadiaFantasyLineup: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let teamID: String
    let scoringDate: Date
    var slots: [StadiaFantasyLineupSlot]
}

struct StadiaFantasyStatLine: Codable, Hashable, Sendable {
    var values: [StadiaFantasyStat: Double]
    var appearances: Int

    subscript(_ stat: StadiaFantasyStat) -> Double {
        values[stat] ?? 0
    }
}

struct StadiaFantasyPlayerScore: Identifiable, Codable, Hashable, Sendable {
    var id: String { playerEntryID }
    let playerEntryID: String
    let points: Double?
    let categoryValues: [StadiaFantasyStat: Double]
}

struct StadiaFantasyMatchupSide: Identifiable, Codable, Hashable, Sendable {
    var id: String { teamID }
    let teamID: String
    var points: Double?
    var categoryValues: [StadiaFantasyStat: Double]
    var categoryWins: Int?
}

struct StadiaFantasyMatchup: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let matchupPeriod: Int
    let startsAt: Date
    let endsAt: Date
    var home: StadiaFantasyMatchupSide
    var away: StadiaFantasyMatchupSide
    var winnerTeamID: String?
}

struct StadiaFantasyStanding: Identifiable, Codable, Hashable, Sendable {
    var id: String { teamID }
    let leagueID: String
    let teamID: String
    var rank: Int
    var wins: Int
    var losses: Int
    var ties: Int
    var pointsFor: Double?
    var pointsAgainst: Double?
}

enum StadiaFantasyTransactionType: String, Codable, Sendable {
    case add
    case drop
    case addDrop
    case waiver
    case trade
    case draftPick
    case lineupChange
}

struct StadiaFantasyPersistenceEnvelope: Codable, Sendable {
    var schemaVersion: Int
    var bundles: [StadiaFantasyLeagueBundle]

    static let currentSchemaVersion = 1
}

struct StadiaFantasyTransaction: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let teamID: String?
    let type: StadiaFantasyTransactionType
    var playerEntryIDs: [String]
    var description: String
    var createdAt: Date
}

struct StadiaFantasyWaiver: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case pending, processed, failed, cancelled }
    let id: String
    let leagueID: String
    let teamID: String
    let addCanonicalPlayerID: String
    let dropPlayerEntryID: String?
    let faabBid: Int?
    var status: Status
    var createdAt: Date
}

struct StadiaFantasyTrade: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case proposed, accepted, rejected, cancelled, underReview, processed }
    let id: String
    let leagueID: String
    let proposingTeamID: String
    let receivingTeamID: String
    var offeredPlayerEntryIDs: [String]
    var requestedPlayerEntryIDs: [String]
    var status: Status
    var createdAt: Date
}

struct StadiaFantasyDraftPick: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let teamID: String
    let round: Int
    let pickInRound: Int
    let overallPick: Int
    var canonicalPlayerID: String?
    var playerName: String?
    var madeAt: Date?
}

struct StadiaFantasyDraft: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    var status: StadiaFantasyLeaguePhase
    var currentPickOverall: Int
    var picks: [StadiaFantasyDraftPick]
}

struct StadiaFantasyLeagueBundle: Codable, Hashable, Sendable {
    var league: StadiaFantasyLeague
    var memberships: [StadiaFantasyMembership]
    var teams: [StadiaFantasyTeam]
    var rosters: [StadiaFantasyRoster]
    var lineups: [StadiaFantasyLineup]
    var matchups: [StadiaFantasyMatchup]
    var standings: [StadiaFantasyStanding]
    var transactions: [StadiaFantasyTransaction]
    var draft: StadiaFantasyDraft?

    func team(for userID: String) -> StadiaFantasyTeam? {
        teams.first { $0.ownerUserID == userID }
    }
}

extension StadiaFantasyLeague {
    var effectiveMode: StadiaFantasyMode {
        mode ?? (maxTeams <= 1 ? .personalTeam : .simulatedLeague)
    }
}

struct StadiaFantasyCreateLeagueRequest: Sendable {
    var sport: FantasySport
    var mode: StadiaFantasyMode
    var leagueName: String
    var teamName: String
    var maxTeams: Int
    var visibility: StadiaFantasyVisibility
    var scoringType: StadiaFantasyScoringType
    var rosterConfiguration: StadiaFantasyRosterConfiguration
    var scoringRules: StadiaFantasyScoringRules
    var draftSettings: StadiaFantasyDraftSettings
    var waiverSettings: StadiaFantasyWaiverSettings
    var tradeSettings: StadiaFantasyTradeSettings
    var playoffSettings: StadiaFantasyPlayoffSettings
}

struct StadiaFantasyJoinLeagueRequest: Sendable {
    var inviteCode: String
    var teamName: String
}
