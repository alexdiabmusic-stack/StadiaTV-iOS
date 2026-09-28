import Foundation

nonisolated enum GolfCoverageKind: String, Codable, Sendable, Hashable {
    case fullTelecast
    case featuredGroup
    case featuredHole
    case audioStream
    case unknown
}

/// Broadcast/streaming metadata only — this app never attempts playback or
/// bypasses a subscription/paywall from this data (STEP 55).
nonisolated struct GolfCoverageWindow: Identifiable, Codable, Sendable, Hashable {
    var id: String
    let kind: GolfCoverageKind
    let streamTitle: String?
    let channelTitle: String?
    let roundNumber: Int?
    let startTime: Date?
    let endTime: Date?
    let liveStatusRaw: String?
}
