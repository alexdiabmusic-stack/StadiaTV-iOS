import Foundation

/// When the player gives up, and how it words what it knows, kept free of AVFoundation so it can be tested on its own.
nonisolated enum PlaybackPolicy {

    /// Extra time a converted transport stream gets over a stream the player opens itself: the converter has to
    /// reach the provider, wait for a keyframe and cut its first few segments before the player has anything to open.
    static let converterWarmUp: TimeInterval = 12

    /// How long one way of playing a channel may take to start before the next is tried (or, with none left, the
    /// channel is given up on).
    static func startupLimit(for source: PlaybackCandidate.Source, startupTimeout: TimeInterval) -> TimeInterval {
        switch source {
        case .direct: return startupTimeout
        case .convertedTransportStream: return startupTimeout + converterWarmUp
        }
    }

    /// How long a way of playing a channel may go without a picture while another way is waiting. A little longer than
    /// the start-up limit: that one stands down as soon as the player reports `.playing`, which a stream that keeps
    /// stalling does again and again.
    static func candidateDeadline(for source: PlaybackCandidate.Source, startupTimeout: TimeInterval) -> TimeInterval {
        startupLimit(for: source, startupTimeout: startupTimeout) + 2
    }

    /// The longest a channel may go without showing a picture, however the start-up timers are reset.
    ///
    /// The start-up watchdog stands down as soon as the player reports `.playing`, and each reconnect starts its own
    /// count, so a stream that keeps flapping between playing and waiting would otherwise show the loading screen
    /// for ever. `sources` are the ways the channel may be tried, each of which gets its own deadline.
    static func firstFrameDeadline(startupTimeout: TimeInterval, sources: [PlaybackCandidate.Source]) -> TimeInterval {
        let tries = sources.reduce(0) { $0 + candidateDeadline(for: $1, startupTimeout: startupTimeout) }
        return max(30, tries + 5)
    }

    /// Reconnects allowed inside `reconnectWindow` before a stream is given up on.
    static let maxReconnectsPerWindow = 5
    static let reconnectWindow: TimeInterval = 180

    /// Whether the stream has already needed as many reconnects as it is allowed lately. The controller's own count
    /// starts again whenever the player reports `.playing`, so a stream that plays for a second between stalls
    /// would never reach its limit.
    static func reconnectBudgetSpent(reconnects: [Date], now: Date) -> Bool {
        reconnects.filter { now.timeIntervalSince($0) < reconnectWindow }.count >= maxReconnectsPerWindow
    }

    /// An entry from the player's own error log, worded for a person; nil when it has nothing useful to say.
    /// AVFoundation reports an HTTP status as the status code, or a CoreMedia code with the status in the comment.
    static func describeLoggedError(statusCode: Int, domain: String, comment: String?) -> String? {
        let code: String?
        if (100..<600).contains(statusCode) {
            code = "HTTP \(statusCode)"
        } else if statusCode != 0 {
            code = domain.isEmpty ? "error \(statusCode)" : "\(domain) \(statusCode)"
        } else {
            code = nil
        }
        let note = String((comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        switch (code, note.isEmpty) {
        case let (code?, false): return "Player log: \(code) (\(note))."
        case let (code?, true): return "Player log: \(code)."
        case (nil, false): return "Player log: \(note)."
        case (nil, true): return nil
        }
    }

    /// Whatever is known about a failure's cause, as one block of text, leaving out what is missing. Each part goes on
    /// its own line unless `separator` says otherwise.
    static func combine(_ details: [String?], separator: String = "\n") -> String? {
        let parts = details.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }
}
