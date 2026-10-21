import Foundation

/// Watches the provider connection at the ingest boundary, long before the decoder could notice.
///
/// It measures delivery in programme seconds per wall-clock second (not bytes), so a line that
/// delivers 0.93 s of programme every second reads 0.93 whatever the bitrate. A fast and a
/// slow moving average are kept: the fast one catches a collapse, the slow one stops a single
/// burst from looking like recovery. Only network and stream signals feed it; decoder or
/// display hiccups never count as a weak line.
nonisolated struct StreamHealthMonitor {
    enum Condition: String, Equatable, Sendable {
        /// Waiting for the connection's first programme.
        case starting
        case healthy
        /// Delivering, but a little slower than real time.
        case marginal
        /// Too slow to sustain playback and the buffer is getting low.
        case unsustainable
        /// Connected but silent for a few seconds: the everyday server pause.
        case deliveryPause
        /// Silent long enough that the connection should be replaced.
        case stalled
    }

    private(set) var connectedAt: Double?
    private(set) var lastByteAt: Double?
    private(set) var lastProgrammeAt: Double?
    private(set) var firstProgrammeAt: Double?
    /// Programme seconds delivered per wall second.
    private(set) var fastRatio: Double?
    private(set) var slowRatio: Double?
    /// Received bits per second, smoothed.
    private(set) var bitrate: Double?
    /// Bits per programme second: the stream's own bitrate.
    private(set) var streamBitrate: Double?
    /// The usual pause between deliveries. Streams a panel restreams from HLS arrive a segment at a
    /// time, every few seconds, and that silence is healthy; learned across reconnects.
    private(set) var deliveryCadence: Double = 0
    private var deliveryGaps: [Double] = []

    private var sampleStart: Double?
    private var sampleProgramme: Double = 0
    private var sampleBytes = 0
    private var totalProgramme: Double = 0
    private var totalBytes = 0
    private var firstProgrammeEver = false

    mutating func connectionOpened(at now: Double) {
        connectedAt = now
        firstProgrammeAt = nil
        lastByteAt = now
    }

    mutating func connectionClosed() {
        connectedAt = nil
    }

    mutating func received(bytes: Int, at now: Double) {
        // Gaps in the first seconds belong to the connect and the provider's burst, not its rhythm.
        if let last = lastByteAt, let connectedAt, now - connectedAt > 2, now - last >= 0.3 {
            deliveryGaps.append(now - last)
            if deliveryGaps.count > 12 { deliveryGaps.removeFirst() }
            // The second-largest recent gap: short gaps while a burst arrives don't hide the rhythm,
            // and a single stall doesn't become it.
            let sorted = deliveryGaps.sorted(by: >)
            deliveryCadence = sorted.count >= 3 ? sorted[1] : sorted[0]
        }
        lastByteAt = now
        sampleBytes += bytes
        totalBytes += bytes
        if sampleStart == nil { sampleStart = now }
    }

    /// New programme reached the reserve (duplicates removed by the splicer don't count).
    mutating func ingested(programmeSeconds: Double, at now: Double) {
        guard programmeSeconds > 0 else { return }
        lastProgrammeAt = now
        if firstProgrammeAt == nil { firstProgrammeAt = now }
        if !firstProgrammeEver {
            firstProgrammeEver = true
            sampleStart = now
            sampleBytes = 0
        }
        sampleProgramme += programmeSeconds
        totalProgramme += programmeSeconds
        if sampleStart == nil { sampleStart = now }
        if totalProgramme > 5 { streamBitrate = Double(totalBytes * 8) / totalProgramme }
    }

    /// Closes a measurement window once a second has passed.
    mutating func sample(at now: Double) {
        // Before the first programme there is nothing to measure; zeros would read as a dead line.
        guard firstProgrammeEver else {
            sampleStart = now
            sampleProgramme = 0
            sampleBytes = 0
            return
        }
        guard let start = sampleStart else {
            sampleStart = now
            return
        }
        let elapsed = now - start
        // A window spans at least two of the stream's usual pauses: a source that arrives a segment
        // every five seconds would otherwise read as dead, then as five times real time.
        guard elapsed >= max(1, 2 * deliveryCadence) else { return }
        let ratio = sampleProgramme / elapsed
        let bits = Double(sampleBytes * 8) / elapsed
        // Smoothing per second of wall time, whatever the window length.
        func weight(_ perSecond: Double) -> Double { 1 - pow(1 - perSecond, elapsed) }
        fastRatio = fastRatio.map { $0 + weight(0.35) * (ratio - $0) } ?? ratio
        slowRatio = slowRatio.map { $0 + weight(0.08) * (ratio - $0) } ?? ratio
        bitrate = bitrate.map { $0 + weight(0.3) * (bits - $0) } ?? bits
        sampleStart = now
        sampleProgramme = 0
        sampleBytes = 0
    }

    /// Seconds since the connection last produced anything (bytes or programme).
    func silence(at now: Double) -> Double? {
        guard connectedAt != nil else { return nil }
        let last = max(lastByteAt ?? 0, lastProgrammeAt ?? 0)
        return last > 0 ? now - last : nil
    }

    /// Seconds since new programme last arrived, on any connection.
    func programmeDrought(at now: Double) -> Double? {
        lastProgrammeAt.map { now - $0 }
    }

    func condition(at now: Double, buffered: Double, configuration: StreamEngineConfiguration) -> Condition {
        guard connectedAt != nil else { return .stalled }
        guard firstProgrammeAt != nil else { return .starting }
        if let silence = silence(at: now) {
            if silence >= Self.stallTimeout(buffered: buffered, configuration: configuration) { return .stalled }
            if silence >= 2.5 { return .deliveryPause }
        }
        if let slowRatio {
            if slowRatio < 0.9, buffered < configuration.lowBuffer { return .unsustainable }
            if slowRatio < 0.99 { return .marginal }
        }
        return .healthy
    }

    /// How long a silent connection is tolerated: long enough to bridge ordinary server pauses
    /// without churning connections, short enough to leave a safety margin of buffer.
    static func stallTimeout(buffered: Double, configuration: StreamEngineConfiguration) -> Double {
        min(configuration.stallTimeoutMaximum,
            max(configuration.stallTimeoutMinimum, buffered - configuration.stallSafetyMargin))
    }
}
