import Foundation

struct TeamPodcastSeed: Codable, Identifiable {
    let id: String
    let league: String
    let sport: String
    let teamName: String
    let aliases: [String]
    let countryStorefront: String
    let minimumTeamSpecificShows: Int
    let searchTerms: [String]

    enum CodingKeys: String, CodingKey {
        case id, league, sport, aliases
        case teamName = "team_name"
        case countryStorefront = "country_storefront"
        case minimumTeamSpecificShows = "minimum_team_specific_shows"
        case searchTerms = "search_terms"
    }
}

struct ApplePodcastSearchResponse: Decodable { let results: [ApplePodcast] }
struct ApplePodcast: Decodable, Hashable {
    let collectionId: Int?
    let collectionName: String?
    let artistName: String?
    let feedUrl: URL?
    let collectionViewUrl: URL?
    let artworkUrl600: URL?
}

enum TeamPodcastResolverError: Error { case invalidURL, insufficientCoverage(found: Int) }

actor TeamPodcastResolver {
    private let session: URLSession
    private var cache: [String: (Date, [ApplePodcast])] = [:]
    private let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    init(session: URLSession = .shared) { self.session = session }

    func podcasts(for team: TeamPodcastSeed) async throws -> [ApplePodcast] {
        if let cached = cache[team.id], Date().timeIntervalSince(cached.0) < cacheLifetime,
           cached.1.count >= team.minimumTeamSpecificShows { return cached.1 }

        var byFeed: [URL: ApplePodcast] = [:]
        for term in team.searchTerms.prefix(4) {
            var components = URLComponents(string: "https://itunes.apple.com/search")
            components?.queryItems = [
                .init(name: "term", value: term), .init(name: "media", value: "podcast"),
                .init(name: "entity", value: "podcast"), .init(name: "limit", value: "50"),
                .init(name: "country", value: team.countryStorefront)
            ]
            guard let url = components?.url else { throw TeamPodcastResolverError.invalidURL }
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let result = try JSONDecoder().decode(ApplePodcastSearchResponse.self, from: data)
            for podcast in result.results where podcast.feedUrl != nil {
                if score(podcast, for: team) >= 70 { byFeed[podcast.feedUrl!] = podcast }
            }
            if byFeed.count >= team.minimumTeamSpecificShows { break }
        }
        let ranked = byFeed.values.sorted { score($0, for: team) > score($1, for: team) }
        let selected = Array(ranked.prefix(team.minimumTeamSpecificShows))
        guard selected.count >= team.minimumTeamSpecificShows else {
            throw TeamPodcastResolverError.insufficientCoverage(found: selected.count)
        }
        cache[team.id] = (Date(), selected)
        return selected
    }

    private func score(_ podcast: ApplePodcast, for team: TeamPodcastSeed) -> Int {
        let text = [podcast.collectionName, podcast.artistName].compactMap { $0?.lowercased() }.joined(separator: " ")
        var score = text.contains(team.teamName.lowercased()) ? 140 : 0
        for alias in team.aliases.dropFirst() where alias.count >= 4 && text.contains(alias.lowercased()) { score += 55 }
        if text.contains("locked on") { score += 12 }
        if text.contains(team.league.lowercased()) { score += 8 }
        return score
    }
}
