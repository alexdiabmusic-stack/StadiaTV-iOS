import Foundation

/// One fantasy team ESPN's account-wide "fan" endpoint reports for the signed-in SWID, across
/// every sport — this is what lets Banner list "your leagues" right after web sign-in instead of
/// asking the user to go find a numeric League ID on espn.com themselves.
struct ESPNDiscoveredLeague: Identifiable, Hashable, Sendable {
    let sport: FantasySport
    let leagueID: String
    let seasonID: Int
    let teamName: String?

    var id: String { "\(sport.rawValue):\(leagueID):\(seasonID)" }
}

/// Calls ESPN's unofficial, undocumented "fan" API to discover which leagues the just-signed-in
/// account belongs to. This endpoint isn't part of ESPN's public Fantasy API (there is no
/// documented "list my leagues" call) and its response shape is reconstructed from community
/// reverse-engineering rather than official docs, so every field below is decoded defensively
/// and a league is kept only if the handful of fields Banner actually needs are present.
/// Unverified against a live ESPN account — if ESPN has changed this response shape, discovery
/// will just come back empty and the user falls back to entering a League ID manually.
struct ESPNFanLeagueDiscoveryClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    nonisolated init(
        baseURL: URL = URL(string: "https://fan.api.espn.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func discoverLeagues(credentials: ESPNFantasyCredentials) async throws -> [ESPNDiscoveredLeague] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/apis/v2/fans/\(credentials.normalizedSWID)"
        components.queryItems = [
            URLQueryItem(name: "displayHiddenEntries", value: "true"),
            URLQueryItem(name: "displayHiddenInternationalEntries", value: "true"),
            URLQueryItem(name: "platform", value: "fantasy")
        ]
        guard let url = components.url else { throw FantasyProviderError.invalidIdentifier }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.cookieHeaderValue, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FantasyProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw FantasyProviderError.authenticationRequired }
            throw FantasyProviderError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ESPNFanPreferencesResponseDTO.self, from: data)
        let entries = (decoded.preferences ?? []).compactMap { $0.metaData?.entry }

        var seen = Set<String>()
        var leagues: [ESPNDiscoveredLeague] = []
        for entry in entries {
            guard
                let groupID = entry.groupId,
                let seasonID = entry.seasonId,
                let gameID = entry.gameId,
                let sport = ESPNFantasyGameCode(token: gameID)?.sport
            else { continue }
            let league = ESPNDiscoveredLeague(
                sport: sport,
                leagueID: String(groupID),
                seasonID: seasonID,
                teamName: entry.name
            )
            guard seen.insert(league.id).inserted else { continue }
            leagues.append(league)
        }
        return leagues
    }
}

private struct ESPNFanPreferencesResponseDTO: Decodable, Sendable {
    let preferences: [ESPNFanPreferenceDTO]?
}

private struct ESPNFanPreferenceDTO: Decodable, Sendable {
    let metaData: ESPNFanPreferenceMetaDataDTO?
}

private struct ESPNFanPreferenceMetaDataDTO: Decodable, Sendable {
    let entry: ESPNFanEntryDTO?
}

private struct ESPNFanEntryDTO: Decodable, Sendable {
    let groupId: Int?
    let seasonId: Int?
    let gameId: String?
    let name: String?
}
