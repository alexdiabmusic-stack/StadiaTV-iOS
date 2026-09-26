import Foundation

/// Resolves a club crest for display, preferring the bundled local asset and falling
/// back to PulseLive's static badge host. This does NOT enumerate "the 20 Premier
/// League clubs" (promotion/relegation changes that every season — see
/// EPLSeasonResolver/EPLProvider, which fetch the current club list from the API).
/// It only records which clubs already have a bundled crest asset in this app bundle;
/// any team ID absent from this table (a newly promoted club, or one without an
/// asset yet) transparently falls back to a remote image, and `TeamLogo`'s own
/// `AsyncImage` placeholder covers the case where even that 403s.
nonisolated enum EPLAssetResolver {
    /// Team ID -> bundled `MSILogo_premier_league_<slug>` asset suffix. IDs are Opta's
    /// stable per-club identifiers (confirmed against the live API 2026-09-23).
    private static let localSlugs: [String: String] = [
        "3": "arsenal", "7": "aston_villa", "91": "bournemouth", "94": "brentford",
        "36": "brighton", "90": "burnley", "8": "chelsea", "31": "crystal_palace",
        "11": "everton", "54": "fulham", "2": "leeds", "14": "liverpool",
        "43": "manchester_city", "1": "manchester_united", "4": "newcastle",
        "17": "nottingham_forest", "20": "southampton", "56": "sunderland",
        "6": "tottenham", "21": "west_ham", "39": "wolves",
    ]

    static func logoURL(teamID: String) -> URL? {
        if let slug = localSlugs[teamID], let url = URL.bannerImageAsset(named: "MSILogo_premier_league_\(slug)") {
            return url
        }
        // PulseLive's badge SVGs can't be decoded by AsyncImage, but the same host
        // also serves a PNG variant at this path (verified 2026-09-23) — use that,
        // not the .svg pattern documented in the reverse-engineered API reference.
        return URL(string: "https://resources.premierleague.com/premierleague25/badges/\(teamID).png")
    }
}
