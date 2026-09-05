import Foundation

// MARK: - Canonical Channel

/// A deduplicated, normalized channel that may map to multiple raw IPTV streams.
nonisolated struct CanonicalChannel: Identifiable, Hashable {
    let id: String              // key from curated JSON, e.g. "ca-cbc-toronto-toronto"
    let name: String
    let categoryId: String
    let country: String
    let languages: [String]
    let market: String?
    let network: String?
    let priority: Int
    let isOptional: Bool
    let tier: String            // "core", "expanded", "optional"
    var logoURL: URL?
    var primaryStream: ChannelStream?
    var fallbackStreams: [ChannelStream]
    var epgChannelId: String?   // matched XMLTV channel id
    var epgSourceId: String?
    var matchMethod: EPGMatchMethod?
    // Identity enrichment from IPTV-org + confidence tracking
    var iptvOrgChannelId: String? = nil
    var resolvedLogo: ResolvedChannelLogo? = nil
    var identityConfidence: Double = 1.0
    var identityConflicts: [IdentityConflict] = []

    /// Best available logo URL: resolved logo > provider logo
    var effectiveLogoURL: URL? { resolvedLogo?.url ?? logoURL }

    /// True if any stream for this channel has archive/catch-up enabled.
    var hasCatchup: Bool { allStreams.contains { $0.archiveEnabled } }

    /// Maximum catch-up retention days across all streams. 0 if unknown.
    var catchupDays: Int { allStreams.map(\.archiveDuration).max() ?? 0 }

    var allStreams: [ChannelStream] {
        var result: [ChannelStream] = []
        if let p = primaryStream { result.append(p) }
        result.append(contentsOf: fallbackStreams)
        return result
    }

    var playableChannel: Channel? {
        guard let stream = primaryStream ?? fallbackStreams.first else { return nil }
        return Channel(
            id: stream.providerChannelId,
            name: name,
            streamURL: stream.streamURL,
            logoURL: logoURL ?? stream.tvgLogoURL,
            group: categoryId,
            playlistID: stream.playlistID,
            playlistName: stream.playlistName
        )
    }

    static func == (lhs: CanonicalChannel, rhs: CanonicalChannel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Stream pre-normalization metadata

/// Metadata extracted from the raw channel name before normalization strips it.
/// Slot numbers, event dates and backup markers are removed by the normalizer;
/// they must be captured here to remain available for identity matching.
nonisolated struct StreamMetadata: Equatable, Sendable {
    /// Slot index in a numbered event feed, e.g. 1 from "PEACOCK 01:", 7 from "TSN+ 7:".
    var slotNumber: Int?
    /// Raw label before the slot colon, e.g. "PEACOCK 01" or "STAN EVENT 3".
    var slotLabel: String?
    /// Date-like string found in the channel name, e.g. "2025-09-06" or "2025".
    var eventDate: String?
    /// True when the name contains [BACKUP] or [BK].
    var isBackup: Bool
    /// Explicit language code from a bracket tag, e.g. "ESP", "FRA".
    var languageHint: String?
    /// Text content from a long bracket event-description suffix before it was stripped.
    var eventDescription: String?

    static let empty = StreamMetadata(
        slotNumber: nil, slotLabel: nil, eventDate: nil,
        isBackup: false, languageHint: nil, eventDescription: nil
    )
}

// MARK: - Channel Stream

nonisolated struct ChannelStream: Identifiable, Hashable {
    let id: String
    let providerChannelId: String
    let originalName: String
    let normalizedName: String
    let streamURL: URL
    let tvgId: String?
    let tvgName: String?
    let tvgLogoURL: URL?
    let groupTitle: String?
    let resolution: StreamResolution
    let playlistID: UUID
    let playlistName: String
    // Provider metadata preserved for identity matching and future catch-up
    var streamId: Int? = nil
    var providerCategoryId: String? = nil
    var archiveEnabled: Bool = false
    var archiveDuration: Int = 0
    var countryHint: String? = nil
    /// Pre-normalization metadata extracted before display-name cleanup.
    var streamMetadata: StreamMetadata = .empty

    static func == (lhs: ChannelStream, rhs: ChannelStream) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

nonisolated enum StreamResolution: Int, Comparable, CaseIterable {
    case uhd = 4
    case fhd = 3
    case hd = 2
    case sd = 1
    case unknown = 0

    static func < (lhs: StreamResolution, rhs: StreamResolution) -> Bool { lhs.rawValue < rhs.rawValue }

    nonisolated static func detect(from name: String) -> StreamResolution {
        let n = name.uppercased()
        if n.contains("4K") || n.contains("UHD") || n.contains("2160") { return .uhd }
        if n.contains("FHD") || n.contains("1080") || n.contains("FULL HD") { return .fhd }
        if n.range(of: #"\bHD\b"#, options: .regularExpression) != nil || n.contains("720") { return .hd }
        if n.range(of: #"\bSD\b"#, options: .regularExpression) != nil { return .sd }
        return .unknown
    }
}

// MARK: - EPG Channel

nonisolated struct EPGChannel: Identifiable, Hashable {
    let id: String          // XMLTV channel id
    let displayNames: [String]
    let iconURL: URL?
    let sourceId: String

    nonisolated var primaryName: String { displayNames.first ?? id }

    static func == (lhs: EPGChannel, rhs: EPGChannel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - EPG Programme

nonisolated struct EPGProgramme: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let epgChannelId: String
    var canonicalChannelId: String?
    let title: String
    let subtitle: String?
    let description: String?
    let categories: [String]
    let start: Date
    let end: Date
    let imageURL: URL?
    let season: Int?
    let episode: Int?
    let rating: String?
    let sourceId: String
    let sourcePriority: Int
    let endTimeIsInferred: Bool

    nonisolated var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    nonisolated var isValid: Bool { start < end && duration > 60 }

    func isOnNow(at date: Date = Date()) -> Bool { start <= date && date < end }
    func isPast(at date: Date = Date()) -> Bool { end < date }
    func isFuture(at date: Date = Date()) -> Bool { start > date }

    func minutesRemaining(from date: Date = Date()) -> Int {
        max(0, Int(end.timeIntervalSince(date) / 60))
    }

    func progress(at date: Date = Date()) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }

    static func == (lhs: EPGProgramme, rhs: EPGProgramme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Returns a copy with start/end shifted by the given number of minutes.
    /// Applied non-destructively in the UI to correct EPG timing offsets.
    func shifted(by minutes: Int) -> EPGProgramme {
        guard minutes != 0 else { return self }
        let delta = TimeInterval(minutes * 60)
        return EPGProgramme(
            id: id, epgChannelId: epgChannelId, canonicalChannelId: canonicalChannelId,
            title: title, subtitle: subtitle, description: description,
            categories: categories,
            start: start.addingTimeInterval(delta), end: end.addingTimeInterval(delta),
            imageURL: imageURL, season: season, episode: episode, rating: rating,
            sourceId: sourceId, sourcePriority: sourcePriority,
            endTimeIsInferred: endTimeIsInferred
        )
    }
}

// MARK: - Match metadata

nonisolated enum EPGMatchMethod: String, Codable {
    // Provider → canonical identity matching
    case exactTvgId
    case exactAlias
    case networkMarket
    case normalizedExact
    case fuzzy
    case manualOverride
    // Extended provider/IPTV-org matching
    case providerEpgExact
    case providerEpgCaseInsensitive
    case iptvOrgExactId
    case iptvOrgCaseInsensitiveId
    case iptvOrgAltName
    case replacementChain
    case unmatched
    // Unknown future cases decode gracefully
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EPGMatchMethod(rawValue: raw) ?? .normalizedExact
    }
}

nonisolated struct EPGChannelMapping: Codable, Hashable {
    let canonicalChannelId: String
    let xmltvChannelId: String
    let sourceId: String
    let matchMethod: EPGMatchMethod
    let confidence: Double
    let isManualOverride: Bool
}

// MARK: - Guide category

nonisolated struct GuideCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let sort: Int
    let isVirtual: Bool
    var isEnabled: Bool

    static func == (lhs: GuideCategory, rhs: GuideCategory) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Programme coverage

/// Temporal extent of a channel's programme data in the live index.
/// Rebuilt on every `finalizeProgrammeIndex` call; O(1) lookup from `EPGRepository.coverage(for:)`.
nonisolated struct ProgrammeCoverage: Sendable {
    let channelId: String
    let earliestStart: Date
    let latestEnd: Date
    let programmeCount: Int

    var spanHours: Double { latestEnd.timeIntervalSince(earliestStart) / 3600 }

    func covers(_ date: Date) -> Bool { date >= earliestStart && date <= latestEnd }

    func overlaps(start: Date, end: Date) -> Bool { start < latestEnd && end > earliestStart }
}

// MARK: - Programme-event join

/// A programme that is likely covering a specific sports event, with evidence scores.
/// Returned by `EPGRepository.programmesNear(start:duration:titleHints:broadcastNetworks:)`.
nonisolated struct ProgrammeEventJoin: Sendable {
    let programme: EPGProgramme
    let canonicalChannelId: String
    /// Jaccard token similarity between programme title and any of the supplied event title hints (0–1).
    let titleSimilarity: Double
    /// Overlap between the programme and the nominal event window (before pre/post-show padding).
    let timeOverlap: TimeInterval
    /// True when the channel's curated network name is in the caller-supplied broadcast-network list.
    let networkMatches: Bool

    /// Composite relevance score. Higher = more likely to carry this event.
    var score: Double {
        let titleWeight  = titleSimilarity * 0.55
        let overlapScore = min(timeOverlap / (2 * 3600), 1.0) * 0.30
        let networkBonus = networkMatches ? 0.15 : 0.0
        return titleWeight + overlapScore + networkBonus
    }
}

// MARK: - Refresh state

nonisolated enum EPGRefreshState: Equatable {
    case idle
    case refreshing
    case failed(String)
}

nonisolated enum LiveTVImportState: Equatable {
    case idle
    case loadingPlaylist
    case filtering
    case matching
    case deduplicating
    case resolvingLogos
    case loadingEPG
    case ready
    case failed(String)
    case cancelled
}

nonisolated struct LiveTVImportProgress: Equatable {
    var state: LiveTVImportState = .idle
    var rawStreams: Int = 0
    var filteredStreams: Int = 0
    var matchedStreams: Int = 0
    var canonicalChannels: Int = 0
    var epgChannels: Int = 0
    var programmesRetained: Int = 0
}

nonisolated struct LiveTVImportDiagnostics: Equatable {
    var playlistDecodeDuration: TimeInterval = 0
    var prefilterDuration: TimeInterval = 0
    var canonicalMatchDuration: TimeInterval = 0
    var dedupeDuration: TimeInterval = 0
    var logoResolutionDuration: TimeInterval = 0
    var epgDownloadDuration: TimeInterval = 0
    var epgChannelParseDuration: TimeInterval = 0
    var epgProgrammeParseDuration: TimeInterval = 0
    var exactMatches: Int = 0
    var normalizedMatches: Int = 0
    var iptvOrgMatches: Int = 0
    var fuzzyMatches: Int = 0
    var unmatched: Int = 0
}
