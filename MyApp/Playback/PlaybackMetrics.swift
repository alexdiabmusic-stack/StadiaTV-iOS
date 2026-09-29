import Foundation
import os

/// Start-up timing for one playback attempt (one stream load), measured from the user's tap.
///
/// Every mark is logged once to the `StadiaTV / Playback` log category and emitted as a
/// signpost event so it lines up with other work in Instruments. Only the stream host and
/// path extension are logged; Xtream URLs embed the account credentials.
nonisolated struct PlaybackMetrics: Sendable {
    enum Mark: String, Sendable {
        case tapReceived, playerAppeared, itemCreated, readyToPlay, firstFrame, firstStall, failed
    }

    static let logger = Logger(subsystem: "StadiaTV", category: "Playback")
    private static let signposter = OSSignposter(logger: logger)

    let attemptID = UUID()
    let tapDate: Date
    let streamDescription: String
    private let signpostID: OSSignpostID
    private(set) var elapsedMs: [Mark: Int] = [:]

    init(tapDate: Date, url: URL) {
        self.tapDate = tapDate
        self.streamDescription = StreamHTTPHeaders.redactedDescription(of: url)
        self.signpostID = Self.signposter.makeSignpostID()
        record(.tapReceived, at: tapDate)
    }

    /// Records a mark the first time it happens in this attempt; later repeats are ignored.
    mutating func record(_ mark: Mark, reason: String? = nil, at date: Date = Date()) {
        guard elapsedMs[mark] == nil else { return }
        let ms = max(0, Int(date.timeIntervalSince(tapDate) * 1000))
        elapsedMs[mark] = ms
        let attempt = String(attemptID.uuidString.prefix(8))
        let stream = streamDescription
        if let reason {
            Self.logger.info("[\(attempt, privacy: .public)] \(mark.rawValue, privacy: .public) +\(ms) ms · \(stream, privacy: .public) · \(reason, privacy: .public)")
        } else {
            Self.logger.info("[\(attempt, privacy: .public)] \(mark.rawValue, privacy: .public) +\(ms) ms · \(stream, privacy: .public)")
        }
        Self.signposter.emitEvent("PlaybackMark", id: signpostID, "\(mark.rawValue, privacy: .public) +\(ms) ms")
    }

    var timeToFirstFrameMs: Int? { elapsedMs[.firstFrame] }

    /// Compact line for the DEBUG overlay, e.g. "TTFF 1.84 s · ready 1.21 s · host · m3u8".
    var summary: String {
        var parts: [String] = []
        if let ttff = elapsedMs[.firstFrame] {
            parts.append("TTFF \(Self.seconds(ttff))")
        } else if elapsedMs[.failed] != nil {
            parts.append("failed")
        } else {
            parts.append("TTFF …")
        }
        if let ready = elapsedMs[.readyToPlay] {
            parts.append("ready \(Self.seconds(ready))")
        }
        parts.append(streamDescription)
        return parts.joined(separator: " · ")
    }

    private static func seconds(_ ms: Int) -> String {
        String(format: "%.2f s", Double(ms) / 1000)
    }
}

/// Remembers when the user tapped something that opens the player, so the player can
/// measure time-to-first-frame from the tap rather than from when it appeared.
enum PlaybackTapClock {
    private static var lastTap: Date?

    static func record() {
        lastTap = Date()
    }

    /// Returns the pending tap time (if recent) and clears it.
    static func consume() -> Date? {
        defer { lastTap = nil }
        guard let lastTap, Date().timeIntervalSince(lastTap) < 15 else { return nil }
        return lastTap
    }
}
