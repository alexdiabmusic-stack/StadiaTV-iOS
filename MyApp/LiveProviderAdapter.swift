import Foundation

// MARK: - Intermediate adapter types

/// Raw channel record produced by a provider adapter before ID assignment and normalization.
nonisolated struct AdapterChannel: Sendable {
    var name: String
    var streamURL: URL
    var logoURL: URL?
    var groupTitle: String?
    var tvgID: String?
    var tvgName: String?
    var rawIndex: Int
    var xtreamStreamID: Int?
    var xtreamCategoryID: String?
    var archiveEnabled: Bool
    var archiveDays: Int
    var catchupSource: String?   // M3U catchup-source URL template
    var httpHeaders: [String: String]?   // #EXTVLCOPT / #KODIPROP / pipe-suffix headers

    init(name: String, streamURL: URL, logoURL: URL? = nil, groupTitle: String? = nil,
         tvgID: String? = nil, tvgName: String? = nil, rawIndex: Int = 0,
         xtreamStreamID: Int? = nil, xtreamCategoryID: String? = nil,
         archiveEnabled: Bool = false, archiveDays: Int = 0, catchupSource: String? = nil,
         httpHeaders: [String: String]? = nil) {
        self.name = name
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.groupTitle = groupTitle
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.rawIndex = rawIndex
        self.xtreamStreamID = xtreamStreamID
        self.xtreamCategoryID = xtreamCategoryID
        self.archiveEnabled = archiveEnabled
        self.archiveDays = archiveDays
        self.catchupSource = catchupSource
        self.httpHeaders = httpHeaders
    }
}

nonisolated struct AdapterGroup: Sendable {
    var id: String
    var title: String
}

// MARK: - Protocol

/// Abstracts a live TV source behind a uniform interface.
/// Implementations must be Sendable so they can cross actor boundaries.
nonisolated protocol LiveProviderAdapter: Sendable {
    var provider: LiveProvider { get }
    func loadGroups() async throws -> [AdapterGroup]
    func loadChannels() async throws -> (epgURL: String?, channels: [AdapterChannel])
    func resolveStream(for channel: LiveChannel) async throws -> StreamDescriptor
}

// MARK: - Provider error

nonisolated enum LiveProviderError: LocalizedError, Sendable, Equatable {
    case missingConfiguration(String)
    case badResponse
    case httpStatus(Int)
    /// The provider answered, but with no channels. Panels send an empty list for an expired or banned
    /// account and when they are limiting requests as often as for a real lineup.
    case noChannels
    case noStreamAvailable
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let detail): return "Provider misconfigured: \(detail)"
        case .badResponse: return "The provider returned an unexpected response."
        case .httpStatus(let code): return Self.describe(httpStatus: code)
        case .noChannels: return "The provider returned no channels. The account may have expired or the provider may be limiting requests; try again in a few minutes."
        case .noStreamAvailable: return "No stream URL is available for this channel."
        case .authenticationFailed: return "Provider credentials are invalid or missing."
        }
    }

    private static func describe(httpStatus code: Int) -> String {
        switch code {
        case 401, 403: return "The provider refused the request (HTTP \(code)). Check the username, password and expiry date."
        case 429: return "The provider is limiting requests (HTTP 429). Try again in a few minutes."
        case 500...599: return "The provider's server is having trouble (HTTP \(code)). Try again later."
        default: return "The provider answered with HTTP \(code)."
        }
    }
}

// MARK: - Stable channel ID generation

nonisolated enum LiveChannelIDGenerator {
    /// DJB2 hash — stable across Swift versions, process restarts, and platforms.
    static func stableHash(_ string: String) -> String {
        var hash: UInt32 = 5381
        for byte in string.utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt32(byte)
        }
        return String(hash, radix: 16, uppercase: false)
    }

    /// Channel IDs for a whole playlist, in playlist order, each naming exactly one channel.
    ///
    /// Providers repeat tvg-ids (HD / SD / backup entries of one channel) and repeat names, and a
    /// 32-bit hash can collide besides. An ID is the cache's primary key and the key favourites and
    /// preferences are stored under, so it can't be shared: the first holder keeps the plain ID
    /// (existing favourites still resolve) and later holders get `~2`, `~3`… in playlist order.
    static func uniqueChannelIDs(for channels: [AdapterChannel], providerID: UUID, kind: LiveProviderKind) -> [String] {
        var seen: [String: Int] = [:]
        seen.reserveCapacity(channels.count)
        return channels.map { channel in
            let base = channelID(for: channel, providerID: providerID, kind: kind)
            let occurrence = (seen[base] ?? 0) + 1
            seen[base] = occurrence
            return occurrence == 1 ? base : "\(base)~\(occurrence)"
        }
    }

    /// The ID a channel would have if no other channel in its playlist shared it.
    static func channelID(for channel: AdapterChannel, providerID: UUID, kind: LiveProviderKind) -> String {
        switch kind {
        case .m3u:
            return m3uChannelID(providerID: providerID, tvgID: channel.tvgID, name: channel.name, group: channel.groupTitle)
        case .xtream:
            return xtreamChannelID(providerID: providerID, streamID: channel.xtreamStreamID ?? 0)
        }
    }

    /// M3U channel with tvg-id: keyed by the tvg-id for maximum stability.
    /// M3U channel without tvg-id: keyed by normalised name+group.
    static func m3uChannelID(providerID: UUID, tvgID: String?, name: String, group: String?) -> String {
        if let tvgID, !tvgID.isEmpty {
            return "\(providerID.uuidString)-m3u-tvg:\(stableHash(tvgID))"
        }
        let key = "\(name.lowercased())|\(group?.lowercased() ?? "")"
        return "\(providerID.uuidString)-m3u:\(stableHash(key))"
    }

    /// Xtream channel: uses the provider-assigned stream_id.
    /// Format matches the legacy `"\(playlist.id)-\(stream_id)"` exactly,
    /// so existing Xtream favorites survive the migration.
    static func xtreamChannelID(providerID: UUID, streamID: Int) -> String {
        "\(providerID.uuidString)-\(streamID)"
    }

    static func streamDescriptorID(channelID: String, index: Int) -> String {
        "\(channelID)-s\(index)"
    }
}

// MARK: - LiveChannel factory

nonisolated extension LiveChannel {
    /// Constructs every LiveChannel of one playlist, with IDs that are unique within it.
    static func makeAll(from adapterChannels: [AdapterChannel], providerID: UUID, kind: LiveProviderKind) -> [LiveChannel] {
        let ids = LiveChannelIDGenerator.uniqueChannelIDs(for: adapterChannels, providerID: providerID, kind: kind)
        return zip(adapterChannels, ids).map { make(from: $0, providerID: providerID, kind: kind, channelID: $1) }
    }

    /// Constructs a LiveChannel from an AdapterChannel emitted by any adapter.
    /// `channelID` overrides the ID derived from the channel itself (see `makeAll`).
    static func make(from ac: AdapterChannel, providerID: UUID, kind: LiveProviderKind, channelID: String? = nil) -> LiveChannel {
        let channelID = channelID ?? LiveChannelIDGenerator.channelID(for: ac, providerID: providerID, kind: kind)

        let streamID = LiveChannelIDGenerator.streamDescriptorID(channelID: channelID, index: 0)
        let stream = StreamDescriptor(
            id: streamID,
            streamURL: ac.streamURL,
            providerID: providerID,
            resolution: StreamResolution.detect(from: ac.name),
            tvgID: ac.tvgID,
            tvgName: ac.tvgName,
            tvgLogoURL: ac.logoURL,
            groupTitle: ac.groupTitle,
            archiveEnabled: ac.archiveEnabled,
            archiveDays: ac.archiveDays,
            httpHeaders: ac.httpHeaders
        )

        let catchup: CatchupCapability? = ac.archiveEnabled ? CatchupCapability(
            isEnabled: true,
            daysAvailable: ac.archiveDays,
            type: kind == .xtream ? .xStreamCodes : .default,
            templateURL: ac.catchupSource
        ) : nil

        return LiveChannel(
            id: channelID,
            providerID: providerID,
            providerKind: kind,
            name: ac.name,
            logoURL: ac.logoURL,
            groupTitle: ac.groupTitle,
            streams: [stream],
            catchup: catchup,
            tvgID: ac.tvgID,
            xtreamStreamID: ac.xtreamStreamID,
            xtreamCategoryID: ac.xtreamCategoryID
        )
    }
}
