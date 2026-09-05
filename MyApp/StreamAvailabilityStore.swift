import Foundation
import Combine

/// Shared store of per-match stream counts, populated by scanning playlist channels
/// against `SourceMatcher`. Multiple views (Following, Live, Home, tvOS) write into
/// the same dict so any surface can read counts without re-running the scan.
@MainActor
final class StreamAvailabilityStore: ObservableObject {

    /// Number of playlist channels that pass the minimum relevance threshold, keyed by match ID.
    /// 0 means scan ran but found no streams; absent means scan has not yet run for that match.
    @Published private(set) var countByMatchId: [String: Int] = [:]

    /// Full ranked source list from the last scan, keyed by match ID.
    /// Used by QuickStreamSheet to show channel names without re-running the scan.
    @Published private(set) var sourcesByMatchId: [String: [RankedSource]] = [:]

    /// Monotonically-increasing generation counter. Incremented at the start of every scan so
    /// a stale concurrent scan cannot overwrite results from a newer one.
    private var scanGeneration: Int = 0

    /// Ranks `matches` against `channels` on utility-priority background tasks, writes explicit
    /// zero counts for every evaluated match, and removes entries for final matches.
    func scan(matches: [Match], channels: [Channel], preferredLanguages: Set<String>) async {
        let nonFinal = matches.filter { $0.state != .final }
        let finalIds = Set(matches.filter { $0.state == .final }.map(\.id))

        // Always remove stale entries for matches that are now final.
        if !finalIds.isEmpty {
            countByMatchId = countByMatchId.filter { !finalIds.contains($0.key) }
            sourcesByMatchId = sourcesByMatchId.filter { !finalIds.contains($0.key) }
        }

        guard !nonFinal.isEmpty else { return }

        // Capture generation before any suspension point so we can detect a newer scan later.
        scanGeneration += 1
        let myGeneration = scanGeneration

        // Pre-populate with zeros — every evaluated match gets an explicit result.
        var freshCounts: [String: Int] = Dictionary(uniqueKeysWithValues: nonFinal.map { ($0.id, 0) })
        var freshSources: [String: [RankedSource]] = [:]

        if !channels.isEmpty {
            await withTaskGroup(of: (String, [RankedSource]).self) { group in
                for match in nonFinal {
                    let m = match
                    group.addTask(priority: .utility) {
                        let ranked = SourceMatcher.rank(
                            match: m,
                            channels: channels,
                            preferredLanguages: preferredLanguages
                        )
                        return (m.id, ranked)
                    }
                }
                for await (id, sources) in group {
                    freshCounts[id] = sources.count
                    if !sources.isEmpty { freshSources[id] = sources }
                }
            }
        }

        // Discard results if a newer scan has already started.
        guard myGeneration == scanGeneration else { return }

        // Overwrite all entries for the evaluated set; preserve unrelated entries.
        let evaluatedIds = Set(nonFinal.map(\.id))
        var mergedCounts = countByMatchId.filter { !evaluatedIds.contains($0.key) }
        mergedCounts.merge(freshCounts) { _, new in new }
        countByMatchId = mergedCounts

        var mergedSources = sourcesByMatchId.filter { !evaluatedIds.contains($0.key) }
        mergedSources.merge(freshSources) { _, new in new }
        sourcesByMatchId = mergedSources
    }

    func count(for matchId: String) -> Int { countByMatchId[matchId] ?? 0 }

    func topRanked(for matchId: String, limit: Int = 3) -> [RankedSource] {
        Array((sourcesByMatchId[matchId] ?? []).prefix(limit))
    }
}
