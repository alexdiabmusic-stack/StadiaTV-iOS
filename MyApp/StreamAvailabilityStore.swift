import Foundation
import Combine

/// Shared store of per-match stream counts, populated by scanning playlist channels
/// using EPG guide confirmation first, then team-name backup matching. Results are cached
/// so MatchDetailView can display them instantly without re-running the scan.
@MainActor
final class StreamAvailabilityStore: ObservableObject {

    /// Number of playlist channels that pass the minimum relevance threshold, keyed by match ID.
    /// 0 means scan ran but found no streams; absent means scan has not yet run for that match.
    @Published private(set) var countByMatchId: [String: Int] = [:]

    /// Number of channels with strong event-specific evidence (guide, team name, or event title match).
    @Published private(set) var confirmedCountByMatchId: [String: Int] = [:]

    /// Full ranked source list from the last scan, keyed by match ID.
    /// Read by MatchDetailView for an instant display on open — no re-scan needed.
    @Published private(set) var sourcesByMatchId: [String: [RankedSource]] = [:]

    /// Monotonically-increasing generation counter. Incremented at the start of every scan so
    /// a stale concurrent scan cannot overwrite results from a newer one.
    private var scanGeneration: Int = 0

    /// Debounced entry point for `.task(id:)`-driven callers, whose id includes
    /// `EPGRepository.lastUpdated`. That timestamp is bumped not just by a real full/custom
    /// EPG merge but also by every tiny single-channel EPG.pw background prefetch — each of
    /// which would otherwise cancel and restart this same O(matches × channels) scan. Waiting
    /// briefly lets a burst of rapid triggers collapse into a single scan: SwiftUI's
    /// `.task(id:)` cancels the previous task (aborting this sleep) whenever the id changes
    /// again before the delay elapses, so only the last trigger in a burst actually scans.
    func scanDebounced(matches: [Match], channels: [Channel], epgRepository: EPGRepository, delay: Duration = .milliseconds(400)) async {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
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
        }

        guard !nonFinal.isEmpty else { return }

        scanGeneration += 1
        let myGeneration = scanGeneration

        var freshCounts: [String: Int] = Dictionary(uniqueKeysWithValues: nonFinal.map { ($0.id, 0) })
        var freshConfirmedCounts: [String: Int] = Dictionary(uniqueKeysWithValues: nonFinal.map { ($0.id, 0) })
        var freshSources: [String: [RankedSource]] = [:]

        if !channels.isEmpty {
            // Phase 1 (main actor, synchronous): run EPG lookups for all matches at once.
            // programmesNear is an in-memory dictionary scan — fast and actor-safe.
            let channelToCanonical = epgRepository.channelToCanonicalMap
            var canonicalToChannels: [String: [Channel]] = [:]
            for channel in channels {
                if let cid = channelToCanonical[channel.id] {
                    canonicalToChannels[cid, default: []].append(channel)
                }
            }

            struct EPGMatchResult: Sendable {
                let matchId: String
                let bestJoinByCanonical: [String: ProgrammeEventJoin]
                let canonicalToChannels: [String: [Channel]]
            }

            var epgResults: [EPGMatchResult] = []
            epgResults.reserveCapacity(nonFinal.count)
            for match in nonFinal {
                let titleHints = [match.name, match.shortName, match.home.displayName, match.away.displayName]
                    .filter { !$0.isEmpty }
                let broadcastNetworks = match.broadcasts.filter { !$0.isEmpty }
                let joins = epgRepository.programmesNear(
                    start: match.date,
                    titleHints: titleHints,
                    broadcastNetworks: broadcastNetworks
                )
                var bestJoins: [String: ProgrammeEventJoin] = [:]
                for join in joins where SourceMatcher.confirms(programme: join.programme, for: match) {
                    if let existing = bestJoins[join.canonicalChannelId] {
                        if join.score > existing.score { bestJoins[join.canonicalChannelId] = join }
                    } else {
                        bestJoins[join.canonicalChannelId] = join
                    }
                }
                epgResults.append(EPGMatchResult(matchId: match.id, bestJoinByCanonical: bestJoins,
                                                  canonicalToChannels: canonicalToChannels))
            }

            // Phase 2 (background, parallel): build primary + backup sources for every match.
            await withTaskGroup(of: (String, [RankedSource]).self) { group in
                for (match, epgResult) in zip(nonFinal, epgResults) {
                    let m = match
                    let er = epgResult
                    let chans = channels
                    group.addTask(priority: .utility) {
                        var primarySources: [RankedSource] = []
                        var primaryIds = Set<String>()
                        for (canonicalId, join) in er.bestJoinByCanonical {
                            // See MatchDetailView.rankSources(): a scoped programme only
                            // confirms the one mirror/feed it names, not the whole canonical group.
                            let scopedId = join.programme.scopedProviderChannelId
                            for channel in (er.canonicalToChannels[canonicalId] ?? []) {
                                guard scopedId == nil || scopedId == channel.id else { continue }
                                guard SourceMatcher.isEligible(channel: channel, for: m) else { continue }
                                var source = RankedSource(channel: channel, score: 100 + Int(join.titleSimilarity * 50))
                                source.evidenceCategories = [.guideListsMatch]
                                source.epgProgramme = join.programme
                                source.canonicalChannelId = canonicalId
                                primarySources.append(source)
                                primaryIds.insert(channel.id)
                            }
                        }
                        primarySources.sort(by: SourceMatcher.ranksBefore)
                        let backups = SourceMatcher.teamNameBackups(match: m, channels: chans, excludeIds: primaryIds)
                        return (m.id, primarySources + backups)
                    }
                }
                for await (id, sources) in group {
                    freshCounts[id] = sources.count
                    freshConfirmedCounts[id] = sources.filter(\.isConfirmed).count
                    if !sources.isEmpty { freshSources[id] = sources }
                }
            }
        }

        guard myGeneration == scanGeneration else { return }

        let evaluatedIds = Set(nonFinal.map(\.id))
        var mergedCounts = countByMatchId.filter { !evaluatedIds.contains($0.key) }
        mergedCounts.merge(freshCounts) { _, new in new }
        countByMatchId = mergedCounts

        var mergedConfirmed = confirmedCountByMatchId.filter { !evaluatedIds.contains($0.key) }
        mergedConfirmed.merge(freshConfirmedCounts) { _, new in new }
        confirmedCountByMatchId = mergedConfirmed

        var mergedSources = sourcesByMatchId.filter { !evaluatedIds.contains($0.key) }
        mergedSources.merge(freshSources) { _, new in new }
        sourcesByMatchId = mergedSources
    }

    func count(for matchId: String) -> Int { countByMatchId[matchId] ?? 0 }

    func confirmedCount(for matchId: String) -> Int { confirmedCountByMatchId[matchId] ?? 0 }

    func topRanked(for matchId: String, limit: Int = 3) -> [RankedSource] {
        Array((sourcesByMatchId[matchId] ?? []).prefix(limit))
    }
}
