import Foundation

actor F1Provider: NativeSportsProvider {
    nonisolated let leaguePath = "racing/f1"
    private let calendar: F1CalendarService
    private var standingsCache: (Date, [StandingsGroup])?
    init(calendar: F1CalendarService = .shared) { self.calendar = calendar }
    func scores(on date: Date?) async throws -> [Match] {
        var games = try await schedule(start: date ?? Date(), days: 1)
        guard Calendar.current.isDateInToday(date ?? Date()), games.contains(where: { $0.date.timeIntervalSinceNow < 3600 && $0.date.timeIntervalSinceNow > -12 * 3600 }) else { return games }
        let updates = await F1LiveSnapshotService.shared.snapshot()
        guard let info = updates.first(where: { $0.topic == "SessionInfo" })?.payload,
              let start = F1ArchiveService.utcStart(info) else { return games }
        for index in games.indices {
            guard abs(games[index].date.timeIntervalSince(start)) < 3600,
                  let scheduled = try await calendar.session(id: games[index].id),
                  F1SessionType(info["Name"].string ?? info["Type"].string ?? "") == scheduled.type else { continue }
            if scheduled.type == .practice && info["Name"].string != scheduled.name { continue }
            let store = F1TopicStateStore(identity: scheduled.id)
            for update in updates { await store.apply(update) }
            let state = await store.normalized()
            games[index] = await Self.match(scheduled, snapshot: state)
        }
        try Task.checkCancellation()
        return games
    }
    func schedule(start: Date, days: Int) async throws -> [Match] {
        let lower = Calendar.current.startOfDay(for: start), end = Calendar.current.date(byAdding: .day, value: max(1, days), to: lower) ?? lower
        let years = Set([Calendar.current.component(.year, from: lower), Calendar.current.component(.year, from: end)])
        var sessions: [F1ScheduledSession] = []
        for year in years { sessions += try await calendar.meetings(season: year).flatMap(\.sessions).filter { $0.start >= lower && $0.start < end } }
        let discovered = sessions
        return await MainActor.run { discovered.sorted { $0.start < $1.start }.map { Self.match($0) } }
    }
    @MainActor static func match(_ session: F1ScheduledSession, snapshot: F1SessionState? = nil) -> Match {
        let league = League(name: "Formula 1", shortName: "F1", path: "racing/f1", group: .racing)
        let side = TeamSide(displayName: session.meeting, shortName: "F1", abbreviation: "F1", logoURL: nil, score: nil, record: nil, isWinner: false)
        var match = Match(id: session.id, league: league, date: session.start, name: session.meeting + " · " + session.name, shortName: session.meeting,
            state: snapshot?.completed == true ? .final : snapshot?.active == true ? .live : .pre, statusDetail: snapshot?.currentLap.map { "\(session.name) · Lap \($0)" } ?? session.name, home: side, away: side, broadcasts: [], venue: session.circuit)
        // Calendar time is not evidence of a healthy live timing connection.
        match.canonicalID = "game:\(league.bannerKey):f1:\(session.id)"
        return match
    }
    func teams() async throws -> [Team] {
        let raw = try await calendar.resource("current/constructors/")
        return await MainActor.run { raw["MRData"]["ConstructorTable"]["Constructors"].array.compactMap { item in
            guard let id = item["constructorId"].string, let name = item["name"].string else { return nil }
            return Team(id: id, displayName: name, shortDisplayName: name, abbreviation: name, logoURL: nil, canonicalIDString: "team:league.racing-f1:f1:\(id)")
        } }
    }
    func standings() async throws -> [StandingsGroup] {
        if let (time, rows) = standingsCache, Date().timeIntervalSince(time) < 1800 { return rows }
        async let drivers = calendar.resource("current/driverstandings/")
        async let constructors = calendar.resource("current/constructorstandings/")
        let (d, c) = try await (drivers, constructors)
        let result = [Self.standingGroup(d, drivers: true), Self.standingGroup(c, drivers: false)]
        standingsCache = (Date(), result); return result
    }
    private nonisolated static func standingGroup(_ raw: F1Value, drivers: Bool) -> StandingsGroup {
        let list = raw["MRData"]["StandingsTable"]["StandingsLists"].array.first ?? .null
        let rows = list[drivers ? "DriverStandings" : "ConstructorStandings"].array.compactMap { row -> StandingRow? in
            let entity = row[drivers ? "Driver" : "Constructor"]
            guard let id = entity[drivers ? "driverId" : "constructorId"].string else { return nil }
            let name = drivers ? [entity["givenName"].string, entity["familyName"].string].compactMap { $0 }.joined(separator: " ") : entity["name"].string ?? "Constructor"
            return StandingRow(teamID: id, displayName: name, abbreviation: entity["code"].string ?? name, logoURL: nil,
                record: row["points"].string.map { "\($0) points" } ?? "–", wins: row["wins"].string, losses: nil, ties: nil, winPercent: nil, gamesBack: nil, streak: nil, pointsFor: nil, pointsAgainst: nil, leaguePoints: row["points"].string, gamesPlayed: nil, goalDiff: nil, leagueRank: row["position"].string)
        }
        return StandingsGroup(id: drivers ? "f1-drivers" : "f1-constructors", name: drivers ? "Driver championship" : "Constructor championship", rows: rows)
    }
    func roster(teamID: String) async throws -> [RosterGroup] {
        guard teamID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw F1LiveTimingError.invalidResponse }
        let raw = try await calendar.resource("current/constructors/\(teamID)/drivers/")
        let athletes = raw["MRData"]["DriverTable"]["Drivers"].array.compactMap(Self.athlete)
        return [RosterGroup(id: teamID, title: "Drivers", athletes: athletes)]
    }
    private nonisolated static func athlete(_ raw: F1Value) -> RosterAthlete? {
        guard let id = raw["driverId"].string else { return nil }
        return RosterAthlete(id: id, displayName: [raw["givenName"].string, raw["familyName"].string].compactMap { $0 }.joined(separator: " "), jersey: raw["permanentNumber"].string, position: "Driver", positionName: "Driver", headshotURL: nil, age: nil, displayHeight: nil, displayWeight: nil, college: nil, experienceYears: nil, birthPlace: raw["nationality"].string, isInjured: false, canonicalID: "player:league.racing-f1:f1:\(id)")
    }
    func playerOverview(id: String) async throws -> AthleteOverview {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw F1LiveTimingError.invalidResponse }
        let raw = try await calendar.resource("current/drivers/\(id)/driverstandings/")
        let row = raw["MRData"]["StandingsTable"]["StandingsLists"].array.first?["DriverStandings"].array.first ?? .null
        let stats = ["position", "points", "wins"].compactMap { key -> StatValue? in row[key].string.map { StatValue(label: key, displayName: key.capitalized, value: $0) } }
        return AthleteOverview(statlineLabel: "Championship", stats: stats, headlineStats: stats, news: [])
    }
    func racers() async throws -> [Racer] {
        let raw = try await calendar.resource("current/driverstandings/")
        let rows = raw["MRData"]["StandingsTable"]["StandingsLists"].array.first?["DriverStandings"].array ?? []
        return await MainActor.run {
            rows.compactMap { row in
                let driver = row["Driver"]
                guard let id = driver["driverId"].string else { return nil }
                return Racer(id: id, name: [driver["givenName"].string, driver["familyName"].string].compactMap { $0 }.joined(separator: " "), shortName: driver["code"].string ?? id, teamName: row["Constructors"].array.last?["name"].string ?? "", place: nil, flagURL: nil, isWinner: false)
            }
        }
    }
}
