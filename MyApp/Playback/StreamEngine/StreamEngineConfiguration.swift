import Foundation

/// Every threshold the engine works with, chosen per buffer profile.
///
/// "Buffered" below always means programme seconds held ahead of what the viewer is watching:
/// the engine's unpublished reserve plus the short lead already handed to AVPlayer. Deeper
/// buffers survive longer outages and sit further behind live; the profile is that trade-off.
nonisolated struct StreamEngineConfiguration: Equatable, Sendable {
    enum Profile: String, Equatable, Sendable {
        /// Closest to live; rides out short delivery pauses.
        case fast
        /// About 20 s of reserve: covers the 6–10 s server pauses and most reconnects. Default.
        case balanced
        /// Up to a minute of reserve, slowing playback on weak lines rather than freezing.
        case maximum
    }

    var profile: Profile

    // Buffer targets, in seconds ahead of the playhead.
    var targetBuffer: Double
    var lowBuffer: Double
    /// Above this the engine plays slightly fast to shed latency.
    var highBuffer: Double
    /// Seconds published to AVPlayer ahead of its playhead; the rest stays in the engine's reserve.
    var lead: Double
    /// After running dry, hold the picture until this much has been rebuilt: one deliberate
    /// pause instead of a string of micro-freezes.
    var rebufferGoal: Double

    // Playback pace (pitch-corrected).
    /// Below the low mark on a healthy line.
    var buildRate: Double
    /// Between the low mark and the target.
    var trickleRate: Double
    /// Lowest rate on a line that can't keep up, or while the reserve covers an outage.
    var slowLineFloor: Double
    /// Above the high mark.
    var shedRate: Double

    // Detection and recovery.
    /// A silent connection is replaced after somewhere between these, depending on how much reserve is left.
    var stallTimeoutMinimum: Double = 4
    var stallTimeoutMaximum: Double = 12
    /// Keep this much buffer in hand when deciding how long to wait out a silent connection.
    var stallSafetyMargin: Double = 6
    /// Connected but no programme at all: the channel is dead at the provider.
    var deadChannelTimeout: Double = 14
    /// No first picture on a route within this long counts as a failed attempt.
    var startupTimeout: Double = 10
    /// Seconds of visible freeze, with the provider still silent, before the source is reported failed.
    var starvedFailover: Double
    /// No programme for this long switches reconnects to the 15/30/60 s stepped schedule.
    var steppedBackoffAfter: Double = 60
    /// Ceiling on connection attempts per minute, so a broken provider is never hammered.
    var maximumConnectionsPerMinute = 15

    // Storage.
    var maximumReserveBytes: Int
    var backBufferSeconds: Double
    var segmenter = HLSSegmenter.Configuration()

    static func profile(_ profile: Profile) -> StreamEngineConfiguration {
        switch profile {
        case .fast:
            return StreamEngineConfiguration(
                profile: .fast, targetBuffer: 8, lowBuffer: 4, highBuffer: 16, lead: 5, rebufferGoal: 1.5,
                buildRate: 0.99, trickleRate: 0.995, slowLineFloor: 0.97, shedRate: 1.01,
                starvedFailover: 15, maximumReserveBytes: 32 * 1024 * 1024, backBufferSeconds: 20)
        case .balanced:
            return StreamEngineConfiguration(
                profile: .balanced, targetBuffer: 20, lowBuffer: 8, highBuffer: 40, lead: 6, rebufferGoal: 3,
                buildRate: 0.98, trickleRate: 0.992, slowLineFloor: 0.93, shedRate: 1.01,
                starvedFailover: 25, maximumReserveBytes: 72 * 1024 * 1024, backBufferSeconds: 30)
        case .maximum:
            return StreamEngineConfiguration(
                profile: .maximum, targetBuffer: 45, lowBuffer: 15, highBuffer: 75, lead: 6, rebufferGoal: 6,
                buildRate: 0.97, trickleRate: 0.985, slowLineFloor: 0.90, shedRate: 1.01,
                starvedFailover: 40, maximumReserveBytes: 128 * 1024 * 1024, backBufferSeconds: 30)
        }
    }

    /// A multiview tile: small reserve and memory so several can run side by side.
    func forMultiviewTile() -> StreamEngineConfiguration {
        var copy = StreamEngineConfiguration.profile(.fast)
        copy.maximumReserveBytes = 20 * 1024 * 1024
        copy.backBufferSeconds = 10
        return copy
    }
}
