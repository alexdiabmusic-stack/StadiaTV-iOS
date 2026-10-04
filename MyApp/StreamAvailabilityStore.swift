import Foundation
import Combine

/// Shared store of per-match stream counts, populated by linking playlist channels to matches
/// through `MatchLinkService` (`StreamLinker`, see MatchLinker/PROMPTS.md). Results are cached
/// so MatchDetailView can display them instantly without re-running the scan.
@MainActor
final class StreamAvailabilityStore: ObservableObject {

    /// The one `StreamLinker` instance for the app's current playlist + guide. Rebuilt lazily
    /// inside `scan`, keyed by a cheap signature, so most `scan` calls do no rebuild work at all.
    let linkService = MatchLinkService()

    /// Number of playlist channels that pass the minimum relevance threshold, keyed by match ID.
    /// 0 means scan ran but found no streams; absent means scan has not yet run for that match.
    @Published private(set) var countByMatchId: [String: Int] = [:]

    /// Number of channels with strong event-specific evidence (guide, team name, or event title match).
    @Published private(set) var confirmedCountByMatchId: [String: Int] = [:]

    /// Full ranked source list from the last scan, keyed by match ID.
    /// Read by MatchDetailView for an instant display on open — no re-scan needed.
    @Published private(set) var sourcesByMatchId: [String: [RankedSource]] = [:]

    /// Monotonically-increasing generation counter, incremented at the start of every scan.
    private var nextGeneration: Int = 0

    /// The generation of the scan that most recently claimed each match ID. Stamped for every
    /// match a scan evaluates *before* that scan's async work starts, so that two overlapping
    /// scans over different (possibly non-disjoint) match sets — e.g. RootView's live-match scan
    /// and MatchesView's followed-match scan — each only write results for the match IDs they
    /// still hold the latest claim on. Without this, a scan that started earlier but finishes
    /// later would silently drop the other scan's results for any match ID it didn't cover.
    private var generationByMatchId: [String: Int] = [:]

    /// Wall-clock time this store last actually attempted a scan (debounced or forced).
    /// Used by `scanDebounced` to bound worst-case staleness — see below.
    private var lastScanAttemptAt: Date?

    /// Per-league confidence history for "Not on your playlist" collapsing (MatchLinker/
    /// PROMPTS.md, Prompt 7 step 3): one record per match id seen in the last 14 days, updated
    /// (not appended) every time that match is scanned again, so re-scanning a still-upcoming
    /// match doesn't double-count it. Persisted so the signal survives app relaunches instead of
    /// needing 14 days of continuous runtime to build up.
    struct LeagueVisibilityRecord: Codable { var date: Date; var leaguePath: String; var confirmed: Bool }
    private var leagueVisibilityLog: [String: LeagueVisibilityRecord] = [:] {
        didSet { schedulePersistOfLeagueVisibilityLog() }
    }
    private var leagueVisibilityPersistTask: Task<Void, Never>?
    private let leagueVisibilityKey = "streamAvailability.leagueVisibilityLog.v1"
    private let leagueVisibilityWindow: TimeInterval = 14 * 86400

    private func loadLeagueVisibilityLog() -> [String: LeagueVisibilityRecord]? {
        guard let data = UserDefaults.standard.data(forKey: leagueVisibilityKey) else { return nil }
        return try? JSONDecoder().decode([String: LeagueVisibilityRecord].self, from: data)
    }

    /// The log is a rolling confidence signal, not user data, so it's written once a burst of scans
    /// settles rather than re-encoding the whole fourteen days after every one. A write lost to
    /// the app being killed in that window costs a few seconds of history.
    private func schedulePersistOfLeagueVisibilityLog() {
        leagueVisibilityPersistTask?.cancel()
        leagueVisibilityPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let data = try? JSONEncoder().encode(self.leagueVisibilityLog) else { return }
            UserDefaults.standard.set(data, forKey: self.leagueVisibilityKey)
        }
    }

    // Assigned here rather than from a method so loading it doesn't trigger a write straight back.
    init() {
        if let decoded = loadLeagueVisibilityLog() { leagueVisibilityLog = decoded }
    }

    /// Not private: `StreamAvailabilityStoreVisibilityTests` seeds records directly rather than
    /// running a full `scan()` (which needs a real playlist + guide).
    func recordLeagueVisibility(matches: [Match], confirmedCounts: [String: Int]) {
        let cutoff = Date().addingTimeInterval(-leagueVisibilityWindow)
        var log = leagueVisibilityLog
        log = log.filter { $0.value.date >= cutoff }
        for match in matches {
            log[match.id] = LeagueVisibilityRecord(date: Date(), leaguePath: match.league.path, confirmed: (confirmedCounts[match.id] ?? 0) > 0)
        }
        leagueVisibilityLog = log
    }

    /// False when this league has 10+ matches in the last 14 days and not one had a confident
    /// stream — the playlist's guide plainly doesn't carry it. A league with fewer than 10
    /// matches always stays visible: that's too little evidence either way.
    func isLeagueOnPlaylist(_ league: League) -> Bool {
        let records = leagueVisibilityLog.values.filter { $0.leaguePath == league.path }
        guard records.count >= 10 else { return true }
        return records.contains { $0.confirmed }
    }

    /// Debounced entry point for `.task(id:)`-driven callers, whose id includes
    /// `EPGRepository.lastUpdated`. That timestamp is bumped not just by a real full/custom
    /// EPG merge but also by every tiny single-channel EPG.pw background prefetch — each of
    /// which would otherwise cancel and restart this same O(matches × channels) scan. Waiting
    /// briefly lets a burst of rapid triggers collapse into a single scan: SwiftUI's
    /// `.task(id:)` cancels the previous task (aborting this sleep) whenever the id changes
    /// again before the delay elapses, so only the last trigger in a burst actually scans.
    ///
    /// A *continuous* trickle of triggers (e.g. many EPG.pw single-channel prefetches
    /// completing in quick succession while a scan is in progress) would otherwise starve
    /// this forever — every call gets cancelled by the next one before its own delay ever
    /// elapses, so `scan()` never runs. Guard against that: if it's already been at least
    /// `delay` since the last attempt, skip the wait and scan immediately instead of queuing
    /// behind a delay that this trigger might never survive. This bounds worst-case latency
    /// to roughly `delay` even under a sustained burst, while still collapsing an isolated
    /// burst into a single scan once it settles.
    func scanDebounced(matches: [Match], channels: [Channel], epgRepository: EPGRepository, delaySeconds: TimeInterval = 0.4) async {
        let elapsed = lastScanAttemptAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed < delaySeconds {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
        }
        // Deferred at launch and while a stream is starting; the first phase runs on the main actor.
        await PlaybackPriority.waitForBackgroundSlot()
        guard !Task.isCancelled else { return }
        lastScanAttemptAt = Date()
        await scan(matches: matches, channels: channels, epgRepository: epgRepository)
    }

    /// Scans `matches` against `channels` using EPG-first matching: the guide is queried for each
    /// match first, then all team/event-named channels are appended as backups.
    /// Results are cached in `sourcesByMatchId` so detail views display instantly.
    func scan(matches: [Match], channels: [Channel], epgRepository: EPGRepository) async {
        let nonFinal = matches.filter { $0.state != .final }
        let finalIds = Set(matches.filter { $0.state == .final }.map(\.id))

        if !finalIds.isEmpty {
            countByMatchId = countByMatchId.filter { !finalIds.contains($0.key) }
            confirmedCountByMatchId = confirmedCountByMatchId.filter { !finalIds.contains($0.key) }
            sourcesByMatchId = sourcesByMatchId.filter { !finalIds.contains($0.key) }
            generationByMatchId = generationByMatchId.filter { !finalIds.contains($0.key) }
        }

        guard !nonFinal.isEmpty else { return }

        nextGeneration += 1
        let myGeneration = nextGeneration
        for match in nonFinal { generationByMatchId[match.id] = myGeneration }

        var freshCounts: [String: Int] = Dictionary(uniqueKeysWithValues: nonFinal.map { ($0.id, 0) })
        var freshConfirmedCounts: [String: Int] = Dictionary(uniqueKeysWithValues: nonFinal.map { ($0.id, 0) })
        var freshSources: [String: [RankedSource]] = [:]

        if !channels.isEmpty {
            // Rebuild the linker only when the playlist or guide actually changed since the
            // last scan — cheap to check, so every debounced trigger can call this.
            let signature = "\(channels.count)|\(epgRepository.programmeRevision)"
            await linkService.rebuildIfNeeded(signature: signature, channels: channels) {
                let now = Date()
                return (try? await EPGProgrammeStore.shared.snapshot(
                    from: now.addingTimeInterval(-6 * 3600),
                    to: now.addingTimeInterval(72 * 3600)
                )) ?? []
            }
            guard !Task.isCancelled else { return }

            // Channel lookups are keyed by playlist-scoped stream id (see
            // StreamLinkerAdapters.streamID) since a bare Channel.id is only unique within
            // one playlist. Built once per scan cycle, not once per match.
            let channelByID: [String: Channel] = await Task.detached(priority: .utility) {
                var map: [String: Channel] = [:]
                for channel in channels { map[StreamLinkerAdapters.streamID(channel)] = channel }
                return map
            }.value
            guard !Task.isCancelled else { return }

            let service = linkService
            await withTaskGroup(of: (String, [RankedSource]).self) { group in
                for match in nonFinal {
                    let m = match
                    group.addTask(priority: .utility) {
                        let families = await service.options(for: m)
                        let sources = StreamLinkerAdapters.rankedSources(for: families, channelByID: channelByID)
                        return (m.id, sources)
                    }
                }
                for await (id, sources) in group {
                    freshCounts[id] = sources.count
                    freshConfirmedCounts[id] = sources.filter(\.isConfirmed).count
                    if !sources.isEmpty { freshSources[id] = sources }
                }
            }
        }

        // Only write results for match IDs this scan still holds the latest claim on — a
        // newer overlapping scan may have already re-claimed some of these IDs while this
        // scan's async work was in flight, in which case its results must win instead.
        let winningIds = Set(nonFinal.map(\.id)).filter { generationByMatchId[$0] == myGeneration }
        guard !winningIds.isEmpty else { return }

        var mergedCounts = countByMatchId
        var mergedConfirmed = confirmedCountByMatchId
        var mergedSources = sourcesByMatchId
        for id in winningIds {
            mergedCounts[id] = freshCounts[id] ?? 0
            mergedConfirmed[id] = freshConfirmedCounts[id] ?? 0
            if let sources = freshSources[id] {
                mergedSources[id] = sources
            } else {
                mergedSources.removeValue(forKey: id)
            }
        }
        countByMatchId = mergedCounts
        confirmedCountByMatchId = mergedConfirmed
        sourcesByMatchId = mergedSources
        recordLeagueVisibility(matches: nonFinal.filter { winningIds.contains($0.id) }, confirmedCounts: freshConfirmedCounts)
    }

    func count(for matchId: String) -> Int { countByMatchId[matchId] ?? 0 }

    func confirmedCount(for matchId: String) -> Int { confirmedCountByMatchId[matchId] ?? 0 }

    func topRanked(for matchId: String, limit: Int = 3) -> [RankedSource] {
        Array((sourcesByMatchId[matchId] ?? []).prefix(limit))
    }

    /// Rebuilds the linker for `channels` if needed, then answers "does this match link to
    /// this channel, and how confidently?" — a 0...100 scale matching `RankedSource.score`'s
    /// convention, for the reverse (channel-you're-watching -> which live match is this?)
    /// lookups in `PlayerView`/`TVPlayerView` and the fantasy game-channel linker, none of
    /// which need the full per-match cache this store otherwise maintains.
    func confidenceScore(match: Match, channel: Channel, channels: [Channel], epgRepository: EPGRepository) async -> Int {
        guard match.state != .final else { return 0 }
        let signature = "\(channels.count)|\(epgRepository.programmeRevision)"
        await linkService.rebuildIfNeeded(signature: signature, channels: channels) {
            let now = Date()
            return (try? await EPGProgrammeStore.shared.snapshot(
                from: now.addingTimeInterval(-6 * 3600),
                to: now.addingTimeInterval(72 * 3600)
            )) ?? []
        }
        let families = await linkService.options(for: match)
        let target = StreamLinkerAdapters.streamID(channel)
        let best = families.flatMap(\.members).filter { $0.streamIDs.contains(target) }.map(\.confidence).max() ?? 0
        return Int(best * 100)
    }
}
