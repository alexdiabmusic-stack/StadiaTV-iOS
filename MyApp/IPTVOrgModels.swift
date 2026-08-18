import Foundation

// MARK: - Provider Channel (raw Xtream / M3U provider record)

struct ProviderChannel: Decodable, Identifiable {
    let num: Int
    let name: String
    let streamType: String
    let streamId: Int
    let streamIcon: String?
    let epgChannelId: String?
    let added: String?
    let categoryId: String?
    let tvArchive: Int
    let tvArchiveDuration: Int

    var id: Int { streamId }
    var archiveEnabled: Bool { tvArchive == 1 }
    var iconURL: URL? {
        guard let s = streamIcon, !s.isEmpty, let u = URL(string: s) else { return nil }
        return u
    }

    private enum CodingKeys: String, CodingKey {
        case num, name, added
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelId = "epg_channel_id"
        case categoryId = "category_id"
        case tvArchive = "tv_archive"
        case tvArchiveDuration = "tv_archive_duration"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = try c.decode(Int.self, forKey: .num)
        name = try c.decode(String.self, forKey: .name)
        streamType = (try? c.decode(String.self, forKey: .streamType)) ?? "live"
        streamId = try c.decode(Int.self, forKey: .streamId)
        streamIcon = try? c.decode(String.self, forKey: .streamIcon)
        epgChannelId = try? c.decode(String.self, forKey: .epgChannelId)
        added = try? c.decode(String.self, forKey: .added)
        categoryId = try? c.decode(String.self, forKey: .categoryId)
        tvArchive = (try? c.decode(Int.self, forKey: .tvArchive)) ?? 0
        // tv_archive_duration can be a String "2" or an Int 0
        if let i = try? c.decode(Int.self, forKey: .tvArchiveDuration) {
            tvArchiveDuration = i
        } else if let s = try? c.decode(String.self, forKey: .tvArchiveDuration), let i = Int(s) {
            tvArchiveDuration = i
        } else {
            tvArchiveDuration = 0
        }
    }
}

// MARK: - IPTV-org Channel

struct IPTVOrgChannel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let altNames: [String]
    let network: String?
    let owners: [String]
    let country: String
    let categories: [String]
    let isNsfw: Bool
    let launched: String?
    let closed: String?
    let replacedBy: String?
    let website: String?

    var isClosed: Bool { closed != nil }

    private enum CodingKeys: String, CodingKey {
        case id, name, network, owners, country, categories, launched, closed, website
        case altNames = "alt_names"
        case isNsfw = "is_nsfw"
        case replacedBy = "replaced_by"
    }

    static func == (lhs: IPTVOrgChannel, rhs: IPTVOrgChannel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - IPTV-org Logo

struct IPTVOrgLogo: Decodable {
    let channel: String
    let feed: String?
    let inUse: Bool
    let tags: [String]
    let width: Int
    let height: Int
    let format: String?
    let url: String

    var resolvedURL: URL? { URL(string: url) }

    nonisolated var isSupported: Bool {
        guard let fmt = format?.uppercased() else { return true }
        return ["PNG", "JPEG", "JPG", "WEBP", "SVG"].contains(fmt)
    }

    private enum CodingKeys: String, CodingKey {
        case channel, feed, tags, width, height, format, url
        case inUse = "in_use"
    }
}

// MARK: - Resolved Channel Logo

enum LogoSource: String, Hashable {
    case manual
    case provider
    case iptvOrgExact
    case iptvOrgBridge
    case xmltv
    case textFallback
}

enum LogoMatchMethod: String, Hashable {
    case manualOverride
    case providerIconHighConfidence
    case iptvOrgExactId
    case iptvOrgCaseFoldedId
    case iptvOrgMetadataBridge
    case xmltvIcon
    case providerIconLowConfidence
    case textFallback
}

struct ResolvedChannelLogo: Hashable {
    let canonicalChannelId: String
    let url: URL?
    let source: LogoSource
    let matchMethod: LogoMatchMethod
    let confidence: Double
    let feed: String?
    let tags: [String]

    var isTextFallback: Bool { url == nil || source == .textFallback }

    static func == (lhs: ResolvedChannelLogo, rhs: ResolvedChannelLogo) -> Bool {
        lhs.canonicalChannelId == rhs.canonicalChannelId && lhs.url == rhs.url
    }
    func hash(into hasher: inout Hasher) { hasher.combine(canonicalChannelId) }
}

// MARK: - Identity Evidence and Conflicts

enum IdentityMatchMethod: String, Hashable {
    case manual
    case providerEpgExact
    case providerEpgCaseInsensitive
    case curatedAlias
    case curatedNormalizedExact
    case iptvOrgExactId
    case iptvOrgCaseInsensitiveId
    case iptvOrgAltName
    case networkMarket
    case replacementChain
    case fuzzy
    case unmatched
}

struct IdentityConflict: Hashable {
    let field: String
    let expected: String
    let actual: String
}

struct ChannelIdentityEvidence {
    let providerChannelId: String
    let providerName: String
    let normalizedName: String
    let providerEpgId: String?
    let providerCategoryId: String?
    let providerIconURL: String?
    let countryHint: String?
    let networkHint: String?
    let curatedCandidateKey: String?
    let iptvOrgCandidateId: String?
    let matchMethod: IdentityMatchMethod
    let confidence: Double
    let conflicts: [IdentityConflict]

    var isHighConfidence: Bool { confidence >= 0.85 }
    var hasConflicts: Bool { !conflicts.isEmpty }
}
