import Foundation

/// Resolves a La Liga official match to its FotMob match id (Step 16). Matching
/// signals: competition (league id 87), both team identities (normalized name —
/// Step 17), and a kickoff-time tolerance window — never score (Step 37).
/// Ambiguous results (zero or more than one candidate within the window) are
/// rejected outright rather than guessed; the caller then continues with
/// official-only data (Step 16, 35). Confirmed mappings are cached via
/// `SoccerProviderMappingStore` so the same fixture is never re-resolved every
/// poll (Step 36). As a side effect of a successful match resolution, this also
/// persists the corresponding home/away team-id mapping (Step 17) — no separate
/// team-resolution round trip is needed since both ids are already in hand.
actor LaLigaFotMobMatchResolver {
    static let shared = LaLigaFotMobMatchResolver()
    static let leagueID = 87

    private let client: any FotMobClientProtocol
    private let store: SoccerProviderMappingStore

    init(client: any FotMobClientProtocol = FotMobClient.shared, store: SoccerProviderMappingStore = .shared) {
        self.client = client
        self.store = store
    }

    func resolve(officialMatchID: String, homeTeamID: String, awayTeamID: String, homeTeamName: String, awayTeamName: String, kickoff: Date) async -> String? {
        if let cached = await store.fotmobMatchID(forOfficialMatchID: officialMatchID) { return cached }
        guard let candidates = try? await fixtures(around: kickoff) else { return nil }
        let normalizedHome = LaLigaFotMobTeamAliases.normalize(homeTeamName)
        let normalizedAway = LaLigaFotMobTeamAliases.normalize(awayTeamName)
        let matches = candidates.filter { candidate in
            abs(candidate.kickoff.timeIntervalSince(kickoff)) <= 6 * 3600 &&
            LaLigaFotMobTeamAliases.normalize(candidate.homeName) == normalizedHome &&
            LaLigaFotMobTeamAliases.normalize(candidate.awayName) == normalizedAway
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        await store.confirmMatch(officialID: officialMatchID, fotmobID: match.id)
        await store.confirmTeam(officialID: homeTeamID, fotmobID: match.homeID)
        await store.confirmTeam(officialID: awayTeamID, fotmobID: match.awayID)
        return match.id
    }

    private struct Candidate { let id: String; let homeID: String; let awayID: String; let homeName: String; let awayName: String; let kickoff: Date }

    /// `/api/data/matches?date=` is keyed by a single calendar date; a kickoff
    /// near midnight UTC could fall on either side, so this queries the kickoff
    /// date and its two neighbors and de-duplicates by id.
    private func fixtures(around kickoff: Date) async throws -> [Candidate] {
        let calendar = Calendar(identifier: .gregorian)
        var byID: [String: Candidate] = [:]
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: kickoff) else { continue }
            let raw = try await client.matches(date: Self.dateString(day), timezone: "UTC")
            for candidate in extractCandidates(raw) { byID[candidate.id] = candidate }
        }
        return Array(byID.values)
    }

    /// `/api/data/matches` groups fixtures by league; only La Liga's group (id 87)
    /// is relevant — everything else in the day's payload is ignored (Step 4's
    /// "don't mix competitions" rule applies here too, just on FotMob's side).
    private func extractCandidates(_ raw: FotMobValue) -> [Candidate] {
        raw["leagues"].array
            .filter { $0["id"].int == Self.leagueID || $0["primaryId"].int == Self.leagueID }
            .flatMap { $0["matches"].array }
            .compactMap { match -> Candidate? in
                guard let id = match["id"].string,
                      let homeID = match["home"]["id"].string, let awayID = match["away"]["id"].string,
                      let home = match["home"]["name"].string, let away = match["away"]["name"].string,
                      let kickoff = FotMobDate.parse(match["status"]["utcTime"].string) else { return nil }
                return Candidate(id: id, homeID: homeID, awayID: awayID, homeName: home, awayName: away, kickoff: kickoff)
            }
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}
