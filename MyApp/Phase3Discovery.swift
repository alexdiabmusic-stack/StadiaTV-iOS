import Foundation

/// Pure, portable inventory policies. Metadata never establishes playback availability.
nonisolated enum EntertainmentDiscovery {
    static func state(_ item: EntertainmentItem, progress: [String: EntertainmentProgress]) -> EntertainmentProgress? {
        progress[item.progressID] ?? progress[item.id]
    }

    static func nextEpisode(seriesID: String, episodes: [EntertainmentItem],
                            progress: [String: EntertainmentProgress], now: Date = Date()) -> EntertainmentItem? {
        let today = String(now.ISO8601Format().prefix(10))
        func available(_ item: EntertainmentItem) -> Bool {
            guard item.isPlayable else { return false }
            if let airDate = item.airDate, airDate.count == 10, airDate > today { return false }
            return true
        }
        let regular = episodes.filter {
            $0.seriesID == seriesID && ($0.seasonNumber ?? 0) > 0 && ($0.episodeNumber ?? 0) > 0
        }.sorted {
            ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0, $0.id) <
            ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0, $1.id)
        }
        let latest = regular.filter { state($0, progress: progress) != nil }.max {
            (state($0, progress: progress)?.lastWatched ?? .distantPast) <
            (state($1, progress: progress)?.lastWatched ?? .distantPast)
        }
        if let latest, let state = state(latest, progress: progress), !state.completed {
            // Never skip an unfinished episode simply because its source is offline.
            return available(latest) ? latest : nil
        }
        return regular.first { candidate in
            guard available(candidate), state(candidate, progress: progress)?.completed != true else { return false }
            guard let latest else { return true }
            return (candidate.seasonNumber ?? 0, candidate.episodeNumber ?? 0) >
                   (latest.seasonNumber ?? 0, latest.episodeNumber ?? 0)
        }
    }

    static func continuing(items: [EntertainmentItem], progress: [String: EntertainmentProgress]) -> [EntertainmentItem] {
        var seen = Set<String>()
        return items.filter {
            guard let value = state($0, progress: progress) else { return false }
            return $0.isPlayable && !value.completed && value.position > 0 && seen.insert($0.progressID).inserted
        }.sorted {
            let lhs = state($0, progress: progress)?.lastWatched ?? .distantPast
            let rhs = state($1, progress: progress)?.lastWatched ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    static func recommendations(items: [EntertainmentItem], kind: EntertainmentKind,
                                progress: [String: EntertainmentProgress], watchlist: Set<String>,
                                excluding: Set<String> = [], limit: Int = 12) -> [EntertainmentItem] {
        let signals = items.filter { state($0, progress: progress) != nil || watchlist.contains($0.id) }
        let genres = Set(signals.flatMap { $0.metadata.genres })
        func score(_ item: EntertainmentItem) -> Int {
            item.metadata.genres.filter { genres.contains($0) }.count * 2 + (watchlist.contains(item.id) ? 3 : 0)
        }
        var seen = Set<String>()
        return Array(items.filter {
            $0.kind == kind && !excluding.contains($0.id) &&
            ($0.isPlayable || ($0.kind == .series && $0.sources.contains { $0.availability == .available })) &&
            state($0, progress: progress) == nil && seen.insert($0.progressID).inserted
        }.sorted {
            let a = score($0), b = score($1)
            if a != b { return a > b }
            if $0.addedAt != $1.addedAt { return ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            return $0.id < $1.id
        }.prefix(limit))
    }

    static func search(_ items: [EntertainmentItem], query: String, kind: EntertainmentKind? = nil) -> [EntertainmentItem] {
        let key = EntertainmentMatching.normalized(query)
        guard !key.isEmpty else { return [] }
        func rank(_ item: EntertainmentItem) -> Int {
            let title = EntertainmentMatching.normalized(item.title)
            return (title == key ? 100 : title.hasPrefix(key) ? 50 : 0) + (item.isPlayable ? 10 : 0)
        }
        return Array(items.filter {
            (kind == nil || $0.kind == kind) && EntertainmentMatching.normalized($0.title).contains(key)
        }.sorted {
            let a = rank($0), b = rank($1)
            return a == b ? $0.id < $1.id : a > b
        }.prefix(100))
    }
}
