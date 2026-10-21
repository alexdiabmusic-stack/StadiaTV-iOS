import Foundation

/// Chooses the playback rate that keeps the reserve where the profile wants it.
///
/// Buffer change per second ≈ delivery ratio − playback rate, so a line delivering 0.93 s of
/// programme per second is sustainable at 0.93x where 1.0x would drain the reserve and freeze.
/// On a healthy line the rate sits a fraction below 1.0x until the reserve reaches its target
/// (0.992x banks about half a second a minute, inaudibly), and a hair above 1.0x when the
/// buffer has grown well past it. Rates change slowly so the tempo never audibly lurches;
/// AVPlayer applies them with pitch correction.
nonisolated struct PlaybackPaceController {
    enum Reason: String, Equatable, Sendable {
        case normal, building, trickling, slowLine, outage, shedding
    }

    private(set) var rate: Double = 1.0
    private(set) var reason: Reason = .normal
    /// Slow-line mode has hysteresis: delivery measured in bursts hovers around 1.0, and the
    /// rate must not flap between "slow line" and "normal" on that noise.
    private(set) var slowLineActive = false

    /// Largest rate change per second.
    static let slewPerSecond = 0.01
    /// Changes smaller than this aren't worth sending to the player.
    static let deadband = 0.002
    static let slowLineEnter = 0.97
    static let slowLineExit = 0.995

    /// Returns the new rate when it changed enough to apply.
    mutating func update(buffered: Double, deliveryRatio: Double?, isOutage: Bool, isStarved: Bool,
                         configuration: StreamEngineConfiguration, elapsed: Double) -> Double? {
        if let ratio = deliveryRatio {
            if slowLineActive {
                if ratio > Self.slowLineExit || buffered >= configuration.targetBuffer { slowLineActive = false }
            } else if ratio < Self.slowLineEnter, buffered < configuration.targetBuffer {
                slowLineActive = true
            }
        }
        let (target, why) = Self.target(buffered: buffered, deliveryRatio: slowLineActive ? deliveryRatio : nil,
                                         isOutage: isOutage, isStarved: isStarved, configuration: configuration)
        reason = why
        let step = Self.slewPerSecond * max(0, elapsed)
        let next = target > rate ? min(target, rate + step) : max(target, rate - step)
        guard abs(next - rate) >= Self.deadband || (next == target && next != rate) else { return nil }
        rate = (next * 1000).rounded() / 1000
        return rate
    }

    /// The rate the controller is steering toward, before slew limiting. `deliveryRatio` is only
    /// passed while the line is judged too slow.
    static func target(buffered: Double, deliveryRatio: Double?, isOutage: Bool, isStarved: Bool,
                       configuration c: StreamEngineConfiguration) -> (Double, Reason) {
        if isStarved { return (1.0, .normal) }
        // During an outage the reserve is all there is: stretch it.
        if isOutage, buffered < c.targetBuffer { return (c.slowLineFloor, .outage) }
        if let ratio = deliveryRatio, buffered < c.targetBuffer {
            return (min(c.buildRate, max(c.slowLineFloor, ratio - 0.015)), .slowLine)
        }
        if buffered < c.lowBuffer { return (c.buildRate, .building) }
        if buffered < c.targetBuffer { return (c.trickleRate, .trickling) }
        if buffered > c.highBuffer { return (c.shedRate, .shedding) }
        return (1.0, .normal)
    }
}

/// What happened, when, with how much buffer — the record that answers "why did it freeze?".
nonisolated struct StreamEngineJournal {
    struct Entry: Equatable, Identifiable, Sendable {
        enum Kind: String, Equatable, Sendable { case connection, splice, recovery, pace, decoder, account, warning }
        let id: Int
        let date: Date
        let kind: Kind
        let message: String
        /// Programme seconds buffered ahead of the playhead when it happened.
        let buffered: Double
    }

    private(set) var entries: [Entry] = []
    private var nextID = 0
    let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    mutating func record(_ kind: Entry.Kind, _ message: String, buffered: Double, at date: Date = Date()) {
        entries.append(Entry(id: nextID, date: date, kind: kind, message: message, buffered: buffered))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func recent(_ count: Int) -> [Entry] { Array(entries.suffix(count)) }
}
