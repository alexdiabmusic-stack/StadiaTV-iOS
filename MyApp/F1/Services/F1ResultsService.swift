import Foundation

actor F1ResultsService {
    static let shared = F1ResultsService()
    func result(for session: F1ScheduledSession) async throws -> F1SessionState? {
        guard session.type == .race else { return nil }
        let raw = try await F1CalendarService.shared.resource("\(session.season)/\(session.round)/results/")
        return Self.normalize(raw, session: session)
    }
    nonisolated static func normalize(_ raw: F1Value, session: F1ScheduledSession) -> F1SessionState? {
        guard let race = raw["MRData"]["RaceTable"]["Races"].array.first, race["season"].int == session.season, race["round"].int == session.round else { return nil }
        let rows = race["Results"].array
        guard !rows.isEmpty else { return nil }
        var state = F1SessionState(identity: session.id)
        state.meeting = session.meeting; state.circuit = session.circuit; state.name = session.name; state.type = session.type
        state.status = "Finalised"; state.updatedAt = .now
        state.drivers = rows.compactMap { row in
            let person = row["Driver"]
            guard let number = row["number"].string ?? person["permanentNumber"].string ?? person["driverId"].string else { return nil }
            let driver = F1Driver(number: number, name: [person["givenName"].string, person["familyName"].string].compactMap { $0 }.joined(separator: " "), tla: person["code"].string ?? number, team: row["Constructor"]["name"].string ?? "", colour: nil, country: person["nationality"].string, headshot: nil)
            var timing = F1DriverTimingState(driver: driver, position: row["position"].int, gap: row["Time"]["time"].string, interval: nil, lastLap: nil, bestLap: row["FastestLap"]["Time"]["time"].string, qualifyingTimes: [], laps: row["laps"].int, sectors: [], speeds: [:], bestSectors: [], stints: [], inPit: false, pitOut: false, stops: nil, retired: false, stopped: false, knockedOut: false, overallFastest: false, personalFastest: false)
            timing.classificationStatus = row["status"].string
            return timing
        }.sorted { ($0.position ?? 999) < ($1.position ?? 999) }
        state.currentLap = state.drivers.first?.laps
        return state
    }
    nonisolated static func merge(_ official: F1SessionState, into archive: F1SessionState) -> F1SessionState {
        guard official.identity == archive.identity else { return archive }
        var result = archive
        let previous = Dictionary(archive.drivers.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        result.drivers = official.drivers.map { row in
            guard var rich = previous[row.id] else { return row }
            rich.position = row.position; rich.classificationStatus = row.classificationStatus
            return rich
        }
        result.status = official.status
        return result
    }
}
