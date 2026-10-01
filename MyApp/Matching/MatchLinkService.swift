import Foundation

/// Owns the app's one `StreamLinker` instance and serves link results to every screen that
/// used to call `SourceMatcher`. See MatchLinker/PROMPTS.md, Prompt 2.
///
/// An actor, not `@MainActor`: building the index (hundreds of ms on a real playlist) and
/// linking (sub-millisecond, but summed across every visible match) must never run on the
/// main thread. Every type it touches from `StreamLinker.swift` is `nonisolated` and `Sendable`
/// for exactly this reason.
actor MatchLinkService {
    private var linker: StreamLinker?
    private var builtSignature: String?
    private(set) var revision: Int = 0
    private var cache: [String: (revision: Int, families: [LinkedFamily])] = [:]

    /// Rebuilds only when `signature` differs from the signature of the index currently held
    /// (e.g. `"<channelCount>|<lastUpdated>"`) — cheap to call on every scan, and the `programmes`
    /// closure (a SQLite read across the whole guide) only runs when a rebuild is actually needed.
    func rebuildIfNeeded(signature: String, channels: [Channel], programmes: () async -> [EPGProgramme]) async {
        guard signature != builtSignature else { return }
        let streams = channels.map(StreamLinkerAdapters.stream)
        let progs = await programmes().map(StreamLinkerAdapters.programme)
        let signpost = GuideMatchingSignposts.beginLinkerBuild()
        linker = StreamLinker(streams: streams, programmes: progs)
        GuideMatchingSignposts.endLinkerBuild(signpost)
        builtSignature = signature
        revision += 1
        cache.removeAll(keepingCapacity: true)
    }

    /// Ranked `[LinkedFamily]` for one match, best confidence first. Cached by match id and
    /// revision, so re-asking for the same match between rebuilds is free.
    func options(for match: Match) -> [LinkedFamily] {
        guard let linker, match.state != .final else { return [] }
        if let hit = cache[match.id], hit.revision == revision { return hit.families }
        let signpost = GuideMatchingSignposts.beginLink()
        let families = linker.link(StreamLinkerAdapters.event(match)).groupedByFamily()
        GuideMatchingSignposts.endLink(signpost)
        cache[match.id] = (revision, families)
        return families
    }

    /// Links every non-final match starting within the next 48 hours in one pass, so opening
    /// the Matches tab reads a warm cache instead of linking on first view.
    func prewarm(matches: [Match]) {
        guard linker != nil else { return }
        let horizon = Date().addingTimeInterval(48 * 3600)
        for match in matches where match.state != .final && match.date <= horizon {
            _ = options(for: match)
        }
    }

    /// Forces the next `rebuildIfNeeded` call to actually rebuild even if its cheap signature
    /// (channel count + guide revision) hasn't changed — used when an event-slot channel's name
    /// changes in place (`EventChannelRefreshService`), which changes what the linker should
    /// find without changing either of those two numbers.
    func invalidate() {
        builtSignature = nil
    }

    /// Sizes of the current index, for logs and the Prompt 8 performance budgets.
    var stats: StreamLinker.Stats? { linker?.stats }
}
