import Foundation

/// Resolves a calendar year to `/api/seasons`' own `ID` (verified live: year 2026 → 75)
/// rather than assuming they're equal — `/api/seasons` is a flat list back to the
/// league's founding, so this also caches the result instead of refetching per lookup.
actor CFLSeasonIdentity {
    static let shared = CFLSeasonIdentity()
    private let client: any CFLClientProtocol
    private var byYear: [Int: Int] = [:]
    private var all: [CFLValue]?

    init(client: any CFLClientProtocol = CFLClient.shared) { self.client = client }

    func seasonID(for year: Int) async throws -> Int {
        if let cached = byYear[year] { return cached }
        let seasons = try await seasonsList()
        guard let match = seasons.first(where: { $0["year"].int == year }), let id = match["ID"].int else {
            throw CFLAPIError.invalidResponse
        }
        byYear[year] = id
        return id
    }
    private func seasonsList() async throws -> [CFLValue] {
        if let all { return all }
        let seasons = try await client.get(.seasons, as: [CFLValue].self, maxAge: 86400)
        all = seasons
        return seasons
    }
}
