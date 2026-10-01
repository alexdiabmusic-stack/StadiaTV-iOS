import Foundation
import AVFoundation
import CoreMedia
import Combine
import os

struct StreamRuntimeMetadata: Equatable, Hashable {
    var width: Int?
    var height: Int?
    var codec: String?
    var frameRate: Double?
    var bitrate: Double?

    var hasVideoSize: Bool {
        (width ?? 0) > 0 && (height ?? 0) > 0
    }
}

enum StreamSelectionMode: Equatable, Hashable {
    case auto
    case manual(String)
}

enum StreamSwitchState: Equatable {
    case idle
    case switching
    case failed(String)
}

enum StreamHealth: String, Equatable {
    case unknown = "Unknown"
    case good = "Good"
    case unstable = "Unstable"
    case unavailable = "Unavailable"
}

struct RankedStreamCandidate: Identifiable, Hashable {
    let stream: ChannelStream
    let score: Int
    let health: StreamHealth
    let metadata: StreamRuntimeMetadata?
    let primaryLabel: String
    let detailLabel: String?
    let sortKey: Int

    var id: String { stream.id }
}

/// Ranking inputs that come from user settings rather than the stream itself.
enum StreamRankingSettings {
    /// Mirrors `UserPreferences.preferUHDStreams`; kept here so ranking stays a pure function.
    static var preferUHD = false
}

enum StreamRanker {
    /// Orders streams for Auto: the last stream that started successfully, then
    /// 1080p, 720p, 4K, SD, unknown (4K first when `preferUHD`), H.264 ahead of HEVC at
    /// equal resolution, backups last. Recently failed streams sink to the bottom.
    static func ranked(
        streams: [ChannelStream],
        runtimeMetadata: [String: StreamRuntimeMetadata] = [:],
        failureRecords: [String: StreamFailureRecord] = [:],
        health: [String: StreamHealthStore.Record] = [:],
        preferUHD: Bool = StreamRankingSettings.preferUHD,
        now: Date = Date()
    ) -> [RankedStreamCandidate] {
        let lastKnownGoodID = health
            .filter { entry in streams.contains { $0.id == entry.key } && entry.value.lastOutcomeWasSuccess }
            .max { ($0.value.lastSuccess ?? .distantPast) < ($1.value.lastSuccess ?? .distantPast) }?
            .key
        let base = streams.enumerated().map { index, stream in
            makeCandidate(stream: stream,
                          index: index,
                          metadata: runtimeMetadata[stream.id],
                          failure: failureRecords[stream.id],
                          healthRecord: health[stream.id],
                          isLastKnownGood: stream.id == lastKnownGoodID,
                          preferUHD: preferUHD,
                          now: now)
        }
        let duplicateCounts = Dictionary(grouping: base, by: { $0.primaryLabel }).mapValues(\.count)
        return base.map { candidate in
            guard (duplicateCounts[candidate.primaryLabel] ?? 0) > 1 else { return candidate }
            let suffix = candidate.detailLabel?.isEmpty == false ? candidate.detailLabel! : "Stream \(candidate.sortKey)"
            return RankedStreamCandidate(stream: candidate.stream,
                                         score: candidate.score,
                                         health: candidate.health,
                                         metadata: candidate.metadata,
                                         primaryLabel: candidate.primaryLabel,
                                         detailLabel: suffix,
                                         sortKey: candidate.sortKey)
        }
        .sorted {
            if $0.health == .unavailable && $1.health != .unavailable { return false }
            if $1.health == .unavailable && $0.health != .unavailable { return true }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.sortKey != $1.sortKey { return $0.sortKey > $1.sortKey }
            return $0.stream.originalName.localizedCaseInsensitiveCompare($1.stream.originalName) == .orderedAscending
        }
    }

    static func displayCandidates(
        streams: [ChannelStream],
        runtimeMetadata: [String: StreamRuntimeMetadata] = [:],
        failureRecords: [String: StreamFailureRecord] = [:],
        now: Date = Date()
    ) -> [RankedStreamCandidate] {
        ranked(streams: streams,
               runtimeMetadata: runtimeMetadata,
               failureRecords: failureRecords,
               now: now)
        .sorted {
            if $0.health == .unavailable && $1.health != .unavailable { return false }
            if $1.health == .unavailable && $0.health != .unavailable { return true }
            if $0.sortKey != $1.sortKey { return $0.sortKey > $1.sortKey }
            return $0.score > $1.score
        }
    }

    private static func makeCandidate(
        stream: ChannelStream,
        index: Int,
        metadata: StreamRuntimeMetadata?,
        failure: StreamFailureRecord?,
        healthRecord: StreamHealthStore.Record?,
        isLastKnownGood: Bool,
        preferUHD: Bool,
        now: Date
    ) -> RankedStreamCandidate {
        let quality = qualityLabel(for: stream, metadata: metadata)
        let codec = codecLabel(for: stream, metadata: metadata)
        let isBackup = stream.isBackupHint
        let isAlternate = stream.isAlternateHint || index > 0
        let isUnavailable = failure?.recentlyFailedUntil.map { $0 > now } ?? false
        let health: StreamHealth = isUnavailable ? .unavailable : ((failure?.failureCount ?? 0) >= 2 ? .unstable : .unknown)
        var score = resolutionTierScore(for: stream, metadata: metadata, preferUHD: preferUHD)
        if metadata?.hasVideoSize == true { score += 20 }
        if codec == "H.264" { score += 8 }
        if codec == "HEVC" { score += preferUHD ? 6 : 2 }
        if isAlternate { score -= 8 }
        if isBackup { score -= 1_000 }
        if health == .unstable { score -= 80 }
        if health == .unavailable { score -= 5_000 }
        if isLastKnownGood, health != .unavailable { score += 2_000 }
        // A stream whose last outcome was a failure (in an earlier session) drops within its tier.
        if let healthRecord, !healthRecord.lastOutcomeWasSuccess,
           let lastFailure = healthRecord.lastFailure, now.timeIntervalSince(lastFailure) < 86_400 {
            score -= 60
        }

        var details: [String] = []
        if let codec { details.append(codec) }
        if isBackup { details.append("Backup") }
        else if isAlternate { details.append("Alternate") }
        if let fps = metadata?.frameRate, fps >= 59.5 { details.append("60 fps") }

        return RankedStreamCandidate(stream: stream,
                                     score: score,
                                     health: health,
                                     metadata: metadata,
                                     primaryLabel: quality,
                                     detailLabel: details.isEmpty ? nil : details.joined(separator: " • "),
                                     sortKey: sortValue(for: stream, metadata: metadata))
    }

    /// FHD > HD > UHD > SD > unknown by default; UHD first when the user prefers 4K.
    /// 4K mirrors are usually the slowest to start and often HEVC, so they aren't the default.
    private static func resolutionTierScore(for stream: ChannelStream, metadata: StreamRuntimeMetadata?, preferUHD: Bool) -> Int {
        let resolution: StreamResolution
        if let height = metadata?.height, height > 0 {
            if height >= 2160 { resolution = .uhd }
            else if height >= 1080 { resolution = .fhd }
            else if height >= 720 { resolution = .hd }
            else { resolution = .sd }
        } else {
            resolution = stream.resolution
        }
        switch resolution {
        case .uhd: return preferUHD ? 600 : 300
        case .fhd: return 500
        case .hd: return 400
        case .sd: return 200
        case .unknown: return 100
        }
    }

    static func qualityLabel(for stream: ChannelStream, metadata: StreamRuntimeMetadata?) -> String {
        if let height = metadata?.height, height > 0 {
            if height >= 2160 { return "4K" }
            if height >= 1440 { return "1440p" }
            if height >= 1080 { return "1080p" }
            if height >= 720 { return "720p" }
            return "SD"
        }
        switch stream.resolution {
        case .uhd: return "4K"
        case .fhd: return "1080p"
        case .hd: return stream.originalName.contains("720") ? "720p" : "HD"
        case .sd: return "SD"
        case .unknown: return stream.isBackupHint ? "Backup" : "Stream"
        }
    }

    static func codecLabel(for stream: ChannelStream, metadata: StreamRuntimeMetadata?) -> String? {
        if let codec = metadata?.codec, !codec.isEmpty { return codec }
        let name = stream.originalName.uppercased()
        if name.contains("HEVC") || name.contains("H265") || name.contains("H.265") || name.contains("X265") { return "HEVC" }
        if name.contains("H264") || name.contains("H.264") || name.contains("AVC") || name.contains("X264") { return "H.264" }
        if name.contains("AV1") { return "AV1" }
        return nil
    }

    private static func sortValue(for stream: ChannelStream, metadata: StreamRuntimeMetadata?) -> Int {
        let height = metadata?.height ?? 0
        if height >= 2160 || stream.resolution == .uhd { return 600 }
        if height >= 1440 { return 500 }
        if height >= 1080 || stream.resolution == .fhd { return 400 }
        if height >= 720 || stream.resolution == .hd { return 300 }
        if stream.resolution == .sd { return 200 }
        return stream.isBackupHint ? 50 : 100
    }
}

struct StreamFailureRecord: Equatable, Hashable {
    var failureCount: Int = 0
    var recentlyFailedUntil: Date?
    var lastFailure: Date?
}

@MainActor
final class StreamSelectionState: ObservableObject {
    @Published private(set) var mode: StreamSelectionMode = .auto
    @Published private(set) var activeStream: ChannelStream?
    @Published private(set) var autoSelectedStream: ChannelStream?
    @Published private(set) var switchState: StreamSwitchState = .idle
    @Published private(set) var runtimeMetadata: [String: StreamRuntimeMetadata] = [:]
    @Published private(set) var failureRecords: [String: StreamFailureRecord] = [:]
    /// Incremented whenever the player should (re)load `activeChannel`: a channel reset,
    /// a source change, a failover, or a retry of the same source.
    @Published private(set) var loadToken = 0

    private(set) var canonicalChannel: CanonicalChannel?
    private(set) var fallbackChannel: Channel
    /// Candidates in their given order when there is no canonical channel
    /// (a plain channel, or the ranked sources of a match).
    private var rawStreams: [ChannelStream] = []
    private var rawChannels: [String: Channel] = [:]

    private static var sessionManualSelections: [String: String] = [:]
    private var attemptedAutoStreamIDs: Set<String> = []
    private let cooldown: TimeInterval = 90
    /// Maximum number of match sources offered for failover and cycling.
    static let maxRawCandidates = 8

    /// - Parameters:
    ///   - candidates: alternative channels for the same content, used when there is no
    ///     canonical channel (e.g. a match's ranked sources). `channel` is always tried first.
    init(channel: Channel, canonicalChannel: CanonicalChannel? = nil, candidates: [Channel] = []) {
        self.fallbackChannel = channel
        configure(channel: channel, canonicalChannel: canonicalChannel, candidates: candidates, preferredStreamID: nil)
    }

    /// Switches to a different channel, keeping per-stream failure history.
    /// - Parameter preferredStreamID: start on this stream if it belongs to the channel
    ///   (e.g. the exact mirror the user picked from a list); Auto can still fail over.
    func reset(to channel: Channel, canonicalChannel: CanonicalChannel?, candidates: [Channel] = [], preferredStreamID: String? = nil) {
        configure(channel: channel, canonicalChannel: canonicalChannel, candidates: candidates, preferredStreamID: preferredStreamID)
        loadToken &+= 1
    }

    private func configure(channel: Channel, canonicalChannel: CanonicalChannel?, candidates: [Channel], preferredStreamID: String?) {
        fallbackChannel = channel
        self.canonicalChannel = canonicalChannel
        rawStreams = []
        rawChannels = [:]
        if canonicalChannel == nil {
            var seen = Set<String>()
            let ordered = ([channel] + candidates).filter { seen.insert($0.id).inserted }.prefix(Self.maxRawCandidates)
            rawStreams = ordered.map(Self.stream(from:))
            rawChannels = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        }
        mode = .auto
        attemptedAutoStreamIDs.removeAll()
        switchState = .idle

        if let canonicalChannel,
           let streamID = Self.sessionManualSelections[canonicalChannel.id],
           let stream = canonicalChannel.allStreams.first(where: { $0.id == streamID }) {
            mode = .manual(streamID)
            activeStream = stream
            autoSelectedStream = nil
        } else if let preferredStreamID, let stream = usableStreams.first(where: { $0.id == preferredStreamID }) {
            activeStream = stream
            autoSelectedStream = stream
        } else {
            selectBestAutoStream()
        }
    }

    var hasSelectableStreams: Bool {
        usableStreams.count > 1
    }

    var usableStreams: [ChannelStream] {
        canonicalChannel?.allStreams ?? rawStreams
    }

    var activeChannel: Channel {
        guard let stream = activeStream else { return fallbackChannel }
        if let canonicalChannel { return canonicalChannel.channel(for: stream) }
        return rawChannels[stream.id] ?? fallbackChannel
    }

    var displayCandidates: [RankedStreamCandidate] {
        StreamRanker.displayCandidates(streams: usableStreams,
                                       runtimeMetadata: runtimeMetadata,
                                       failureRecords: failureRecords)
    }

    var autoSummary: String {
        summary(for: autoSelectedStream ?? activeStream, fallback: "Recommended")
    }

    var currentSummary: String {
        switch mode {
        case .auto:
            return "Auto — \(autoSummary)"
        case .manual:
            return summary(for: activeStream, fallback: "Manual")
        }
    }

    private func summary(for stream: ChannelStream?, fallback: String) -> String {
        guard let stream else { return fallback }
        let candidate = StreamRanker.ranked(streams: [stream], runtimeMetadata: runtimeMetadata, failureRecords: failureRecords).first
        let label = [candidate?.primaryLabel, candidate?.detailLabel].compactMap { $0 }.joined(separator: " • ")
        return label.isEmpty ? fallback : label
    }

    func selectAuto() {
        mode = .auto
        if let canonicalChannel {
            Self.sessionManualSelections[canonicalChannel.id] = nil
        }
        attemptedAutoStreamIDs.removeAll()
        switchState = .idle
        selectBestAutoStream()
        loadToken &+= 1
        logSelection(reason: "user_auto")
    }

    func selectManual(streamID: String) {
        guard let stream = usableStreams.first(where: { $0.id == streamID }) else { return }
        mode = .manual(streamID)
        if let canonicalChannel {
            Self.sessionManualSelections[canonicalChannel.id] = streamID
        }
        switchState = .idle
        activeStream = stream
        loadToken &+= 1
        logSelection(reason: "user_manual")
    }

    /// Reloads the current source after clearing its failure record.
    func retryActiveStream() {
        if let activeStream { clearFailure(for: activeStream.id) }
        attemptedAutoStreamIDs.removeAll()
        switchState = .idle
        loadToken &+= 1
    }

    func handlePlaybackFailure(message: String = "Couldn't play this stream.") {
        guard let failed = activeStream else {
            switchState = .failed(message)
            return
        }
        recordFailure(for: failed.id)
        switch mode {
        case .auto:
            attemptedAutoStreamIDs.insert(failed.id)
            failoverFromAuto(message: message)
        case .manual:
            switchState = .failed("Selected stream unavailable.")
        }
    }

    /// Clears the cooldown on a stream that just started, so it isn't shown as unavailable.
    func recordPlaybackSuccess(streamID: String) {
        guard var record = failureRecords[streamID] else { return }
        record.recentlyFailedUntil = nil
        failureRecords[streamID] = record
    }

    func updateRuntimeMetadata(_ metadata: StreamRuntimeMetadata, for streamID: String) {
        runtimeMetadata[streamID] = metadata
        if case .auto = mode {
            autoSelectedStream = activeStream ?? autoOrderedStreams().first
        }
    }

    /// Probes the next two Auto candidates in parallel and marks dead ones unavailable,
    /// so a failover skips them instead of waiting out the start-up watchdog.
    ///
    /// Skipped on a single-connection (or unknown-limit, or already-at-limit) account: opening
    /// a second connection to probe a candidate while the main stream is live is exactly what
    /// kicks the viewer on those accounts. See MatchLinker/PROMPTS.md, Prompt 6.
    func preflightAlternates() async {
        guard let active = activeStream else { return }
        let activePlaylistID = channel(for: active).playlistID
        guard !XtreamAccountStatusStore.shared.blocksAdditionalConnection(forPlaylistID: activePlaylistID) else { return }
        let activeID = active.id
        let targets = autoOrderedStreams()
            .filter { $0.id != activeID && !isUnavailable($0.id) }
            .prefix(2)
            .map { stream -> (id: String, url: URL, headers: [String: String]?) in
                let channel = channel(for: stream)
                return (stream.id, channel.streamURL, channel.httpHeaders)
            }
        guard !targets.isEmpty else { return }
        let results = await withTaskGroup(of: (String, StreamPreflight.Result).self) { group in
            for target in targets {
                group.addTask { (target.id, await StreamPreflight.probe(url: target.url, headers: target.headers)) }
            }
            var collected: [(String, StreamPreflight.Result)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (streamID, result) in results where result == .dead {
            PlaybackMetrics.logger.info("Preflight: candidate \(streamID, privacy: .private) unreachable; skipping it for failover")
            recordFailure(for: streamID)
        }
    }

    private func failoverFromAuto(message: String) {
        if let next = autoOrderedStreams().first(where: { !attemptedAutoStreamIDs.contains($0.id) && !isUnavailable($0.id) }) {
            switchState = .idle
            activeStream = next
            autoSelectedStream = next
            loadToken &+= 1
            logSelection(reason: "auto_failover")
        } else {
            switchState = .failed(message)
        }
    }

    private func selectBestAutoStream() {
        activeStream = autoOrderedStreams().first
            ?? canonicalChannel?.primaryStream
            ?? canonicalChannel?.fallbackStreams.first
            ?? rawStreams.first
        autoSelectedStream = activeStream
        logSelection(reason: "auto_rank")
    }

    /// Canonical channels are ranked; raw candidates (match sources) keep their given
    /// order because it already reflects how well each source matches the event.
    private func autoOrderedStreams() -> [ChannelStream] {
        if canonicalChannel != nil {
            let streams = usableStreams
            return StreamRanker.ranked(streams: streams,
                                       runtimeMetadata: runtimeMetadata,
                                       failureRecords: failureRecords,
                                       health: StreamHealthStore.shared.records(for: streams.map(\.id)))
                .map(\.stream)
        }
        return rawStreams.filter { !isUnavailable($0.id) } + rawStreams.filter { isUnavailable($0.id) }
    }

    private func channel(for stream: ChannelStream) -> Channel {
        if let canonicalChannel { return canonicalChannel.channel(for: stream) }
        return rawChannels[stream.id] ?? fallbackChannel
    }

    private func isUnavailable(_ streamID: String, now: Date = Date()) -> Bool {
        failureRecords[streamID]?.recentlyFailedUntil.map { $0 > now } ?? false
    }

    private func recordFailure(for streamID: String) {
        var record = failureRecords[streamID] ?? StreamFailureRecord()
        record.failureCount += 1
        record.lastFailure = Date()
        record.recentlyFailedUntil = Date().addingTimeInterval(cooldown)
        failureRecords[streamID] = record
    }

    private func clearFailure(for streamID: String) {
        failureRecords[streamID] = nil
    }

    private static func stream(from channel: Channel) -> ChannelStream {
        var stream = ChannelStream(
            id: channel.id,
            providerChannelId: channel.id,
            originalName: channel.name,
            normalizedName: channel.name.lowercased(),
            streamURL: channel.streamURL,
            tvgId: channel.tvgId,
            tvgName: channel.name,
            tvgLogoURL: channel.logoURL,
            groupTitle: channel.group,
            resolution: StreamResolution.detect(from: channel.name),
            playlistID: channel.playlistID,
            playlistName: channel.playlistName
        )
        stream.httpHeaders = channel.httpHeaders
        return stream
    }

    private func logSelection(reason: String) {
        #if DEBUG
        let canonicalID = canonicalChannel?.id ?? "raw-channel"
        let streamID = activeStream?.id ?? fallbackChannel.id
        let metadata = activeStream.flatMap { runtimeMetadata[$0.id] }
        print("StreamSelection canonical=\(canonicalID) candidates=\(usableStreams.count) active=\(streamID) mode=\(mode) reason=\(reason) quality=\(activeStream.map { StreamRanker.qualityLabel(for: $0, metadata: metadata) } ?? "unknown") codec=\(activeStream.flatMap { StreamRanker.codecLabel(for: $0, metadata: metadata) } ?? "unknown")")
        #endif
    }
}

extension CanonicalChannel {
    func channel(for stream: ChannelStream) -> Channel {
        Channel(id: stream.providerChannelId,
                name: name,
                streamURL: stream.streamURL,
                logoURL: effectiveLogoURL ?? stream.tvgLogoURL,
                group: categoryId,
                playlistID: stream.playlistID,
                playlistName: stream.playlistName,
                httpHeaders: stream.httpHeaders)
    }
}

extension ChannelStream {
    var isBackupHint: Bool {
        let n = originalName.uppercased()
        return n.contains("BACKUP") || n.range(of: #"\bBK\b"#, options: .regularExpression) != nil || n.contains("BCKP")
    }

    var isAlternateHint: Bool {
        let n = originalName.uppercased()
        return n.contains(" ALT") || n.contains("ALTERNATE") || n.contains("VIP")
    }
}

enum StreamMetadataReader {
    /// Reads resolution, codec, frame rate and bitrate for the stream that is actually playing.
    ///
    /// HLS assets never expose tracks on the `AVURLAsset`; they only appear on
    /// `AVPlayerItem.tracks` once variants are loaded, so read from there. Bitrate comes
    /// from the access log because HLS asset tracks don't report `estimatedDataRate`.
    static func metadata(from playerItem: AVPlayerItem) async -> StreamRuntimeMetadata? {
        var metadata = StreamRuntimeMetadata()
        let size = playerItem.presentationSize
        if size.width > 0, size.height > 0 {
            metadata.width = Int(size.width.rounded())
            metadata.height = Int(size.height.rounded())
        }

        let videoTrack = playerItem.tracks.first { track in
            track.isEnabled && track.assetTrack?.mediaType == .video
        }
        if let videoTrack {
            if videoTrack.currentVideoFrameRate > 0 {
                metadata.frameRate = Double(videoTrack.currentVideoFrameRate)
            }
            if let assetTrack = videoTrack.assetTrack {
                do {
                    if !metadata.hasVideoSize {
                        let naturalSize = try await assetTrack.load(.naturalSize)
                        if naturalSize.width > 0, naturalSize.height > 0 {
                            metadata.width = Int(abs(naturalSize.width).rounded())
                            metadata.height = Int(abs(naturalSize.height).rounded())
                        }
                    }
                    if metadata.frameRate == nil {
                        let frameRate = try await assetTrack.load(.nominalFrameRate)
                        if frameRate > 0 { metadata.frameRate = Double(frameRate) }
                    }
                    let descriptions = try await assetTrack.load(.formatDescriptions)
                    metadata.codec = descriptions.compactMap { codecName(from: $0) }.first
                } catch {
                    // Live streams often expose metadata late; keep whatever was already observed.
                }
            }
        }

        if let event = playerItem.accessLog()?.events.last {
            if event.indicatedBitrate > 0 {
                metadata.bitrate = event.indicatedBitrate
            } else if event.observedBitrate > 0 {
                metadata.bitrate = event.observedBitrate
            }
        }

        return metadata.hasVideoSize || metadata.codec != nil || metadata.frameRate != nil || metadata.bitrate != nil ? metadata : nil
    }

    private static func codecName(from description: CMFormatDescription) -> String? {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xff),
            UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff),
            UInt8(subtype & 0xff)
        ]
        let code = String(bytes: bytes, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch code {
        case "avc1", "h264": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01": return "AV1"
        case "mp4v": return "MPEG-4"
        default: return code?.isEmpty == false ? code?.uppercased() : nil
        }
    }
}
