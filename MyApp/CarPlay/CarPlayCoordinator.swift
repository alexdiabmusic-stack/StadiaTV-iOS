#if canImport(CarPlay)
import CarPlay
import Foundation
import UIKit

/// Presents shared sports, podcast and playback services through native audio templates.
@MainActor
final class CarPlayCoordinator: NSObject, CPNowPlayingTemplateObserver {
    private let interfaceController: CPInterfaceController
    private let env = BannerAppEnvironment.shared
    private let playback = CarPlayPlaybackCoordinator.shared
    private var forYouTemplate: CPListTemplate?
    private var liveTemplate: CPListTemplate?
    private var listenTemplate: CPListTemplate?
    private var moreTemplate: CPListTemplate?
    private var snapshot: SportsLiveMatchSnapshot?
    private var refreshTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private var navigationTasks: [UUID: Task<Void, Never>] = [:]
    private var teamPodcasts: [Podcast] = []
    private var connected = false
    private var renderSignatures: [ObjectIdentifier: String] = [:]
    private var refreshVisible: (() -> Void)?
    private var artworkTasks: [URL: Task<UIImage?, Never>] = [:]

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        super.init()
    }

    func start() {
        guard !connected else { return }
        connected = true
        func tab(_ title: String, image: String) -> CPListTemplate {
            let template = CPListTemplate(title: title, sections: [message(String(localized: "Loading…"))])
            template.tabTitle = title
            template.tabImage = UIImage(systemName: image)
            return template
        }
        let forYou = tab(String(localized: "For You"), image: "star.fill")
        let live = tab(String(localized: "Live"), image: "dot.radiowaves.left.and.right")
        let listen = tab(String(localized: "Listen"), image: "headphones")
        let more = tab(String(localized: "More"), image: "ellipsis.circle")
        forYouTemplate = forYou
        liveTemplate = live
        listenTemplate = listen
        moreTemplate = more
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [forYou, live, listen, more]),
                                            animated: false, completion: nil)
        CPNowPlayingTemplate.shared.add(self)
        CPNowPlayingTemplate.shared.upNextTitle = String(localized: "Up Next")
        if #available(iOS 27.0, *) { CPNowPlayingTemplate.shared.allowsMiniPlayer = CarPlayRollout.shared.miniPlayer }
        playback.onFailure = { [weak self] _ in
            self?.showError(String(localized: "No playable broadcast is available. Choose another source."))
        }
        playback.onStateChange = { [weak self] in self?.render() }
        observationTasks = [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .bannerPreferencesChanged) {
                    guard !Task.isCancelled, let self else { return }
                    self.render()
                    self.startRefresh()
                    self.loadLibrary()
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .bannerAudioLibraryChanged) {
                    guard !Task.isCancelled else { return }
                    self?.render()
                }
            }
        ]
        render()
        startRefresh()
        loadLibrary()
    }

    func stop() {
        connected = false
        refreshTask?.cancel()
        libraryTask?.cancel()
        observationTasks.forEach { $0.cancel() }
        navigationTasks.values.forEach { $0.cancel() }
        artworkTasks.values.forEach { $0.cancel() }
        observationTasks.removeAll()
        navigationTasks.removeAll()
        artworkTasks.removeAll()
        CPNowPlayingTemplate.shared.remove(self)
        playback.onFailure = nil
        playback.onStateChange = nil
        refreshVisible = nil
        renderSignatures.removeAll()
        forYouTemplate = nil
        liveTemplate = nil
        listenTemplate = nil
        moreTemplate = nil
    }

    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connected else { return }
                let result = await SportsRepository.shared.liveMatchSnapshot(
                    leagues: self.env.preferences.followedLeagues, startingSoonWindow: 24 * 3600, nextLimit: 40)
                guard !Task.isCancelled, self.connected else { return }
                self.snapshot = result
                self.render()
                await self.env.streamStore.scan(matches: result.live, channels: self.env.playlistStore.allChannels,
                                                epgRepository: self.env.epgRepository)
                guard !Task.isCancelled else { return }
                self.render()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func loadLibrary() {
        libraryTask?.cancel()
        libraryTask = Task { [weak self] in
            guard let self else { return }
            await self.env.podcastStore.ensureCatalogLoaded()
            for podcast in self.env.podcastStore.followedPodcasts.prefix(12) {
                guard !Task.isCancelled else { return }
                await self.env.podcastStore.loadEpisodes(for: podcast.feedURL)
            }
            var shows: [Podcast] = []
            var seen = Set<String>()
            for team in self.env.preferences.favoriteTeams.prefix(6) {
                guard !Task.isCancelled else { return }
                let resolved = await self.env.podcastStore.resolvePodcasts(for: team)
                shows += resolved.filter { seen.insert($0.id).inserted }.prefix(5)
            }
            guard !Task.isCancelled else { return }
            self.teamPodcasts = shows
            self.render()
        }
    }

    private var games: [Match] {
        guard let snapshot else { return [] }
        var seen = Set<String>()
        return (snapshot.live + snapshot.startingSoon + snapshot.next + snapshot.pastStartToday)
            .filter { seen.insert($0.canonicalID ?? "\($0.league.path):\($0.id)").inserted }
    }

    private func render() {
        guard connected else { return }
        if #available(iOS 27.0, *) { CPNowPlayingTemplate.shared.allowsMiniPlayer = CarPlayRollout.shared.miniPlayer }
        renderForYou()
        renderLive()
        renderListen()
        renderMore()
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled =
            !env.podcastStore.listeningLibrary.upcoming.isEmpty && env.podcastStore.isPlaying
        refreshVisible?()
    }

    // Only replace sections when presentation changes, preserving navigation and reducing churn.
    private func update(_ template: CPListTemplate?, sections: [CPListSection]) {
        guard let template else { return }
        let sections = limited(sections)
        let signature = sections.map { section in
            (section.header ?? "") + section.items.compactMap { $0 as? CPListItem }.map {
                "\($0.text ?? "")|\($0.detailText ?? "")|\($0.isPlaying)|\(Int($0.playbackProgress * 100))"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        let key = ObjectIdentifier(template)
        guard renderSignatures[key] != signature else { return }
        renderSignatures[key] = signature
        template.updateSections(sections)
    }

    private func limited(_ sections: [CPListSection]) -> [CPListSection] {
        var remaining = CPListTemplate.maximumItemCount
        return sections.prefix(CPListTemplate.maximumSectionCount).compactMap { section in
            guard remaining > 0 else { return nil }
            let items = Array(section.items.prefix(remaining))
            remaining -= items.count
            return CPListSection(items: items, header: section.header, sectionIndexTitle: nil)
        }
    }

    private func message(_ title: String, detail: String? = nil) -> CPListSection {
        let item = CPListItem(text: title, detailText: detail)
        item.isEnabled = false
        return CPListSection(items: [item])
    }

    private func action(_ title: String, detail: String? = nil, symbol: String? = nil,
                        perform: @escaping @MainActor () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: symbol.flatMap { UIImage(systemName: $0) })
        item.accessoryType = .disclosureIndicator
        item.handler = { _, completion in
            perform()
            completion()
        }
        return item
    }

    private func push(_ template: CPTemplate) {
        guard connected, interfaceController.topTemplate !== template,
              interfaceController.templates.count < 5 else { return }
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func showList(_ title: String, sections: [CPListSection]) {
        push(CPListTemplate(title: title, sections: limited(sections)))
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        navigationTasks[id] = Task { [weak self] in
            await operation()
            self?.navigationTasks[id] = nil
        }
    }

    // MARK: - For You and Live

    private func renderForYou() {
        guard CarPlayRollout.shared.personalizedHome else {
            update(forYouTemplate, sections: [CPListSection(items: [
                action(String(localized: "Listen"), symbol: "headphones") { [weak self] in
                    guard let self, let template = self.listenTemplate else { return }
                    self.showList(String(localized: "Listen"), sections: template.sections)
                },
                action(String(localized: "Sports Channels"), symbol: "radio") { [weak self] in self?.showChannels() }
            ])])
            return
        }
        let favorites = games.filter { env.preferences.isFavoriteMatch($0) }
        var sections: [CPListSection] = []
        let live = favorites.filter { $0.state == .live }
        if !live.isEmpty {
            sections.append(CPListSection(items: live.map(gameRow), header: String(localized: "Your live games"), sectionIndexTitle: nil))
        }
        if let episode = env.podcastStore.continueListeningEpisode {
            sections.append(CPListSection(items: [episodeRow(episode)], header: String(localized: "Continue Listening"), sectionIndexTitle: nil))
        }
        let upcoming = favorites.filter { $0.state == .pre }.sorted { $0.date < $1.date }
        if !upcoming.isEmpty {
            sections.append(CPListSection(items: Array(upcoming.prefix(8)).map(gameRow),
                                          header: String(localized: "Your upcoming games"), sectionIndexTitle: nil))
        }
        let recommendations = AudioRecommendations.rank(store: env.podcastStore, teamPodcastIDs: Set(teamPodcasts.map(\.id)))
        if !recommendations.isEmpty {
            sections.append(CPListSection(items: recommendations.prefix(5).map { episodeRow($0.episode) },
                                          header: String(localized: "Recommended listening"), sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            if env.preferences.favoriteTeams.isEmpty {
                sections.append(message(String(localized: "No teams followed"), detail: String(localized: "Follow a team on your iPhone")))
            } else if snapshot == nil {
                sections.append(message(String(localized: "Loading…")))
            } else if snapshot?.failures.isEmpty == false {
                sections.append(message(String(localized: "Schedule unavailable"), detail: String(localized: "Some leagues could not be loaded. Try again shortly.")))
            } else {
                sections.append(message(String(localized: "No games for your followed teams")))
            }
            sections.append(CPListSection(items: [
                action(String(localized: "Your Podcasts"), symbol: "mic.fill") { [weak self] in self?.showPodcasts(self?.env.podcastStore.followedPodcasts ?? []) },
                action(String(localized: "Sports Channels"), symbol: "radio") { [weak self] in self?.showChannels() }
            ]))
        }
        update(forYouTemplate, sections: sections)
    }

    private func renderLive() {
        let ordered = games.sorted {
            let a = env.preferences.isFavoriteMatch($0), b = env.preferences.isFavoriteMatch($1)
            if a != b { return a }
            if ($0.state == .live) != ($1.state == .live) { return $0.state == .live }
            return $0.date < $1.date
        }
        var leagueOrder: [String] = []
        var byLeague: [String: [Match]] = [:]
        for game in ordered {
            if byLeague[game.league.path] == nil { leagueOrder.append(game.league.path) }
            byLeague[game.league.path, default: []].append(game)
        }
        var sections = leagueOrder.compactMap { path -> CPListSection? in
            guard let matches = byLeague[path], let league = matches.first?.league else { return nil }
            return CPListSection(items: matches.map(gameRow), header: league.shortName, sectionIndexTitle: nil)
        }
        if snapshot?.failures.isEmpty == false {
            sections.append(message(String(localized: "Some leagues could not be loaded. Try again shortly.")))
        }
        if sections.isEmpty { sections = [message(snapshot == nil ? String(localized: "Loading…") : String(localized: "No live games right now"))] }
        update(liveTemplate, sections: sections)
    }

    private func gameRow(_ match: Match) -> CPListItem {
        let title = match.hasDisplayScore && !env.preferences.prefs.spoilerFreeMode
            ? "\(match.away.abbreviation) \(match.away.score ?? "–") – \(match.home.abbreviation) \(match.home.score ?? "–")"
            : "\(match.away.abbreviation) @ \(match.home.abbreviation)"
        let item = action(title, detail: MatchAudioPresentation.status(match), symbol: "sportscourt") { [weak self] in
            guard let self else { return }
            self.showGame(self.games.first { $0.id == match.id && $0.league.path == match.league.path } ?? match)
        }
        item.isPlaying = playback.currentContext?.match.id == match.id &&
            playback.currentContext?.match.league.path == match.league.path &&
            playback.playbackController.state == .playing &&
            playback.currentContext?.channel.id == playback.playbackController.channel?.id
        loadArtwork(match.home.logoURL ?? match.away.logoURL, for: item)
        return item
    }

    private func showGame(_ match: Match) {
        let template = CPListTemplate(title: "\(match.away.abbreviation) @ \(match.home.abbreviation)", sections: [])
        template.updateSections(limited(gameSections(match)))
        refreshVisible = { [weak self, weak template] in
            guard let self, let template, self.interfaceController.topTemplate === template else { return }
            let current = self.games.first { $0.id == match.id && $0.league.path == match.league.path } ?? match
            self.update(template, sections: self.gameSections(current))
        }
        push(template)
    }

    private func gameSections(_ game: Match) -> [CPListSection] {
        var rows: [CPListItem] = []
        let sources = playback.confirmedBroadcasts(for: game)
        if game.state == .live, !sources.isEmpty {
            rows.append(action(String(localized: "Listen Live"), symbol: "play.fill") { [weak self] in
                self?.playback.listenLive(to: game) { [weak self] in self?.showNowPlaying() }
            })
            if sources.count > 1 {
                for source in sources {
                    rows.append(action(source.channel.name, detail: String(localized: "Alternative broadcast")) { [weak self] in
                        self?.playback.playBroadcast(for: game, source: source) { [weak self] in self?.showNowPlaying() }
                    })
                }
            }
        } else {
            let item = CPListItem(text: String(localized: "No confirmed broadcast available"), detailText: nil)
            item.isEnabled = false
            rows.append(item)
        }
        rows.append(action(String(localized: "Sports Channels")) { [weak self] in self?.showChannels() })
        return [message(MatchAudioPresentation.status(game)), CPListSection(items: rows)]
    }

    // MARK: - Listening

    private func renderListen() {
        let store = env.podcastStore
        var rows: [CPListItem] = []
        if let episode = store.continueListeningEpisode {
            rows.append(action(String(localized: "Continue Listening"), detail: episode.title, symbol: "play.fill") { [weak self] in self?.playEpisode(episode) })
        }
        rows.append(action(String(localized: "Your Podcasts"), symbol: "mic.fill") { [weak self] in self?.showPodcasts(self?.env.podcastStore.followedPodcasts ?? []) })
        if !teamPodcasts.isEmpty {
            rows.append(action(String(localized: "For Your Teams"), symbol: "star.fill") { [weak self] in self?.showPodcasts(self?.teamPodcasts ?? []) })
        }
        rows.append(action(String(localized: "Live Sports Radio"), detail: String(localized: "Audio from your sports channels"), symbol: "radio") { [weak self] in self?.showChannels() })
        let playable = games.filter { $0.state == .live && !playback.confirmedBroadcasts(for: $0).isEmpty }
        if !playable.isEmpty {
            rows.append(action(String(localized: "Live Game Audio"), symbol: "sportscourt") { [weak self] in
                guard let self else { return }
                self.showList(String(localized: "Live Game Audio"), sections: [CPListSection(items: playable.map(self.gameRow))])
            })
        }
        if CarPlayRollout.shared.offlineLibrary, !store.downloads.downloads.isEmpty {
            rows.append(action(String(localized: "Downloads"), symbol: "arrow.down.circle") { [weak self] in
                self?.showEpisodesList(String(localized: "Downloads"), episodes: self?.env.podcastStore.downloads.downloads.map(\.episode) ?? [])
            })
        }
        if !store.listeningLibrary.history.isEmpty {
            rows.append(action(String(localized: "Recently Played"), symbol: "clock") { [weak self] in
                self?.showEpisodesList(String(localized: "Recently Played"), episodes: self?.env.podcastStore.listeningLibrary.history ?? [])
            })
        }
        if !store.listeningLibrary.queue.isEmpty {
            rows.append(action(String(localized: "Up Next"), symbol: "list.bullet") { [weak self] in self?.showQueue() })
        }
        if CarPlayRollout.shared.sportsDrive, !AudioRecommendations.rank(store: store).isEmpty {
            rows.append(action(String(localized: "Sports Drive"), detail: String(localized: "Play your recommended podcast queue"), symbol: "car.fill") { [weak self] in
                guard let self, CarPlayRollout.shared.sportsDrive else { return }
                let episodes = AudioRecommendations.rank(store: self.env.podcastStore, teamPodcastIDs: Set(self.teamPodcasts.map(\.id))).prefix(20).map(\.episode)
                self.env.podcastStore.playQueue(episodes)
                self.showNowPlaying()
            })
        }
        update(listenTemplate, sections: [CPListSection(items: rows)])
    }

    private func showPodcasts(_ podcasts: [Podcast]) {
        guard !podcasts.isEmpty else {
            showList(String(localized: "Your Podcasts"), sections: [message(String(localized: "Follow podcasts on your iPhone"))])
            return
        }
        let items = podcasts.prefix(CPListTemplate.maximumItemCount).map { podcast in
            let item = action(podcast.title, detail: podcast.publisher, symbol: "mic.fill") { [weak self] in self?.showPodcast(podcast) }
            loadArtwork(podcast.artworkURL, for: item)
            return item
        }
        showList(String(localized: "Podcasts"), sections: [CPListSection(items: items)])
    }

    private func showPodcast(_ podcast: Podcast) {
        let template = CPListTemplate(title: podcast.title, sections: [message(String(localized: "Loading…"))])
        push(template)
        run { [weak self, weak template] in
            guard let self, let template else { return }
            await self.env.podcastStore.loadEpisodes(for: podcast.feedURL)
            guard !Task.isCancelled, self.connected else { return }
            let episodes = self.env.podcastStore.episodes(for: podcast).sorted { $0.publishedAt > $1.publishedAt }
            if episodes.isEmpty {
                let retry = self.action(String(localized: "Try Again")) { [weak self] in
                    guard let self else { return }
                    self.run { [weak self, weak template] in
                        guard let self, let template else { return }
                        await self.env.podcastStore.loadEpisodes(for: podcast.feedURL)
                        guard !Task.isCancelled else { return }
                        self.populateEpisodes(template, episodes: self.env.podcastStore.episodes(for: podcast).sorted { $0.publishedAt > $1.publishedAt }, page: 0)
                    }
                }
                template.updateSections([self.message(self.env.podcastStore.feedErrors[podcast.feedURL.absoluteString] ?? String(localized: "No episodes available")), CPListSection(items: [retry])])
            } else {
                self.populateEpisodes(template, episodes: episodes, page: 0)
            }
        }
    }

    private func showEpisodesList(_ title: String, episodes: [PodcastEpisode]) {
        let template = CPListTemplate(title: title, sections: [])
        populateEpisodes(template, episodes: episodes, page: 0)
        push(template)
    }

    private func populateEpisodes(_ template: CPListTemplate, episodes: [PodcastEpisode], page: Int) {
        let size = max(1, min(30, CPListTemplate.maximumItemCount - 2))
        let start = page * size
        var items = episodes.dropFirst(start).prefix(size).map(episodeRow)
        if page > 0 {
            items.append(action(String(localized: "Previous Page")) { [weak self, weak template] in
                if let self, let template { self.populateEpisodes(template, episodes: episodes, page: page - 1) }
            })
        }
        if start + size < episodes.count {
            items.append(action(String(localized: "More Episodes")) { [weak self, weak template] in
                if let self, let template { self.populateEpisodes(template, episodes: episodes, page: page + 1) }
            })
        }
        template.updateSections(items.isEmpty ? [message(String(localized: "No episodes available"))] : limited([CPListSection(items: items)]))
        refreshVisible = { [weak self, weak template] in
            guard let self, let template, self.interfaceController.topTemplate === template else { return }
            for case let item as CPListItem in template.sections.flatMap(\.items) {
                guard let id = item.userInfo as? String, let episode = episodes.first(where: { $0.id == id }) else { continue }
                item.isPlaying = self.env.podcastStore.nowPlaying?.id == id && self.env.podcastStore.isPlaying
                item.playbackProgress = CGFloat(self.env.podcastStore.progressFraction(for: episode))
            }
        }
    }

    private func episodeRow(_ episode: PodcastEpisode) -> CPListItem {
        let store = env.podcastStore
        let detail = [episode.podcastTitle, episode.formattedDuration, episode.publishedAt.formatted(date: .abbreviated, time: .omitted)].filter { !$0.isEmpty }.joined(separator: " · ")
        let item = action(episode.title, detail: detail, symbol: "play.circle") { [weak self] in self?.playEpisode(episode) }
        item.userInfo = episode.id
        item.playbackProgress = CGFloat(store.progressFraction(for: episode))
        item.isPlaying = store.nowPlaying?.id == episode.id && store.isPlaying
        loadArtwork(episode.podcastArtworkURL, for: item)
        return item
    }

    private func playEpisode(_ episode: PodcastEpisode) {
        env.podcastStore.play(episode)
        showNowPlaying()
    }

    private func showQueue() {
        showEpisodesList(String(localized: "Up Next"), episodes: env.podcastStore.listeningLibrary.upcoming)
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) { showQueue() }

    private func showNowPlaying() { push(CPNowPlayingTemplate.shared) }

    // MARK: - Secondary browsing

    private func renderMore() {
        let rows = [
            action(String(localized: "Leagues"), symbol: "sportscourt") { [weak self] in self?.showLeagues() },
            action(String(localized: "Sports Channels"), symbol: "radio") { [weak self] in self?.showChannels() },
            action(String(localized: "Upcoming Games"), symbol: "calendar") { [weak self] in self?.showSchedule(nil) },
            action(String(localized: "Preferences on iPhone"), symbol: "iphone") { [weak self] in
                self?.showList(String(localized: "Preferences on iPhone"), sections: [self?.message(String(localized: "Manage teams, playlists and podcasts on your iPhone")) ?? CPListSection(items: [])])
            }
        ]
        update(moreTemplate, sections: [CPListSection(items: rows)])
    }

    private func showLeagues() {
        let rows = env.preferences.followedLeagues.map { league in
            action(league.name) { [weak self] in self?.showSchedule(league) }
        }
        showList(String(localized: "Leagues"), sections: rows.isEmpty
                 ? [message(String(localized: "Choose leagues on your iPhone"))] : [CPListSection(items: rows)])
    }

    private func showSchedule(_ league: League?) {
        let template = CPListTemplate(title: league?.shortName ?? String(localized: "Upcoming Games"),
                                      sections: [message(String(localized: "Loading…"))])
        push(template)
        run { [weak self, weak template] in
            guard let self, let template else { return }
            var matches: [Match] = []
            var failed = false
            for league in league.map({ [$0] }) ?? self.env.preferences.followedLeagues {
                do {
                    matches += try await SportsRepository.shared.cachedLegacyScoreboards(
                        for: league, starting: Calendar.current.startOfDay(for: Date()), days: 7)
                } catch { failed = true }
                guard !Task.isCancelled else { return }
            }
            var seen = Set<String>()
            let upcoming = matches.filter {
                $0.state == .pre && $0.date >= Date() &&
                seen.insert($0.canonicalID ?? "\($0.league.path):\($0.id)").inserted
            }.sorted { $0.date < $1.date }
            var sections = [CPListSection(items: upcoming.map(self.gameRow))]
            if upcoming.isEmpty { sections = [self.message(failed ? String(localized: "Schedule unavailable") : String(localized: "No upcoming games"))] }
            self.update(template, sections: sections)
        }
    }

    private func showChannels() {
        var seen = Set<String>()
        let favoriteIDs = Set(env.channelPreferences.favoriteChannelIDs)
        let preferredLanguages = env.preferences.prefs.preferredStreamLanguages
        let channels = env.playlistStore.allChannels.filter {
            guard !env.channelPreferences.isHidden($0.id) else { return false }
            if favoriteIDs.contains($0.id) { return true }
            guard BannerSportsChannelClassifier.isSportsChannel($0) else { return false }
            let languages = SourceMatcher.languageTags(in: $0.name)
            return languages.isEmpty || preferredLanguages.isEmpty || !languages.isDisjoint(with: preferredLanguages)
        }.sorted {
            let a = favoriteIDs.contains($0.id), b = favoriteIDs.contains($1.id)
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a
        }.filter {
            seen.insert(($0.tvgId ?? $0.name).lowercased() + "|" + $0.playlistID.uuidString).inserted
        }
        let rows = channels.prefix(CPListTemplate.maximumItemCount).map { channel in
            let item = action(channel.name, detail: env.epgRepository.currentProgramme(for: channel.tvgId ?? channel.id)?.title, symbol: "radio") { [weak self] in
                self?.playback.playChannelDirectly(channel)
                self?.showNowPlaying()
            }
            item.isPlaying = playback.playbackController.channel?.id == channel.id && playback.playbackController.state == .playing
            loadArtwork(channel.logoURL, for: item)
            return item
        }
        showList(String(localized: "Sports Channels"), sections: rows.isEmpty
                 ? [message(String(localized: "No sports channels found"), detail: String(localized: "Add a playlist on your iPhone"))]
                 : [CPListSection(items: rows)])
    }

    private func loadArtwork(_ url: URL?, for item: CPListItem) {
        guard let url else { return }
        let task: Task<UIImage?, Never>
        if let existing = artworkTasks[url] { task = existing }
        else {
            task = Task {
                guard let cgImage = try? await ImagePipeline.shared.cgImage(for: url, maxPixelSize: 160),
                      !Task.isCancelled else { return nil }
                return UIImage(cgImage: cgImage)
            }
            // The image pipeline owns the durable cache; keep a bounded set of scene requests.
            if artworkTasks.count > 150 { artworkTasks.removeAll() }
            artworkTasks[url] = task
        }
        run { [weak item] in
            if let image = await task.value, !Task.isCancelled { item?.setImage(image) }
        }
    }

    private func showError(_ text: String) {
        guard connected, interfaceController.presentedTemplate == nil else { return }
        let alert = CPAlertTemplate(titleVariants: [text], actions: [
            CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        ])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}
#endif
