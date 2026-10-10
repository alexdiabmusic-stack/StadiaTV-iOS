import Foundation

/// The segments of a live stream and the playlist that lists the latest of them, shared between the thread that cuts
/// the stream and the threads that answer the player's requests.
nonisolated final class HLSSegmentStore: @unchecked Sendable {

    nonisolated enum PlaylistResult: Equatable {
        case playlist(String)
        case failed(String)
        case timedOut
    }

    /// Segments listed in the playlist; the player starts a live stream near the end of it.
    private let windowSize = 5
    /// Segments kept for the player to fetch, a little more than are listed so a slow request still finds its own.
    private let retained = 8
    /// The playlist is first offered when this much video (or this many segments) is ready, so the player starts
    /// with a cushion rather than at the very edge of a stream that only grows in real time.
    private let startSeconds = 6.0
    private let startSegments = 3

    private let condition = NSCondition()
    private var segments: [HLSSegmenter.Segment] = []
    private var evictedDiscontinuities = 0
    private var failure: String?
    private var target = 0
    private var cancelled = false

    /// Adds segments as they are cut.
    func add(_ new: [HLSSegmenter.Segment]) {
        guard !new.isEmpty else { return }
        condition.lock()
        segments.append(contentsOf: new)
        while segments.count > retained {
            let removed = segments.removeFirst()
            if removed.discontinuity { evictedDiscontinuities += 1 }
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Records why no more segments are coming; whoever is waiting for the playlist is told at once.
    func fail(_ reason: String) {
        condition.lock()
        if failure == nil { failure = reason }
        condition.broadcast()
        condition.unlock()
    }

    /// Releases anyone waiting; nothing more will be served.
    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    var failureReason: String? {
        condition.lock()
        defer { condition.unlock() }
        return failure
    }

    var segmentCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return segments.count
    }

    /// The playlist, waiting up to `timeout` for enough of the stream to have been cut to start from.
    func playlist(timeout: TimeInterval) -> PlaylistResult {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled { return .failed("The stream was closed.") }
            if isReady { return .playlist(render()) }
            if let failure { return .failed(failure) }
            if !condition.wait(until: deadline) { return isReady ? .playlist(render()) : .timedOut }
        }
    }

    /// The bytes of a segment, if it is still kept.
    func segment(sequence: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return segments.first { $0.sequence == sequence }?.data
    }

    // MARK: Playlist

    private var isReady: Bool {
        if target > 0 { return !segments.isEmpty }   // already started: any segment will do
        let seconds = segments.reduce(0) { $0 + $1.duration }
        return segments.count >= startSegments || (segments.count >= 2 && seconds >= startSeconds)
    }

    private func render() -> String {
        let listed = Array(segments.suffix(windowSize))
        // The target duration is a promise about every segment, so it only ever goes up.
        let longest = listed.map(\.duration).max() ?? 0
        target = max(target, max(3, Int(longest.rounded(.up)) + 1))

        let first = listed.first?.sequence ?? 0
        let skippedFlags = segments.filter { $0.sequence < first && $0.discontinuity }.count + evictedDiscontinuities
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
        if skippedFlags > 0 { lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(skippedFlags)") }
        for segment in listed {
            if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("segment\(segment.sequence).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
