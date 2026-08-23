import Foundation

// MARK: - Intermediate adapter types

/// Raw channel record produced by a provider adapter before ID assignment and normalization.
/// Named `AdapterChannel` to avoid collision with the existing `ProviderChannel` in IPTVOrgModels.
struct AdapterChannel: Sendable {
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

    init(name: String, streamURL: URL, logoURL: URL? = nil, groupTitle: String? = nil,
         tvgID: String? = nil, tvgName: String? = nil, rawIndex: Int = 0,
         xtreamStreamID: Int? = nil, xtreamCategoryID: String? = nil,
         archiveEnabled: Bool = false, archiveDays: Int = 0, catchupSource: String? = nil) {
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
    }
}

struct AdapterGroup: Sendable {
    var id: String
    var title: String
}

// MARK: - Protocol

/// Abstracts a live TV source behind a uniform interface.
/// Implementations must be Sendable so they can cross actor boundaries.
protocol LiveProviderAdapter: Sendable {
    var provider: LiveProvider { get }
    func loadGroups() async throws -> [AdapterGroup]
    func loadChannels() async throws -> [AdapterChannel]
    func resolveStream(for channel: LiveChannel) async throws -> StreamDescriptor
}

// MARK: - Provider error

enum LiveProviderError: LocalizedError, Sendable {
    case missingConfiguration(String)
    case badResponse
    case noStreamAvailable
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let detail): return "Provider misconfigured: \(detail)"
        case .badResponse: return "The provider returned an unexpected response."
        case .noStreamAvailable: return "No stream URL is available for this channel."
        case .authenticationFailed: return "Provider credentials are invalid or missing."
        }
    }
}

// MARK: - Stable channel ID generation

enum LiveChannelIDGenerator {
    /// DJB2 hash — stable across Swift versions, process restarts, and platforms.
    static func stableHash(_ string: String) -> String {
        var hash: UInt32 = 5381
        for byte in string.utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt32(byte)
        }
        return String(hash, radix: 16, uppercase: false)
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

extension LiveChannel {
    /// Constructs a LiveChannel from an AdapterChannel emitted by any adapter.
    static func make(from ac: AdapterChannel, providerID: UUID, kind: LiveProviderKind) -> LiveChannel {
        let channelID: String
        switch kind {
        case .m3u:
            channelID = LiveChannelIDGenerator.m3uChannelID(
                providerID: providerID, tvgID: ac.tvgID,
                name: ac.name, group: ac.groupTitle)
        case .xtream:
            channelID = LiveChannelIDGenerator.xtreamChannelID(
                providerID: providerID, streamID: ac.xtreamStreamID ?? 0)
        }

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
            archiveDays: ac.archiveDays
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
