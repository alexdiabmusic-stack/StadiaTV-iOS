import Foundation

/// Resolves the current LaLiga EA Sports (`primera-division`) subscription slug.
/// `/subscriptions` mixes in every other competition the site tracks (Copa del Rey,
/// UCL, even Bundesliga — 241 entries observed live 2026-09-24) and is not sorted by
/// relevance, so this walks it page by page matching on `competition.slug` + `year`
/// rather than assuming the `laliga-easports-{year}` naming convention or trusting
/// the first page (Step 2). An `actor` (not a pure function) because that walk is a
/// real network round trip, same reasoning as `MLSSeasonResolver`; cached 24h since
/// the season boundary only moves once a year.
actor LaLigaSeasonResolver {
    static let shared = LaLigaSeasonResolver()
    private let client: any LaLigaClientProtocol
    private var cache: (Date, String)?

    init(client: any LaLigaClientProtocol = LaLigaClient.shared) { self.client = client }

    /// The season's starting year. La Liga's calendar year spans two seasons — July
    /// fixtures are still the prior season's, same boundary rule as `EPLSeasonResolver`.
    /// September 2026 -> 2026/27 (year 2026); February 2027 -> still 2026/27 (Step 38).
    static func startingYear(for date: Date = Date(), calendar: Calendar = .current) -> Int {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        return month >= 7 ? year : year - 1
    }

    func currentSubscriptionSlug(for date: Date = Date()) async throws -> String {
        let year = Self.startingYear(for: date)
        if let (time, slug) = cache, Date().timeIntervalSince(time) < 86400 { return slug }
        let pageSize = 100
        let maxPages = 6 // covers 600 subscriptions; 241 observed live 2026-09-24
        for page in 0..<maxPages {
            let raw = try await client.subscriptions(offset: page * pageSize, limit: pageSize)
            let subscriptions = raw["subscriptions"].array
            if let match = subscriptions.first(where: {
                $0["competition"]["slug"].string == LaLigaProviderConfiguration.competitionSlug && $0["year"].int == year
            }), let slug = match["slug"].string {
                cache = (Date(), slug)
                return slug
            }
            if subscriptions.count < pageSize { break }
        }
        throw LaLigaAPIError.decoding("No LaLiga EA Sports subscription found for season \(year)")
    }
}
