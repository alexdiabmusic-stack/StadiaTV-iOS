import Foundation

/// Maps `Coverage`. Metadata only — no playback/stream URLs are surfaced or
/// used (STEP 55).
nonisolated enum PGACoverageMapper {
    // Built once; the ISO fallback runs for every coverage window. Never mutated, so sharing is safe.
    private nonisolated(unsafe) static let isoDateFormatter = ISO8601DateFormatter()

    static func windows(_ value: PGAValue) -> [GolfCoverageWindow] {
        value["coverageType"].array.compactMap(window)
    }

    private static func window(_ value: PGAValue) -> GolfCoverageWindow? {
        let typeName = value["__typename"].string ?? ""
        let kind: GolfCoverageKind
        switch typeName {
        case "BroadcastFullTelecast": kind = .fullTelecast
        case "BroadcastFeaturedGroup": kind = .featuredGroup
        case "BroadcastFeaturedHole": kind = .featuredHole
        case "BroadcastAudioStream": kind = .audioStream
        default: kind = .unknown
        }
        guard let id = value["id"].string else { return nil }
        return GolfCoverageWindow(
            id: id,
            kind: kind,
            streamTitle: value["streamTitle"].string,
            channelTitle: value["channelTitle"].string,
            roundNumber: value["roundNumber"].int,
            startTime: PGAMappingSupport.epochMillis(value["startTime"]) ?? isoDateFormatter.date(from: value["startTime"].string ?? ""),
            endTime: PGAMappingSupport.epochMillis(value["endTime"]) ?? isoDateFormatter.date(from: value["endTime"].string ?? ""),
            liveStatusRaw: value["liveStatus"].string
        )
    }
}
