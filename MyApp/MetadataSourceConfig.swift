import Foundation

// MARK: - Metadata Source

struct MetadataSource: Identifiable, Hashable {
    let id: String
    let displayName: String
    let remoteURL: URL
    var enabled: Bool
    let cacheTTL: TimeInterval  // slow-moving data: 7 days

    static func == (lhs: MetadataSource, rhs: MetadataSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Registry

enum MetadataSourceRegistry {

    // swiftlint:disable force_unwrapping
    static let iptvOrgChannels = MetadataSource(
        id: "iptv_org_channels",
        displayName: "IPTV-org Channel Database",
        remoteURL: URL(string: "https://raw.githubusercontent.com/iptv-org/database/master/data/channels.json")!,
        enabled: true,
        cacheTTL: 7 * 24 * 3600
    )

    static let iptvOrgLogos = MetadataSource(
        id: "iptv_org_logos",
        displayName: "IPTV-org Logo Database",
        remoteURL: URL(string: "https://raw.githubusercontent.com/iptv-org/logos/master/logs/channels.json")!,
        enabled: true,
        cacheTTL: 7 * 24 * 3600
    )
    // swiftlint:enable force_unwrapping

    static let all: [MetadataSource] = [iptvOrgChannels, iptvOrgLogos]
}
