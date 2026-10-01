import Foundation
import os

/// os_signpost intervals around the guide/matching pipeline — guide download, parse, SQLite
/// store write, linker build, link, and the time from opening the Matches tab to the first
/// drawn stream option. Same subsystem ("StadiaTV") as `PlaybackMetrics` so Instruments shows
/// guide/matching work and playback timing together on one timeline. See MatchLinker/
/// PROMPTS.md, Prompt 8 step 3.
///
/// `beginX()` generates a fresh signpost id per call (not `.exclusive`) wherever more than one
/// interval of that name can legitimately be in flight at once — guide downloads/parses run
/// concurrently across sources, and `link()` runs concurrently across matches in a task group.
nonisolated enum GuideMatchingSignposts {
    static let logger = Logger(subsystem: "StadiaTV", category: "GuideMatching")
    private static let signposter = OSSignposter(logger: logger)

    static func beginGuideDownload() -> OSSignpostIntervalState {
        signposter.beginInterval("GuideDownload", id: signposter.makeSignpostID())
    }
    static func endGuideDownload(_ state: OSSignpostIntervalState) {
        signposter.endInterval("GuideDownload", state)
    }

    static func beginGuideParse() -> OSSignpostIntervalState {
        signposter.beginInterval("GuideParse", id: signposter.makeSignpostID())
    }
    static func endGuideParse(_ state: OSSignpostIntervalState) {
        signposter.endInterval("GuideParse", state)
    }

    static func beginStoreWrite() -> OSSignpostIntervalState {
        signposter.beginInterval("StoreWrite", id: signposter.makeSignpostID())
    }
    static func endStoreWrite(_ state: OSSignpostIntervalState) {
        signposter.endInterval("StoreWrite", state)
    }

    static func beginLinkerBuild() -> OSSignpostIntervalState {
        signposter.beginInterval("LinkerBuild")
    }
    static func endLinkerBuild(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LinkerBuild", state)
    }

    static func beginLink() -> OSSignpostIntervalState {
        signposter.beginInterval("Link", id: signposter.makeSignpostID())
    }
    static func endLink(_ state: OSSignpostIntervalState) {
        signposter.endInterval("Link", state)
    }

    static func beginMatchesTabToFirstOption() -> OSSignpostIntervalState {
        signposter.beginInterval("MatchesTabToFirstOption")
    }
    static func endMatchesTabToFirstOption(_ state: OSSignpostIntervalState) {
        signposter.endInterval("MatchesTabToFirstOption", state)
    }
}
