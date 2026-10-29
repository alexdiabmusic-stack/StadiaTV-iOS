import Foundation
import Observation
import CryptoKit

private actor EntertainmentDiskCache {
    struct Snapshot: Codable, Sendable {
        var version = 1
        var items: [EntertainmentItem]
        var seasons: [String: [EntertainmentSeason]]
        var refreshed: [String: Date]
    }
    private var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("banner-entertainment-v1.json")
    }
    func read() -> Snapshot? {
        guard let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 30_000_000, let data = try? Data(contentsOf: file),
              let result = try? JSONDecoder().decode(Snapshot.self, from: data), result.version == 1 else { return nil }
        return result
    }
    func write(_ snapshot: Snapshot) {
        guard let file, let data = try? JSONEncoder().encode(snapshot), data.count <= 30_000_000 else { return }
        try? data.write(to: file, options: .atomic)
    }
}

@MainActor @Observable
final class EntertainmentRepository {
    static let shared = EntertainmentRepository()
    private(set) var items: [EntertainmentItem] = [] {
        didSet { catalog = Self.canonicalPresentation(items) }
    }
    private(set) var catalog: [EntertainmentItem] = []
    private(set) var seasonsBySeries: [String: [EntertainmentSeason]] = [:]
    private(set) var isRefreshing = false
    private(set) var sourceErrors: [UUID: String] = [:]
    private(set) var progress: [String: EntertainmentProgress] = [:]
    private(set) var watchlist: Set<String> = []
    private(set) var savedWatchlistItems: [String: EntertainmentItem] = [:]
    private(set) var savedHistoryItems: [String: EntertainmentItem] = [:]
    private(set) var revision = 0
    private(set) var userStateRevision = 0
    private(set) var hiddenContinueWatching: Set<String> = []
    private var refreshed: [String: Date] = [:]
    private var attempted: [String: Date] = [:]
    private var loaded = false
    private let disk = EntertainmentDiskCache()
    private let defaults: UserDefaults
    private let metadata: any EntertainmentMetadataProvider
    private var detailRequests: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard, metadata: any EntertainmentMetadataProvider = TMDBMetadataService.shared) {
        self.defaults = defaults
        self.metadata = metadata
        if let data = defaults.data(forKey: "banner.entertainment.progress.v1") {
            progress = (try? JSONDecoder().decode([String: EntertainmentProgress].self, from: data)) ?? [:]
        }
        if let data = defaults.data(forKey: "banner.entertainment.historyItems.v1"),
           let saved = try? JSONDecoder().decode([String: EntertainmentItem].self, from: data) {
            savedHistoryItems = saved
        }
        hiddenContinueWatching = Set(defaults.stringArray(forKey: "banner.entertainment.hiddenContinue.v1") ?? [])
        watchlist = Set(defaults.stringArray(forKey: "banner.entertainment.watchlist.v1") ?? [])
        if let data = defaults.data(forKey: "banner.entertainment.watchlistItems.v1"),
           let saved = try? JSONDecoder().decode([String: EntertainmentItem].self, from: data) {
            savedWatchlistItems = saved
        }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let snapshot = await disk.read() {
            items = snapshot.items
            seasonsBySeries = snapshot.seasons
            refreshed = snapshot.refreshed
            revision += 1
        }
    }

    func sync(playlists: [Playlist], channels: [Channel], force: Bool = false) async {
        await load()
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Retain legacy history presentation before refreshed inventory can evict it.
        for item in catalog + seasonsBySeries.values.flatMap({ $0.flatMap(\.episodes) })
            where watchProgress(for: item) != nil { retainHistoryItem(item, persist: false) }
        persistHistoryItems()
        // Capture legacy saved titles before a source refresh can evict them.
        for item in catalog where watchlist.contains(item.id) { savedWatchlistItems[item.id] = item }
        persistWatchlistItems()
        let configuredIDs = Set(playlists.map(\.id))
        items.removeAll { $0.sources.allSatisfy { !configuredIDs.contains($0.sourceID) } }
        sourceErrors = sourceErrors.filter { configuredIDs.contains($0.key) }
        if force { sourceErrors.removeAll() }
        for playlist in playlists {
            guard !Task.isCancelled else { break }
            if playlist.kind == .m3u {
                let entries = channels.filter { $0.playlistID == playlist.id }
                let imported = await Task.detached(priority: .utility) { Self.classifyM3U(entries) }.value
                let shows = await Task.detached(priority: .utility) { Self.classifyM3USeries(entries) }.value
                replace(imported + shows.items, sourceID: playlist.id, kind: nil)
                for (id, seasons) in shows.seasons { seasonsBySeries[id] = seasons }
                continue
            }
            let adapter = XtreamEntertainmentAdapter(playlist: playlist)
            for kind in [EntertainmentKind.movie, .series] {
                let key = "\(playlist.id):\(kind.rawValue)"
                if !force, let date = attempted[key], Date().timeIntervalSince(date) < 300 { continue }
                if !force, let date = refreshed[key], Date().timeIntervalSince(date) < 12 * 3600 { continue }
                do {
                    attempted[key] = Date()
                    let incoming = try await adapter.inventory(kind: kind)
                    try Task.checkCancellation()
                    replace(incoming, sourceID: playlist.id, kind: kind)
                    refreshed[key] = Date()
                } catch is CancellationError { break }
                catch {
                    sourceErrors[playlist.id] = (error as? EntertainmentError)?.localizedDescription ?? EntertainmentError.unavailable.localizedDescription
                    markUnknown(sourceID: playlist.id, kind: kind)
                }
            }
        }
        let seriesIDs = Set(items.filter { $0.kind == .series }.map(\.id))
        seasonsBySeries = seasonsBySeries.filter { seriesIDs.contains($0.key) }
        revision += 1
        await persist()
    }

    private func replace(_ incoming: [EntertainmentItem], sourceID: UUID, kind: EntertainmentKind?) {
        let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items.removeAll { item in
            item.sources.contains { $0.sourceID == sourceID } && (kind == nil || item.kind == kind)
        }
        items.append(contentsOf: incoming.map { item in
            var item = item
            if let old = previous[item.id], old.metadata.confidence != .unmatched,
               old.providerTitle == item.providerTitle { item.metadata = old.metadata }
            return item
        })
        revision += 1
    }

    private func markUnknown(sourceID: UUID, kind: EntertainmentKind) {
        if kind == .series {
            for id in Array(seasonsBySeries.keys) {
                seasonsBySeries[id] = seasonsBySeries[id]?.map { season in
                    var season = season
                    season.episodes = season.episodes.map { episode in
                        var episode = episode
                        episode.sources = episode.sources.map { source in
                            var source = source
                            if source.sourceID == sourceID { source.availability = .unknown }
                            return source
                        }
                        return episode
                    }
                    return season
                }
            }
        }
        for index in items.indices where items[index].kind == kind {
            for source in items[index].sources.indices where items[index].sources[source].sourceID == sourceID {
                items[index].sources[source].availability = .unknown
            }
        }
    }

    func detail(_ item: EntertainmentItem, playlists: [Playlist]) async {
        if let task = detailRequests[item.id] { await task.value; return }
        let task = Task { await self.loadDetail(item, playlists: playlists) }
        detailRequests[item.id] = task
        await task.value
        detailRequests[item.id] = nil
    }

    private func loadDetail(_ item: EntertainmentItem, playlists: [Playlist]) async {
        // Episode identity is enriched through its validated series/season mapping only.
        guard item.kind != .episode else { return }
        guard let source = item.sources.first, let playlist = playlists.first(where: { $0.id == source.sourceID }) else { return }
        var updated = item
        if playlist.kind == .xtream {
            let adapter = XtreamEntertainmentAdapter(playlist: playlist)
            if item.kind == .movie, let provider = try? await adapter.movieDetails(item) {
                updated.metadata = Self.merging(provider.metadata, fallback: updated.metadata)
                updated.sources = provider.sources
            }
            if item.kind == .series {
                do {
                    let detail = try await adapter.seriesDetails(item)
                    updated.metadata = Self.merging(detail.metadata, fallback: updated.metadata)
                    seasonsBySeries[item.id] = detail.seasons
                    sourceErrors[playlist.id] = nil
                } catch {
                    sourceErrors[playlist.id] = EntertainmentError.unavailable.localizedDescription
                    // Never leave cached episodes marked available after a failed availability refresh.
                    seasonsBySeries[item.id] = seasonsBySeries[item.id]?.map { season in
                        var season = season
                        season.episodes = season.episodes.map { episode in
                            var episode = episode
                            episode.sources = episode.sources.map { var source = $0; source.availability = .unknown; return source }
                            return episode
                        }
                        return season
                    }
                }
            }
        }
        let language = Locale.current.language.languageCode?.identifier == "fr" ? "fr-CA" : "en-CA"
        if let enriched = try? await metadata.enrich(updated, language: language) {
            updated.metadata = Self.merging(enriched, fallback: updated.metadata)
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let ownIDs = Set(items[index].sources.map(\.id))
            updated.sources = updated.sources.filter { ownIDs.contains($0.id) }
            items[index] = updated
        }
        revision += 1
        await persist()
    }

    func enrichSeason(_ season: EntertainmentSeason, series: EntertainmentItem) async {
        guard let id = series.metadata.tmdbID,
              [.verifiedIdentifier, .highConfidence].contains(series.metadata.confidence) else { return }
        let language = Locale.current.language.languageCode?.identifier == "fr" ? "fr-CA" : "en-CA"
        if let enriched = try? await metadata.enrichSeason(season, seriesTMDBID: id, language: language),
           let index = seasonsBySeries[series.id]?.firstIndex(where: { $0.id == season.id }) {
            seasonsBySeries[series.id]?[index] = enriched
            revision += 1
            await persist()
        }
    }

    func channel(for item: EntertainmentItem, source: EntertainmentSource, playlists: [Playlist], channels: [Channel]) async throws -> Channel {
        guard item.isPlayable, source.availability == .available,
              let playlist = playlists.first(where: { $0.id == source.sourceID }) else { throw EntertainmentError.unavailable }
        if playlist.kind == .m3u {
            guard let channel = channels.first(where: { $0.id == source.itemID && $0.playlistID == source.sourceID }) else { throw EntertainmentError.unavailable }
            return channel
        }
        let url = try await XtreamEntertainmentAdapter(playlist: playlist).resolve(source)
        return Channel(id: source.id, name: item.title, streamURL: url, logoURL: item.metadata.poster,
                       group: source.category, playlistID: playlist.id, playlistName: playlist.name,
                       httpHeaders: playlist.userAgent.map { ["User-Agent": $0] })
    }

    func watchProgress(for item: EntertainmentItem) -> EntertainmentProgress? {
        progress[item.progressID] ?? progress[item.id]
    }

    func record(_ value: EntertainmentProgress, item: EntertainmentItem? = nil) {
        if let item { retainHistoryItem(item) }
        userStateRevision += 1
        progress[value.contentID] = value
        if hiddenContinueWatching.remove(value.contentID) != nil {
            defaults.set(Array(hiddenContinueWatching), forKey: "banner.entertainment.hiddenContinue.v1")
        }
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: "banner.entertainment.progress.v1") }
    }

    func toggleWatchlist(_ id: String) {
        userStateRevision += 1
        if let item = item(for: id) { savedWatchlistItems[id] = item }
        if watchlist.contains(id) { watchlist.remove(id) } else { watchlist.insert(id) }
        defaults.set(Array(watchlist), forKey: "banner.entertainment.watchlist.v1")
        savedWatchlistItems = savedWatchlistItems.filter { watchlist.contains($0.key) }
        persistWatchlistItems()
    }

    func hideFromContinueWatching(_ item: EntertainmentItem) {
        userStateRevision += 1
        hiddenContinueWatching.insert(item.progressID)
        defaults.set(Array(hiddenContinueWatching), forKey: "banner.entertainment.hiddenContinue.v1")
    }

    func markWatched(_ item: EntertainmentItem) {
        let previous = watchProgress(for: item)
        record(EntertainmentProgress(contentID: item.progressID,
            sourceVariantID: previous?.sourceVariantID ?? item.sources.first?.id ?? "",
            position: previous?.duration ?? previous?.position ?? 0, duration: previous?.duration,
            lastWatched: Date(), completed: true), item: item)
    }

    func removeProgress(for item: EntertainmentItem) {
        userStateRevision += 1
        progress[item.progressID] = nil
        progress[item.id] = nil
        savedHistoryItems[item.progressID] = nil
        savedHistoryItems[item.id] = nil
        persistHistoryItems()
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: "banner.entertainment.progress.v1") }
    }

    func item(for id: String) -> EntertainmentItem? {
        if let item = catalog.first(where: { $0.id == id || $0.sources.contains { $0.id == id } }) { return item }
        if let episode = seasonsBySeries.values.lazy.flatMap({ $0 }).lazy.flatMap({ $0.episodes }).first(where: { $0.id == id }) { return episode }
        guard var saved = savedWatchlistItems[id] ?? savedHistoryItems[id] ?? savedHistoryItems.values.first(where: { $0.id == id }) else { return nil }
        saved.sources = saved.sources.map { var source = $0; source.availability = .unavailable; return source }
        return saved
    }

    nonisolated static func canonicalPresentation(_ items: [EntertainmentItem]) -> [EntertainmentItem] {
        var result: [EntertainmentItem] = []
        var index: [String: Int] = [:]
        for item in items {
            guard let tmdb = item.metadata.tmdbID,
                  [.verifiedIdentifier, .highConfidence].contains(item.metadata.confidence) else {
                result.append(item); continue
            }
            // Keep cuts and provider title variants separate unless both title and verified identity agree.
            let key = "\(item.kind.rawValue):\(tmdb):\(EntertainmentMatching.normalized(item.providerTitle))"
            if let position = index[key] {
                let known = Set(result[position].sources.map(\.id))
                result[position].sources.append(contentsOf: item.sources.filter { !known.contains($0.id) })
            } else { index[key] = result.count; result.append(item) }
        }
        return result
    }

    private func retainHistoryItem(_ item: EntertainmentItem, persist: Bool = true) {
        guard watchProgress(for: item) != nil || item.kind != .series else { return }
        guard savedHistoryItems[item.progressID] != item else { return }
        savedHistoryItems[item.progressID] = item
        if persist { persistHistoryItems() }
    }

    private func persistHistoryItems() {
        if let data = try? JSONEncoder().encode(savedHistoryItems) {
            defaults.set(data, forKey: "banner.entertainment.historyItems.v1")
        }
    }

    private func persistWatchlistItems() {
        if let data = try? JSONEncoder().encode(savedWatchlistItems) {
            defaults.set(data, forKey: "banner.entertainment.watchlistItems.v1")
        }
    }

    private func persist() async {
        for item in catalog where watchlist.contains(item.id) { savedWatchlistItems[item.id] = item }
        persistWatchlistItems()
        await disk.write(.init(items: items, seasons: seasonsBySeries, refreshed: refreshed))
    }

    nonisolated static func merging(_ metadata: EntertainmentMetadata, fallback: EntertainmentMetadata) -> EntertainmentMetadata {
        var result = metadata
        result.poster = result.poster ?? fallback.poster
        result.backdrop = result.backdrop ?? fallback.backdrop
        result.overview = result.overview ?? fallback.overview
        result.year = result.year ?? fallback.year
        result.tmdbID = result.tmdbID ?? fallback.tmdbID
        result.imdbID = result.imdbID ?? fallback.imdbID
        if result.genres.isEmpty { result.genres = fallback.genres }
        if result.cast.isEmpty { result.cast = fallback.cast }
        return result
    }

    nonisolated static func classifyM3USeries(_ channels: [Channel]) -> (items: [EntertainmentItem], seasons: [String: [EntertainmentSeason]]) {
        var series: [String: EntertainmentItem] = [:]
        var episodes: [String: [EntertainmentItem]] = [:]
        for channel in channels {
            let group = EntertainmentMatching.normalized(channel.group ?? "")
            guard ["series", "tv shows", "tv series", "shows"].contains(group),
                  ["mp4", "m4v", "mkv", "mov", "avi"].contains(channel.streamURL.pathExtension.lowercased()),
                  let numbers = EntertainmentMatching.episodeNumbers(channel.name),
                  let marker = channel.name.range(of: #"(?i)\b(?:S\d{1,2}E\d{1,3}|Season\s+\d{1,2}\s+Episode\s+\d{1,3})\b"#, options: .regularExpression) else { continue }
            let title = String(channel.name[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            // Provider-scoped exact stem: this is organization, never an external metadata identity.
            let digest = SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = "m3u-series:\(channel.playlistID):\(digest)"
            let source = EntertainmentSource(sourceID: channel.playlistID, itemID: channel.id, kind: .episode,
                container: channel.streamURL.pathExtension, category: channel.group)
            var episode = EntertainmentItem(id: source.id, kind: .episode, providerTitle: channel.name,
                sources: [source], seriesID: id, seasonNumber: numbers.season, episodeNumber: numbers.episode)
            episode.metadata.poster = XtreamEntertainmentAdapter.safeArtwork(channel.logoURL?.absoluteString)
            episodes[id, default: []].append(episode)
            if series[id] == nil {
                let reference = EntertainmentSource(sourceID: channel.playlistID, itemID: digest, kind: .series, category: channel.group)
                series[id] = EntertainmentItem(id: id, kind: .series, providerTitle: title, sources: [reference])
            }
        }
        var seasons: [String: [EntertainmentSeason]] = [:]
        for (id, entries) in episodes {
            seasons[id] = Dictionary(grouping: entries, by: { $0.seasonNumber ?? 0 }).map { number, values in
                EntertainmentSeason(seriesID: id, number: number, episodes: values.sorted {
                    ($0.episodeNumber ?? Int.max, $0.id) < ($1.episodeNumber ?? Int.max, $1.id)
                })
            }.sorted { $0.number < $1.number }
        }
        return (series.values.sorted { $0.id < $1.id }, seasons)
    }

    nonisolated static func classifyM3U(_ channels: [Channel]) -> [EntertainmentItem] {
        // Existing live inventory remains untouched, including all ambiguous entries.
        channels.compactMap { channel in
            guard ["mp4", "m4v", "mkv", "mov", "avi"].contains(channel.streamURL.pathExtension.lowercased()) else { return nil }
            let group = EntertainmentMatching.normalized(channel.group ?? "")
            guard ["movie", "movies", "film", "films", "vod"].contains(group),
                  EntertainmentMatching.episodeNumbers(channel.name) == nil else { return nil }
            let source = EntertainmentSource(sourceID: channel.playlistID, itemID: channel.id, kind: .movie,
                container: channel.streamURL.pathExtension, category: channel.group)
            var item = EntertainmentItem(id: source.id, kind: .movie, providerTitle: channel.name, sources: [source])
            item.metadata.poster = XtreamEntertainmentAdapter.safeArtwork(channel.logoURL?.absoluteString)
            return item
        }
    }
}
