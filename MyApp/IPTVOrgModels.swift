import Foundation

// MARK: - Provider Channel (raw Xtream / M3U provider record)

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

struct IdentityConflict: Hashable {
    let field: String
    let expected: String
    let actual: String
}
