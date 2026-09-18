import Foundation
import AVFoundation
import SwiftUI
import Combine
import MediaPlayer
import UIKit

// MARK: - Playback speed

enum PodcastSpeed: Float, CaseIterable, Identifiable {
    case x075 = 0.75, x1 = 1.0, x125 = 1.25, x15 = 1.5, x2 = 2.0
    var id: Float { rawValue }
    var label: String {
        switch self {
        case .x075: return "0.75×"
        case .x1:   return "1×"
        case .x125: return "1.25×"
        case .x15:  return "1.5×"
        case .x2:   return "2×"
        }
    }
}

// MARK: - PodcastStore

@MainActor
final class PodcastStore: ObservableObject {

    // MARK: - Playback state

    @Published private(set) var nowPlaying: PodcastEpisode?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var totalDuration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published var speed: PodcastSpeed = .x1

    // MARK: - Library state

    @Published private(set) var subscribedIDs: Set<String> = []      // podcast IDs (feedURL strings)
    @Published private(set) var episodeProgress: [String: TimeInterval] = [:] // episode id -> seconds
    @Published private(set) var playedEpisodeIDs: Set<String> = []

    // MARK: - Catalog

    @Published private(set) var catalog: [PodcastCatalog.CatalogFeed] = []
    @Published private(set) var teamSeeds: [String: TeamPodcastSeed] = [:] // team seed id -> seed

    // MARK: - Resolved episode cache

    @Published private(set) var episodesByFeed: [String: [PodcastEpisode]] = [:]
    @Published private(set) var loadingFeedIDs: Set<String> = []
    @Published private(set) var podcastMetaCache: [String: Podcast] = [:]  // feedURL -> Podcast

    // MARK: - Private internals

    private var player: AVPlayer?
    @Published private(set) var videoPlayer: AVPlayer?   // non-nil when nowPlaying is a video episode
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var endPlaybackObserver: (any NSObjectProtocol)?
    private var isAppInBackground: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .background
        #else
        return false
        #endif
    }
    private var lastNowPlayingSyncTime: TimeInterval = 0
    private let api = PodcastIndexService.shared
    private let teamResolver = TeamPodcastResolver()

    private let subscribedKey  = "bannertv.podcasts.subscribed.v1"
    private let progressKey    = "bannertv.podcasts.progress.v1"
    private let playedKey      = "bannertv.podcasts.played.v1"

    // MARK: - Init

    init() {
        loadPersistedState()
        loadBundledCatalog()
        setupRemoteCommands()
        prefetchTopArtwork()
        setupAppLifecycleObservers()
    }

    // MARK: - Startup artwork prefetch

    private func prefetchTopArtwork() {
        Task(priority: .background) {
            // Pre-warm URLCache for feeds with artwork URLs already known from catalog
            for feed in catalog.prefix(24) {
                let key = feed.feedURL.absoluteString
                if let artworkURL = podcastMetaCache[key]?.artworkURL {
                    _ = try? await URLSession.shared.data(from: artworkURL)
                }
            }
            // Resolve artwork URLs for the first few catalog feeds that lack them
            for feed in catalog.prefix(12) {
                let key = feed.feedURL.absoluteString
                if podcastMetaCache[key]?.artworkURL == nil {
                    await fetchArtwork(for: feed.feedURL)
                }
            }
        }
    }

    // MARK: - Catalog loading

    private func loadBundledCatalog() {
        var allFeeds: [PodcastCatalog.CatalogFeed] = []
        var seenURLs = Set<String>()

        // Primary curated catalog
        if let url = Bundle.main.url(forResource: "sports_podcast_rss_catalog_v2", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PodcastCatalog.self, from: data) {
            for feed in decoded.feeds where seenURLs.insert(feed.feedURL.absoluteString).inserted {
                allFeeds.append(feed)
            }
        }

        // DB-derived supplemental catalog (higher volume, includes pre-seeded artwork URLs)
        if let url = Bundle.main.url(forResource: "sports_db_catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PodcastCatalog.self, from: data) {
            for feed in decoded.feeds where seenURLs.insert(feed.feedURL.absoluteString).inserted {
                allFeeds.append(feed)
            }
        }

        catalog = allFeeds

        // Pre-seed artwork cache from catalog entries that ship with an image URL
        for feed in catalog {
            guard let imageURL = feed.imageURL else { continue }
            let key = feed.feedURL.absoluteString
            if podcastMetaCache[key] == nil {
                podcastMetaCache[key] = Podcast(
                    id: key, title: feed.title, publisher: feed.author ?? "",
                    feedURL: feed.feedURL, artworkURL: imageURL,
                    podcastDescription: "", sport: feed.sport, tags: feed.tags
                )
            }
        }

        if let url = Bundle.main.url(forResource: "sports_team_podcast_coverage", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(TeamPodcastRegistry.self, from: data) {
            teamSeeds = Dictionary(uniqueKeysWithValues: decoded.teams.map { ($0.id, $0) })
        }
    }

    // MARK: - Catalog queries

    func catalogFeeds(forSport sport: SportGroup) -> [PodcastCatalog.CatalogFeed] {
        let label: String
        switch sport {
        case .football:   label = "American Football"
        case .basketball: label = "Basketball"
        case .baseball:   label = "Baseball"
        case .hockey:     label = "Hockey"
        case .soccer:     label = "Soccer"
        case .tennis:     label = "Tennis"
        case .golf:       label = "Golf"
        case .racing:     label = "Racing"
        case .cycling:    label = "Cycling"
        case .wrestling:  label = "Wrestling"
        case .esports:    label = "Esports"
        }
        return catalog.filter { $0.sport.lowercased() == label.lowercased() }.prefix(20).map { $0 }
    }

    func catalogFeedsForFollowedSports(_ leagues: [League]) -> [PodcastCatalog.CatalogFeed] {
        let groups = Set(leagues.map(\.group))
        var result: [PodcastCatalog.CatalogFeed] = []
        var seenIDs = Set<String>()
        for group in groups {
            for feed in catalogFeeds(forSport: group) {
                if seenIDs.insert(feed.id).inserted { result.append(feed) }
            }
        }
        return Array(result.prefix(24))
    }

    // MARK: - Artwork prefetch

    /// Fetches and caches the artwork URL for a feed without loading full episode data.
    /// Returns immediately if artwork is already available in the catalog or cache.
    func fetchArtwork(for feedURL: URL) async {
        let key = feedURL.absoluteString
        guard podcastMetaCache[key]?.artworkURL == nil else { return }
        guard let feed = try? await api.podcast(forFeedURL: feedURL) else { return }
        guard let artwork = feed.image else { return }
        let existing = podcastMetaCache[key]
        podcastMetaCache[key] = Podcast(
            id: key,
            title: existing?.title ?? feed.title,
            publisher: existing?.publisher ?? (feed.author ?? ""),
            feedURL: feedURL,
            artworkURL: artwork,
            podcastDescription: existing?.podcastDescription ?? (feed.description ?? ""),
            sport: existing?.sport,
            tags: existing?.tags ?? [],
            medium: existing?.medium ?? feed.podcastMedium
        )
    }

    // MARK: - Episode fetching

    func episodes(for podcast: Podcast) -> [PodcastEpisode] {
        if let eps = episodesByFeed[podcast.feedURL.absoluteString], !eps.isEmpty {
            return eps
        }
        if let eps = episodesByFeed[podcast.id], !eps.isEmpty {
            return eps
        }
        return []
    }

    func loadEpisodes(for feedURL: URL) async {
        let key = feedURL.absoluteString
        guard !loadingFeedIDs.contains(key) else { return }
        loadingFeedIDs.insert(key)
        defer { loadingFeedIDs.remove(key) }

        // Try PodcastIndex first
        do {
            let items = try await api.episodes(forFeedURL: feedURL, max: 1000)
            let episodes = items.compactMap { $0.toEpisode() }
            if !episodes.isEmpty {
                episodesByFeed[key] = episodes
                // Enrich podcast metadata if missing or if artwork is missing
                let currentCached = podcastMetaCache[key]
                let foundArt = episodes.first(where: { $0.podcastArtworkURL != nil })?.podcastArtworkURL
                if let foundArt, (currentCached == nil || currentCached?.artworkURL == nil) {
                    if let existing = currentCached {
                        podcastMetaCache[key] = Podcast(
                            id: key, title: existing.title, publisher: existing.publisher,
                            feedURL: feedURL, artworkURL: foundArt,
                            podcastDescription: existing.podcastDescription, sport: existing.sport,
                            tags: existing.tags, medium: existing.medium
                        )
                    } else if let first = episodes.first {
                        podcastMetaCache[key] = Podcast(
                            id: key, title: first.podcastTitle, publisher: "",
                            feedURL: feedURL, artworkURL: foundArt,
                            podcastDescription: "", sport: nil, tags: [],
                            medium: first.medium
                        )
                    }
                }
                return
            }
        } catch {}

        // Fallback: direct RSS fetch + parse
        if let (data, _) = try? await URLSession.shared.data(from: feedURL) {
            let parser = RSSFeedParser(feedURL: feedURL)
            let parsed = parser.parse(data: data)
            episodesByFeed[key] = parsed.episodes
            let currentCached = podcastMetaCache[key]
            if currentCached == nil || currentCached?.artworkURL == nil {
                let resolvedArt = parsed.artworkURL ?? currentCached?.artworkURL
                if let existing = currentCached {
                    podcastMetaCache[key] = Podcast(
                        id: key, title: existing.title.isEmpty ? parsed.podcastTitle : existing.title,
                        publisher: existing.publisher, feedURL: feedURL,
                        artworkURL: resolvedArt, podcastDescription: existing.podcastDescription,
                        sport: existing.sport, tags: existing.tags, medium: existing.medium
                    )
                } else {
                    podcastMetaCache[key] = Podcast(
                        id: key, title: parsed.podcastTitle, publisher: "",
                        feedURL: feedURL, artworkURL: resolvedArt,
                        podcastDescription: "", sport: nil, tags: []
                    )
                }
            }
        }
    }

    /// Resolve team-specific podcasts by running Apple Search and PodcastMatcher in parallel.
    /// Results are merged (Apple Search first as they are more verified) and deduplicated.
    func resolvePodcasts(for team: FavoriteTeam) async -> [Podcast] {
        // Run Apple Search, PodcastIndex Search, and PodcastMatcher concurrently
        async let matcherResult = PodcastMatcher.shared.findPodcasts(for: team, max: 20)
        async let piSearchResult = api.searchPodcasts(query: team.displayName, max: 30)

        var applePodcasts: [Podcast] = []
        let seedID = seedID(for: team)
        let seed = teamSeeds[seedID]
        if let seed {
            let shows = (try? await teamResolver.podcasts(for: seed)) ?? []
            applePodcasts = shows.compactMap { show -> Podcast? in
                guard let feedURL = show.feedUrl else { return nil }
                return Podcast(id: feedURL.absoluteString,
                               title: show.collectionName ?? "Unknown",
                               publisher: show.artistName ?? "",
                               feedURL: feedURL,
                               artworkURL: show.artworkUrl600,
                               podcastDescription: "",
                               sport: seed.sport,
                               tags: [seed.league.lowercased(), team.displayName.lowercased()])
            }
        }

        let matcherPodcasts = await matcherResult
        let piFeeds = (try? await piSearchResult) ?? []
        let teamLower = team.displayName.lowercased()
        let aliases = seed?.aliases ?? [team.abbreviation]
        let piPodcasts = piFeeds.filter { feed in
            let text = (feed.title + " " + (feed.author ?? "") + " " + (feed.description ?? "")).lowercased()
            return text.contains(teamLower) || aliases.contains { !$0.isEmpty && $0.count >= 3 && text.contains($0.lowercased()) }
        }.map { $0.toPodcast() }

        // Local catalog feeds matching team
        let catalogMatches = catalog.filter { feed in
            feed.tags.contains { $0.lowercased().contains(teamLower) } ||
            feed.title.localizedCaseInsensitiveContains(teamLower)
        }.map { $0.toPodcast(cachedMeta: podcastMetaCache[$0.feedURL.absoluteString]) }

        // Merge in order: Apple Search -> Curated Catalog -> PodcastIndex -> Matcher
        var seen = Set<String>()
        var merged: [Podcast] = []
        for podcast in applePodcasts + catalogMatches + piPodcasts + matcherPodcasts {
            if seen.insert(podcast.id).inserted {
                if podcastMetaCache[podcast.id] == nil {
                    podcastMetaCache[podcast.id] = podcast
                }
                merged.append(podcast)
            }
        }
        return merged
    }

    private func seedID(for team: FavoriteTeam) -> String {
        let leaguePart: String
        switch team.leaguePath {
        case "hockey/nhl":       leaguePart = "nhl"
        case "basketball/nba":   leaguePart = "nba"
        case "baseball/mlb":     leaguePart = "mlb"
        case "football/nfl":     leaguePart = "nfl"
        case "soccer/usa.1":     leaguePart = "mls"
        default:                 leaguePart = team.leaguePath.components(separatedBy: "/").last ?? ""
        }
        let namePart = team.displayName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
        return "\(leaguePart)-\(namePart)"
    }

    // MARK: - PodcastIndex search

    func search(query: String) async -> [Podcast] {
        do {
            let feeds = try await api.searchPodcasts(query: query)
            return feeds.map { $0.toPodcast() }
        } catch {
            return []
        }
    }

    // MARK: - Subscription management

    func isSubscribed(_ podcast: Podcast) -> Bool { subscribedIDs.contains(podcast.id) }

    func toggleSubscription(_ podcast: Podcast) {
        if subscribedIDs.contains(podcast.id) {
            subscribedIDs.remove(podcast.id)
        } else {
            subscribedIDs.insert(podcast.id)
            podcastMetaCache[podcast.id] = podcast
        }
        persistState()
    }

    // MARK: - Playback

    func play(_ episode: PodcastEpisode) {
        configureAudioSession()
        teardownPlayer()

        let item = AVPlayerItem(url: episode.audioURL)
        player = AVPlayer(playerItem: item)
        player?.volume = 1.0
        player?.isMuted = false
        player?.automaticallyWaitsToMinimizeStalling = true
        player?.rate = speed.rawValue
        nowPlaying = episode
        totalDuration = episode.duration > 0 ? episode.duration : 0
        currentTime = episodeProgress[episode.id] ?? 0
        isPlaying = true
        videoPlayer = episode.isVideo ? player : nil

        if currentTime > 0 {
            player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
        }
        player?.play()
        player?.rate = speed.rawValue

        setupObservers()
        configureNowPlaying(for: episode)
    }

    func togglePlayPause() {
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            saveProgress()
        } else {
            player?.play()
            player?.rate = speed.rawValue
            isPlaying = true
        }
        updateNowPlayingPlayback()
    }

    func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlayingPlayback()
    }

    func skip(seconds: TimeInterval) {
        let target = max(0, currentTime + seconds)
        seek(to: target)
    }

    func setSpeed(_ newSpeed: PodcastSpeed) {
        speed = newSpeed
        if isPlaying { player?.rate = newSpeed.rawValue }
        updateNowPlayingPlayback()
    }

    func markPlayed(_ episode: PodcastEpisode) {
        playedEpisodeIDs.insert(episode.id)
        episodeProgress[episode.id] = episode.duration
        persistState()
    }

    func markUnplayed(_ episode: PodcastEpisode) {
        playedEpisodeIDs.remove(episode.id)
        episodeProgress.removeValue(forKey: episode.id)
        persistState()
    }

    func remainingTimeFormatted(for episode: PodcastEpisode) -> String? {
        if isPlayed(episode) { return "Played" }
        guard episode.duration > 0 else { return nil }
        let current = (nowPlaying?.id == episode.id) ? currentTime : (episodeProgress[episode.id] ?? 0)
        guard current > 0 else { return nil }
        let remaining = max(0, episode.duration - current)
        let m = Int(remaining) / 60
        let h = m / 60
        if h > 0 {
            return "\(h)h \(m % 60)m left"
        } else {
            return "\(max(1, m))m left"
        }
    }

    func isPlayed(_ episode: PodcastEpisode) -> Bool {
        playedEpisodeIDs.contains(episode.id)
    }

    func progressFraction(for episode: PodcastEpisode) -> Double {
        guard episode.duration > 0 else { return 0 }
        return min(1, (episodeProgress[episode.id] ?? 0) / episode.duration)
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            print("[PodcastStore] AudioSession setup error: \(error)")
        }
    }

    // MARK: - Player observers & Background Power Optimization

    private func setupObservers() {
        guard let player else { return }

        resetTimeObserver(interval: isAppInBackground ? 30.0 : 0.5)

        statusObserver = player.currentItem?.observe(\.status) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.isBuffering = item.status == .unknown
                if item.status == .failed { self?.isPlaying = false }
            }
        }

        rateObserver = player.observe(\.rate) { [weak self] p, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = p.rate > 0
                if p.rate == 0 { self?.saveProgress() }
            }
        }

        if let obs = endPlaybackObserver {
            NotificationCenter.default.removeObserver(obs)
            endPlaybackObserver = nil
        }
        endPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let ep = self?.nowPlaying { self?.markPlayed(ep) }
                self?.isPlaying = false
                self?.updateNowPlayingPlayback()
            }
        }
    }

    private func resetTimeObserver(interval: TimeInterval) {
        guard let player else { return }
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let t = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard t.isFinite && t >= 0 else { return }

                if self.isAppInBackground {
                    // When backgrounded: avoid invalidating SwiftUI state every 500ms since no UI is rendered.
                    // Instead, save progress periodically to preserve exact state on system termination.
                    self.saveProgress()
                    return
                }

                self.currentTime = t
                if let dur = self.player?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.totalDuration = dur
                }

                // Apple Developer Documentation: MPNowPlayingInfoCenter does NOT need continuous updates
                // on each tick because iOS automatically calculates elapsed time using playbackRate.
                // Frequent IPC writes wake up the CPU and mediaserverd, drastically draining battery.
                // We only sync periodically (every 60s) to reconcile minute clock drift.
                if self.totalDuration > 0 && abs(t - self.lastNowPlayingSyncTime) >= 60.0 {
                    self.lastNowPlayingSyncTime = t
                    self.tickNowPlayingTime(t)
                }
            }
        }
    }

    // MARK: - App Lifecycle Power Management

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidEnterBackground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillEnterForeground()
            }
        }
    }

    private func handleDidEnterBackground() {
        saveProgress()
        if nowPlaying?.isVideo == true {
            setVideoTracksEnabled(false)
        }
        resetTimeObserver(interval: 30.0)
    }

    private func handleWillEnterForeground() {
        if nowPlaying?.isVideo == true {
            setVideoTracksEnabled(true)
        }
        if let t = player?.currentTime().seconds, t.isFinite, t >= 0 {
            currentTime = t
        }
        resetTimeObserver(interval: 0.5)
    }

    private func setVideoTracksEnabled(_ enabled: Bool) {
        guard nowPlaying?.isVideo == true, let tracks = player?.currentItem?.tracks else { return }
        for track in tracks where track.assetTrack?.mediaType == .video {
            track.isEnabled = enabled
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken, let p = player {
            p.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let obs = endPlaybackObserver {
            NotificationCenter.default.removeObserver(obs)
            endPlaybackObserver = nil
        }
        statusObserver?.invalidate(); statusObserver = nil
        rateObserver?.invalidate(); rateObserver = nil
        player?.pause()
        player = nil
        videoPlayer = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func saveProgress() {
        guard let episode = nowPlaying, currentTime > 0 else { return }
        episodeProgress[episode.id] = currentTime
        persistState()
    }

    // MARK: - Now Playing info (lock screen / Control Center / Dynamic Island)

    private func configureNowPlaying(for episode: PodcastEpisode) {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcastTitle,
            MPMediaItemPropertyAlbumTitle: episode.podcastTitle,
            MPMediaItemPropertyPlaybackDuration: episode.duration > 0 ? episode.duration : 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: Double(speed.rawValue),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing

        // Fetch artwork asynchronously and update once loaded
        if let artworkURL = episode.podcastArtworkURL {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: artworkURL),
                      let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                guard var current = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                current[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    private func updateNowPlayingPlayback() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speed.rawValue) : 0.0
        if totalDuration > 0 { info[MPMediaItemPropertyPlaybackDuration] = totalDuration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func tickNowPlayingTime(_ time: TimeInterval) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        if totalDuration > 0 { info[MPMediaItemPropertyPlaybackDuration] = totalDuration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.skip(seconds: e.interval) }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.skip(seconds: -e.interval) }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    // MARK: - Persistence

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(Array(subscribedIDs), forKey: subscribedKey)
        if let data = try? JSONEncoder().encode(episodeProgress) { defaults.set(data, forKey: progressKey) }
        defaults.set(Array(playedEpisodeIDs), forKey: playedKey)
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: podcastMetaCache.map { ($0.key, $0.value) })) {
            defaults.set(data, forKey: "bannertv.podcasts.meta.v1")
        }
    }

    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        subscribedIDs = Set(defaults.stringArray(forKey: subscribedKey) ?? [])
        playedEpisodeIDs = Set(defaults.stringArray(forKey: playedKey) ?? [])
        if let data = defaults.data(forKey: progressKey),
           let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
            episodeProgress = decoded
        }
        if let data = defaults.data(forKey: "bannertv.podcasts.meta.v1"),
           let decoded = try? JSONDecoder().decode([String: Podcast].self, from: data) {
            podcastMetaCache = decoded
        }
    }
}
