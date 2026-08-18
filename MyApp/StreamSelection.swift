import Foundation
import AVFoundation
import CoreMedia
import Combine

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

enum StreamRanker {
    static func ranked(
        streams: [ChannelStream],
        runtimeMetadata: [String: StreamRuntimeMetadata] = [:],
        failureRecords: [String: StreamFailureRecord] = [:],
        now: Date = Date()
    ) -> [RankedStreamCandidate] {
        let base = streams.enumerated().map { index, stream in
            makeCandidate(stream: stream,
                          index: index,
                          metadata: runtimeMetadata[stream.id],
                          failure: failureRecords[stream.id],
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
        now: Date
    ) -> RankedStreamCandidate {
        let quality = qualityLabel(for: stream, metadata: metadata)
        let codec = codecLabel(for: stream, metadata: metadata)
        let isBackup = stream.isBackupHint
        let isAlternate = stream.isAlternateHint || index > 0
        let isUnavailable = failure?.recentlyFailedUntil.map { $0 > now } ?? false
        let health: StreamHealth = isUnavailable ? .unavailable : ((failure?.failureCount ?? 0) >= 2 ? .unstable : .unknown)
        var score = stream.resolution.rawValue * 100
        if metadata?.hasVideoSize == true { score += 40 }
        if codec == "HEVC" { score += 8 }
        if codec == "H.264" { score += 5 }
        if isAlternate { score -= 8 }
        if isBackup { score -= 18 }
        if health == .unstable { score -= 80 }
        if health == .unavailable { score -= 500 }

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

    let canonicalChannel: CanonicalChannel?
    let fallbackChannel: Channel

    private static var sessionManualSelections: [String: String] = [:]
    private var attemptedAutoStreamIDs: Set<String> = []
    private let cooldown: TimeInterval = 90

    init(channel: Channel, canonicalChannel: CanonicalChannel? = nil) {
        self.fallbackChannel = channel
        self.canonicalChannel = canonicalChannel
        if let canonicalChannel,
           let streamID = Self.sessionManualSelections[canonicalChannel.id],
           canonicalChannel.allStreams.contains(where: { $0.id == streamID }) {
            mode = .manual(streamID)
            activeStream = canonicalChannel.allStreams.first { $0.id == streamID }
        } else if let canonicalChannel {
            selectBestAutoStream(for: canonicalChannel)
        }
    }

    var hasSelectableStreams: Bool {
        usableStreams.count > 1
    }

    var usableStreams: [ChannelStream] {
        canonicalChannel?.allStreams ?? []
    }

    var activeChannel: Channel {
        guard let canonicalChannel, let stream = activeStream else { return fallbackChannel }
        return canonicalChannel.channel(for: stream)
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
            attemptedAutoStreamIDs.removeAll()
            switchState = .switching
            selectBestAutoStream(for: canonicalChannel)
            switchState = .idle
        }
        logSelection(reason: "user_auto")
    }

    func selectManual(streamID: String) {
        guard let canonicalChannel,
              let stream = canonicalChannel.allStreams.first(where: { $0.id == streamID }) else { return }
        mode = .manual(streamID)
        Self.sessionManualSelections[canonicalChannel.id] = streamID
        switchState = .switching
        activeStream = stream
        switchState = .idle
        logSelection(reason: "user_manual")
    }

    func retryActiveStream() {
        guard let activeStream else { return }
        clearFailure(for: activeStream.id)
        switchState = .switching
        self.activeStream = activeStream
        switchState = .idle
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

    func updateRuntimeMetadata(_ metadata: StreamRuntimeMetadata, for streamID: String) {
        runtimeMetadata[streamID] = metadata
        if case .auto = mode, let canonicalChannel {
            autoSelectedStream = activeStream ?? StreamRanker.ranked(streams: canonicalChannel.allStreams,
                                                                    runtimeMetadata: runtimeMetadata,
                                                                    failureRecords: failureRecords).first?.stream
        }
    }

    private func failoverFromAuto(message: String) {
        guard let canonicalChannel else {
            switchState = .failed(message)
            return
        }
        let candidates = StreamRanker.ranked(streams: canonicalChannel.allStreams,
                                            runtimeMetadata: runtimeMetadata,
                                            failureRecords: failureRecords)
        if let next = candidates.first(where: { !attemptedAutoStreamIDs.contains($0.stream.id) && $0.health != .unavailable })?.stream {
            switchState = .switching
            activeStream = next
            autoSelectedStream = next
            switchState = .idle
            logSelection(reason: "auto_failover")
        } else {
            switchState = .failed(message)
        }
    }

    private func selectBestAutoStream(for canonicalChannel: CanonicalChannel) {
        let candidates = StreamRanker.ranked(streams: canonicalChannel.allStreams,
                                            runtimeMetadata: runtimeMetadata,
                                            failureRecords: failureRecords)
        activeStream = candidates.first?.stream ?? canonicalChannel.primaryStream ?? canonicalChannel.fallbackStreams.first
        autoSelectedStream = activeStream
        logSelection(reason: "auto_rank")
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
                playlistName: stream.playlistName)
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
    static func metadata(from playerItem: AVPlayerItem) async -> StreamRuntimeMetadata? {
        var metadata = StreamRuntimeMetadata()
        let size = playerItem.presentationSize
        if size.width > 0, size.height > 0 {
            metadata.width = Int(size.width.rounded())
            metadata.height = Int(size.height.rounded())
        }

        do {
            let tracks = try await playerItem.asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let naturalSize = try await track.load(.naturalSize)
                if naturalSize.width > 0, naturalSize.height > 0 {
                    metadata.width = Int(abs(naturalSize.width).rounded())
                    metadata.height = Int(abs(naturalSize.height).rounded())
                }
                let frameRate = try await track.load(.nominalFrameRate)
                if frameRate > 0 {
                    metadata.frameRate = Double(frameRate)
                }
                let bitrate = try await track.load(.estimatedDataRate)
                if bitrate > 0 {
                    metadata.bitrate = Double(bitrate)
                }
                let descriptions = try await track.load(.formatDescriptions)
                metadata.codec = descriptions.compactMap { codecName(from: $0) }.first
            }
        } catch {
            // Live streams often expose metadata late; keep any presentation size already observed.
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
