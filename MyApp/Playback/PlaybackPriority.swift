import Foundation

/// Lets background refreshers yield to a stream that is starting.
///
/// While a `PlaybackController` is loading (tap → first frame), EPG, fantasy and
/// stream-availability work waits here before starting new network requests, so the
/// first video segments don't compete with them for bandwidth.
enum PlaybackPriority {
    private static var activeLoads = 0
    /// Background work never waits longer than this, even if a load gets stuck.
    private static let maxWait: TimeInterval = 12

    static var isPlaybackStarting: Bool { activeLoads > 0 }

    static func beginLoading() {
        activeLoads += 1
    }

    static func endLoading() {
        activeLoads = max(0, activeLoads - 1)
    }

    /// Returns once no stream is starting (or after `maxWait`).
    static func waitForIdle() async {
        let deadline = Date().addingTimeInterval(maxWait)
        while activeLoads > 0, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Set when the app starts (see `MyApp.init`).
    static var launchDate = Date()
    /// Non-critical launch work waits this long after launch.
    private static let launchSettleDelay: TimeInterval = 5

    /// Waits until the app has been running for a few seconds and no stream is starting.
    /// Use for work that shouldn't compete with the first screen or the first tap.
    static func waitForBackgroundSlot() async {
        let remaining = launchSettleDelay - Date().timeIntervalSince(launchDate)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
        await waitForIdle()
    }
}
