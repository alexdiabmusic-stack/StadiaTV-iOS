import Foundation

// MARK: - Provider Kind

enum LiveProviderKind: String, Codable, Sendable {
    case m3u
    case xtream
}

// MARK: - Live Provider

/// Canonical representation of a live TV source.
/// Maps 1:1 to the existing Playlist type so both describe the same source.
struct LiveProvider: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var kind: LiveProviderKind
    var m3uURL: String?
    var host: String?
    var credentialID: UUID
    var addedAt: Date
    var lastRefreshedAt: Date?
    var channelCount: Int

    init(playlist: Playlist) {
        self.id = playlist.id
        self.name = playlist.name
        self.kind = playlist.kind == .m3u ? .m3u : .xtream
        self.m3uURL = playlist.m3uURL
        self.host = playlist.host
        self.credentialID = playlist.credentialID
        self.addedAt = Date()
        self.lastRefreshedAt = nil
        self.channelCount = 0
    }

    static func == (lhs: LiveProvider, rhs: LiveProvider) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Live Group

/// A channel group/category within a provider.
struct LiveGroup: Identifiable, Codable, Sendable, Hashable {
    let id: String              // "\(providerID)|\(title)"
    let providerID: UUID
    let title: String
    var channelCount: Int

    static func == (lhs: LiveGroup, rhs: LiveGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - StreamResolution extensions

// Adds Codable + Sendable to the existing EPGModels.swift type.
extension StreamResolution: Codable, @unchecked Sendable {}

// MARK: - Stream Descriptor

/// A single playable stream endpoint for a channel.
/// One channel may have multiple descriptors (primary + fallbacks, different qualities).
struct StreamDescriptor: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let streamURL: URL
    let providerID: UUID
    var resolution: StreamResolution
    var tvgID: String?
    var tvgName: String?
    var tvgLogoURL: URL?
    var groupTitle: String?
    var archiveEnabled: Bool
    var archiveDays: Int

    init(id: String, streamURL: URL, providerID: UUID,
         resolution: StreamResolution = .unknown,
         tvgID: String? = nil, tvgName: String? = nil,
         tvgLogoURL: URL? = nil, groupTitle: String? = nil,
         archiveEnabled: Bool = false, archiveDays: Int = 0) {
        self.id = id
        self.streamURL = streamURL
        self.providerID = providerID
        self.resolution = resolution
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.tvgLogoURL = tvgLogoURL
        self.groupTitle = groupTitle
        self.archiveEnabled = archiveEnabled
        self.archiveDays = archiveDays
    }

    static func == (lhs: StreamDescriptor, rhs: StreamDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Catchup Capability

struct CatchupCapability: Codable, Sendable, Hashable {
    var isEnabled: Bool
    var daysAvailable: Int
    var type: CatchupType
    var templateURL: String?   // M3U catchup-source URL template

    enum CatchupType: String, Codable, Sendable {
        case `default`, append, shift, flussonic, xStreamCodes
    }
}

// MARK: - Live Channel

/// Unified live TV channel produced by any provider adapter.
/// This is the canonical data-layer model. The UI consumes it via `asChannel()`.
///
/// ID stability:
///   - M3U with tvg-id  → "<providerUUID>-m3u-tvg:<djb2(tvgID)>"
///   - M3U name-based   → "<providerUUID>-m3u:<djb2(name|group)>"
///   - Xtream           → "<providerUUID>-<stream_id>"  (matches legacy format exactly)
struct LiveChannel: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let providerID: UUID
    let providerKind: LiveProviderKind

    var name: String
    var logoURL: URL?
    var groupTitle: String?
    var streams: [StreamDescriptor]
    var catchup: CatchupCapability?

    // Provider-specific identifiers kept separate from the stable channel ID.
    var tvgID: String?
    var xtreamStreamID: Int?
    var xtreamCategoryID: String?
    var epgChannelID: String?
    var epgOffset: Int

    var primaryStream: StreamDescriptor? { streams.first }

    init(id: String, providerID: UUID, providerKind: LiveProviderKind,
         name: String, logoURL: URL? = nil, groupTitle: String? = nil,
         streams: [StreamDescriptor] = [], catchup: CatchupCapability? = nil,
         tvgID: String? = nil, xtreamStreamID: Int? = nil,
         xtreamCategoryID: String? = nil, epgChannelID: String? = nil,
         epgOffset: Int = 0) {
        self.id = id
        self.providerID = providerID
        self.providerKind = providerKind
        self.name = name
        self.logoURL = logoURL
        self.groupTitle = groupTitle
        self.streams = streams
        self.catchup = catchup
        self.tvgID = tvgID
        self.xtreamStreamID = xtreamStreamID
        self.xtreamCategoryID = xtreamCategoryID
        self.epgChannelID = epgChannelID
        self.epgOffset = epgOffset
    }

    /// Converts to the legacy Channel type expected by all existing UI code.
    func asChannel(playlistName: String = "") -> Channel {
        Channel(
            id: id,
            name: name,
            streamURL: primaryStream?.streamURL ?? URL(string: "about:blank")!,
            logoURL: logoURL ?? primaryStream?.tvgLogoURL,
            group: groupTitle,
            playlistID: providerID,
            playlistName: playlistName
        )
    }

    static func == (lhs: LiveChannel, rhs: LiveChannel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Channel Preferences

/// Per-channel user overlay. Provider refreshes never modify these.
struct ChannelPreferences: Codable, Sendable, Hashable {
    let channelID: String
    var customName: String?
    var isHidden: Bool
    var isFavorite: Bool
    var favoriteOrder: Int?     // lower = appears earlier in the Favourites list
    var sortOrder: Int?
    var manualEPGChannelID: String?
    var epgOffset: Int

    init(channelID: String) {
        self.channelID = channelID
        self.isHidden = false
        self.isFavorite = false
        self.epgOffset = 0
    }

    // Custom decoder so old data (without isFavorite/favoriteOrder) decodes gracefully.
    enum CodingKeys: String, CodingKey {
        case channelID, customName, isHidden, isFavorite, favoriteOrder
        case sortOrder, manualEPGChannelID, epgOffset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID            = try c.decode(String.self, forKey: .channelID)
        customName           = try c.decodeIfPresent(String.self, forKey: .customName)
        isHidden             = try c.decodeIfPresent(Bool.self,   forKey: .isHidden)    ?? false
        isFavorite           = try c.decodeIfPresent(Bool.self,   forKey: .isFavorite)  ?? false
        favoriteOrder        = try c.decodeIfPresent(Int.self,    forKey: .favoriteOrder)
        sortOrder            = try c.decodeIfPresent(Int.self,    forKey: .sortOrder)
        manualEPGChannelID   = try c.decodeIfPresent(String.self, forKey: .manualEPGChannelID)
        epgOffset            = try c.decodeIfPresent(Int.self,    forKey: .epgOffset)   ?? 0
    }

    static func == (lhs: ChannelPreferences, rhs: ChannelPreferences) -> Bool {
        lhs.channelID == rhs.channelID
    }
    func hash(into hasher: inout Hasher) { hasher.combine(channelID) }
}

// MARK: - Channel Sort Order

enum ChannelSortOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case providerOrder  = "Provider Order"
    case nameAZ         = "A → Z"
    case nameZA         = "Z → A"
    case channelNumber  = "Channel Number"
    case favoritesFirst = "Favourites First"
    case custom         = "Custom"

    var id: String { rawValue }
}

// MARK: - Custom Group

/// A user-created channel group that can span multiple providers.
struct CustomGroup: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var name: String
    var sortOrder: Int
    var channelIDs: [String]    // ordered list; order is preserved for .custom sort

    init(name: String) {
        self.id        = UUID().uuidString
        self.name      = name
        self.sortOrder = 0
        self.channelIDs = []
    }

    static func == (lhs: CustomGroup, rhs: CustomGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Group Preferences

/// Per-provider-group user overlay: hide, rename, custom sort position.
/// Group ID format: "\(providerUUID)|\(groupTitle)"
struct GroupPreferences: Codable, Sendable, Hashable {
    let groupID: String
    var isHidden: Bool
    var customName: String?
    var sortOrder: Int?

    init(groupID: String) {
        self.groupID  = groupID
        self.isHidden = false
    }

    static func == (lhs: GroupPreferences, rhs: GroupPreferences) -> Bool {
        lhs.groupID == rhs.groupID
    }
    func hash(into hasher: inout Hasher) { hasher.combine(groupID) }
}
