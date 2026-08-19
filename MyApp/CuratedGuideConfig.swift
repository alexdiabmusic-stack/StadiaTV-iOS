import Foundation

// MARK: - Root config

nonisolated struct CuratedGuideConfig: Decodable {
    let schemaVersion: String
    let profiles: [String: CuratedProfile]
    let categories: [CuratedCategory]
    let normalization: CuratedNormalization
    let filterRules: CuratedFilterRules
    let deduplication: CuratedDeduplication
    let channels: [CuratedChannel]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case profiles, categories, normalization
        case filterRules = "filter_rules"
        case deduplication, channels
    }

    nonisolated static func load() -> CuratedGuideConfig? {
        guard let url = Bundle.main.url(forResource: "curated_tv_guide_filter", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CuratedGuideConfig.self, from: data)
    }
}

nonisolated struct CuratedProfile: Decodable {
    let description: String
    let includeTiers: [String]
    let includeOptional: Bool
    let hardMax: Int?

    private enum CodingKeys: String, CodingKey {
        case description
        case includeTiers = "include_tiers"
        case includeOptional = "include_optional"
        case hardMax = "hard_max"
    }
}

nonisolated struct CuratedCategory: Decodable, Identifiable {
    let id: String
    let name: String
    let defaultEnabled: Bool
    let sort: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, sort
        case defaultEnabled = "default_enabled"
    }
}

nonisolated struct CuratedNormalization: Decodable {
    let caseInsensitive: Bool
    let stripPrefixRegex: [String]
    let stripQualityTokensRegex: [String]
    let stripSourceTokensRegex: [String]
    let collapseWhitespace: Bool
    let preserveTokens: [String]

    private enum CodingKeys: String, CodingKey {
        case caseInsensitive = "case_insensitive"
        case stripPrefixRegex = "strip_prefix_regex"
        case stripQualityTokensRegex = "strip_quality_tokens_regex"
        case stripSourceTokensRegex = "strip_source_tokens_regex"
        case collapseWhitespace = "collapse_whitespace"
        case preserveTokens = "preserve_tokens"
    }
}

nonisolated struct CuratedFilterRules: Decodable {
    let alwaysHideNamePatterns: [String]
    let vodLikeNamePatterns: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alwaysHideNamePatterns = (try? c.decode([String].self, forKey: .alwaysHideNamePatterns)) ?? []
        vodLikeNamePatterns = (try? c.decode([String].self, forKey: .vodLikeNamePatterns)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case alwaysHideNamePatterns = "always_hide_name_patterns"
        case vodLikeNamePatterns = "vod_like_name_patterns"
    }
}

nonisolated struct CuratedDeduplication: Decodable {
    let fuzzyThreshold: Double
    let neverMergeIfDifferentMarket: Bool
    let neverMergeIfDifferentRegionalFeed: Bool

    private enum CodingKeys: String, CodingKey {
        case fuzzyThreshold = "fuzzy_threshold"
        case neverMergeIfDifferentMarket = "never_merge_if_different_market"
        case neverMergeIfDifferentRegionalFeed = "never_merge_if_different_regional_feed"
    }
}

nonisolated struct CuratedChannel: Decodable, Identifiable {
    let key: String
    let name: String
    let country: String
    let languages: [String]
    let category: String
    let tier: String
    let priority: Int
    let optional: Bool
    let aliases: [String]
    let market: String?
    let network: String?
    let epgId: String?

    nonisolated var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, name, country, languages, category, tier, priority
        case optional, aliases, market, network
        case epgId = "epg_id"
    }
}
