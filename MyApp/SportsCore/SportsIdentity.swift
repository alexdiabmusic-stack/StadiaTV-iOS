import Foundation

nonisolated struct SportsIdentityResolver: Sendable {
    func canonicalTeamID(league: League, provider: SportsDataProviderID, providerTeamID: String?, abbreviation: String, displayName: String) -> BannerEntityID {
        BannerEntityID(rawValue: "team:\(league.bannerKey):\(provider.rawValue):\(providerTeamID ?? abbreviation)")
    }
    func canonicalPlayerID(league: League, provider: SportsDataProviderID, providerPlayerID: String?, fullName: String, birthDate: Date? = nil, teamAbbreviation: String? = nil) -> BannerEntityID {
        BannerEntityID(rawValue: "player:\(league.bannerKey):\(provider.rawValue):\(providerPlayerID ?? Self.slug(fullName))")
    }
    func canonicalGameID(league: League, provider: SportsDataProviderID, providerGameID: String?, home: BannerTeam, away: BannerTeam, scheduledStart: Date) -> BannerEntityID {
        BannerEntityID(rawValue: "game:\(league.bannerKey):\(provider.rawValue):\(providerGameID ?? "")")
    }
    static func canonicalLeagueID(for league: League) -> BannerEntityID {
        BannerEntityID(rawValue: "league:\(league.bannerKey)")
    }
    static func providerID(from id: BannerEntityID, provider: SportsDataProviderID) -> String? {
        let parts = id.rawValue.split(separator: ":")
        guard parts.count == 4, parts[2] == Substring(provider.rawValue) else { return nil }
        return String(parts[3])
    }
    static func slug(_ value: String) -> String {
        value.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }
}
nonisolated enum SportsProviderRouteConfiguration {
    static func leagueKey(forLegacyPath path: String) -> String { "league.\(SportsIdentityResolver.slug(path))" }
}
