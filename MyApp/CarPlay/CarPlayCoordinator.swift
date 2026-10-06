import CarPlay
import Foundation

/// Builds and drives every CarPlay template. Holds no sports/matching/playback logic of
/// its own — it only reads `BannerAppEnvironment.shared`'s stores and
/// `CarPlayPlaybackCoordinator.shared`, and renders what they already compute into
/// Apple's CarPlay templates. Four tabs per the product brief: Live, Following, Listen, More.
@MainActor
final class CarPlayCoordinator {
    private let interfaceController: CPInterfaceController
    private let env = BannerAppEnvironment.shared
    private let playback = CarPlayPlaybackCoordinator.shared

    private var liveTemplate: CPListTemplate?
    private var followingTemplate: CPListTemplate?
    private var listenTemplate: CPListTemplate?
    private var moreTemplate: CPListTemplate?

    private var refreshTask: Task<Void, Never>?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        let live = CPListTemplate(title: "Live", sections: [loadingSection()])
        live.tabTitle = "Live"
        live.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right")
        let following = CPListTemplate(title: "Following", sections: [loadingSection()])
        following.tabTitle = "Following"
        following.tabImage = UIImage(systemName: "star.fill")
        let listen = CPListTemplate(title: "Listen", sections: [loadingSection()])
        listen.tabTitle = "Listen"
        listen.tabImage = UIImage(systemName: "headphones")
        let more = CPListTemplate(title: "More", sections: [loadingSection()])
        more.tabTitle = "More"
        more.tabImage = UIImage(systemName: "ellipsis.circle")

        liveTemplate = live
        followingTemplate = following
        listenTemplate = listen
        moreTemplate = more

        let tabBar = CPTabBarTemplate(templates: [live, following, listen, more])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        playback.onFailure = { [weak self] failure in
            self?.presentFailure(failure)
        }

        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // One snapshot fetch per tick, shared by Live and Following — avoids
                // duplicating the per-league network calls `SportsRepository` makes.
                let leagues = self.env.preferences.followedLeagues
                let snapshot = await SportsRepository.shared.liveMatchSnapshot(
                    leagues: leagues, startingSoonWindow: 24 * 3600, nextLimit: 20)
                self.updateLiveSections(from: snapshot)
                self.updateFollowingSections(from: snapshot)
                self.refreshListen()
                self.refreshMore()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        // Deliberately does not stop `playback` — live audio should keep playing on the
        // phone/car's active audio route after CarPlay disconnects, same as any other
        // audio app. Only CarPlay's own refresh loop and templates are torn down.
        refreshTask?.cancel()
        refreshTask = nil
        liveTemplate = nil
        followingTemplate = nil
        listenTemplate = nil
        moreTemplate = nil
    }

    private func loadingSection() -> CPListSection {
        CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
    }

    // MARK: - Live

    private func updateLiveSections(from snapshot: SportsLiveMatchSnapshot) {
        // The shared snapshot buckets "starting soon" over a wide window (so Following can
        // show the whole day); Live only wants the truly imminent ones.
        let imminent = snapshot.startingSoon.filter { $0.date.timeIntervalSinceNow <= 3600 }
        let ordered = rank(live: snapshot.live, startingSoon: imminent)
        var sections: [CPListSection] = []
        if !ordered.isEmpty {
            sections.append(CPListSection(items: ordered.map { matchListItem($0) }))
        } else {
            sections.append(CPListSection(items: [CPListItem(text: "No live games right now", detailText: "Check Following for upcoming games")]))
        }
        liveTemplate?.updateSections(sections)
    }

    /// Favorite teams first, then close games, then the rest — per the product brief's
    /// Live-tab priority order. "Close game" uses the score differential when both sides
    /// have a numeric score; non-numeric/missing scores sort last within their tier.
    private func rank(live: [Match], startingSoon: [Match]) -> [Match] {
        func margin(_ match: Match) -> Int {
            guard let h = Int(match.home.score ?? ""), let a = Int(match.away.score ?? "") else { return .max }
            return abs(h - a)
        }
        let rankedLive = live.sorted { a, b in
            let favA = env.preferences.isFavoriteMatch(a), favB = env.preferences.isFavoriteMatch(b)
            if favA != favB { return favA }
            return margin(a) < margin(b)
        }
        let rankedSoon = startingSoon.sorted { a, b in
            let favA = env.preferences.isFavoriteMatch(a), favB = env.preferences.isFavoriteMatch(b)
            if favA != favB { return favA }
            return a.date < b.date
        }
        return rankedLive + rankedSoon
    }

    private func matchListItem(_ match: Match) -> CPListItem {
        let scoreLine = match.hasDisplayScore
            ? "\(match.home.abbreviation) \(match.home.score ?? "0") — \(match.away.abbreviation) \(match.away.score ?? "0")"
            : "\(match.home.abbreviation) vs \(match.away.abbreviation)"
        let detail = [match.statusDetail, match.state.label].filter { !$0.isEmpty }.joined(separator: " · ")
        let item = CPListItem(text: scoreLine, detailText: detail)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.showGameDetail(for: match)
            completion()
        }
        return item
    }

    private func showGameDetail(for match: Match) {
        let template = buildGameDetailTemplate(for: match)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func buildGameDetailTemplate(for match: Match) -> CPListTemplate {
        var items: [CPListItem] = []

        let listen = CPListItem(text: "Listen Live", detailText: nil)
        listen.handler = { [weak self] _, completion in
            self?.listenLive(to: match)
            completion()
        }
        if match.state != .final { items.append(listen) }

        let confirmed = playback.confirmedBroadcasts(for: match)
        if confirmed.count > 1 {
            let change = CPListItem(text: "Change Broadcast", detailText: "\(confirmed.count) broadcasts available")
            change.handler = { [weak self] _, completion in
                self?.showChangeBroadcast(for: match, sources: confirmed)
                completion()
            }
            items.append(change)
        }

        let isFavorite = env.preferences.isFavoriteMatch(match)
        let follow = CPListItem(text: isFavorite ? "Unfollow" : "Follow", detailText: nil)
        follow.handler = { [weak self] _, completion in
            self?.toggleFollow(match)
            completion()
        }
        items.append(follow)

        if match.state == .pre {
            let remind = CPListItem(text: "Remind Me", detailText: nil)
            remind.handler = { [weak self] _, completion in
                Task { _ = await MatchNotificationService.shared.scheduleReminder(for: match, leadTime: self?.env.preferences.matchReminderLeadTime ?? .thirty) }
                completion()
            }
            items.append(remind)
        }

        let detail = match.hasDisplayScore
            ? "\(match.home.abbreviation) \(match.home.score ?? "0")  —  \(match.away.abbreviation) \(match.away.score ?? "0")\n\(match.statusDetail)"
            : match.statusDetail
        let template = CPListTemplate(title: "\(match.home.displayName) vs \(match.away.displayName)",
                                       sections: [CPListSection(items: [CPListItem(text: detail, detailText: nil)] + items)])
        return template
    }

    private func listenLive(to match: Match) {
        playback.listenLive(to: match)
        if playback.currentContext != nil {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    private func showChangeBroadcast(for match: Match, sources: [RankedSource]) {
        let items = sources.map { source -> CPListItem in
            let item = CPListItem(text: source.channel.name, detailText: source.linkerLabel)
            item.handler = { [weak self] _, completion in
                self?.playback.changeBroadcast(to: source)
                self?.interfaceController.popTemplate(animated: false, completion: nil)
                self?.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Change Broadcast", sections: [CPListSection(items: items)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func toggleFollow(_ match: Match) {
        let league = match.league
        for side in [match.home, match.away] {
            guard let teamID = side.teamID else { continue }
            let team = Team(id: teamID, displayName: side.displayName, shortDisplayName: side.shortName,
                             abbreviation: side.abbreviation, logoURL: side.logoURL, canonicalIDString: side.canonicalIDString)
            env.preferences.toggleFavorite(team, in: league)
        }
    }

    private func presentFailure(_ failure: CarPlayPlaybackCoordinator.PlaybackFailure) {
        let message: String
        switch failure {
        case .noConfirmedBroadcast: message = "No confirmed broadcast available"
        case .streamUnavailable: message = "Stream unavailable"
        case .gameEnded: message = "Game has ended"
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            }
        ])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Following

    private func updateFollowingSections(from snapshot: SportsLiveMatchSnapshot) {
        let favorites = (snapshot.live + snapshot.startingSoon + snapshot.next + snapshot.pastStartToday)
            .filter { env.preferences.isFavoriteMatch($0) }
        var byDay: [String: [Match]] = [:]
        var order: [String] = []
        let calendar = Calendar.current
        for match in favorites.sorted(by: { $0.date < $1.date }) {
            let key = dayLabel(for: match.date, calendar: calendar)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(match)
        }
        var sections: [CPListSection] = []
        if favorites.isEmpty {
            sections.append(CPListSection(items: [CPListItem(text: "No games for your followed teams", detailText: "Follow a team on your phone to see them here")]))
        } else {
            for key in order {
                sections.append(CPListSection(items: (byDay[key] ?? []).map { matchListItem($0) }, header: key, sectionIndexTitle: nil))
            }
        }
        followingTemplate?.updateSections(sections)
    }

    private func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    // MARK: - Listen

    private func refreshListen() {
        let sportsChannels = env.playlistStore.allChannels.filter(BannerSportsChannelClassifier.isSportsChannel).prefix(30)
        let items = sportsChannels.map { channel -> CPListItem in
            let now = env.epgRepository.currentProgramme(for: channel.tvgId ?? channel.id)
            let item = CPListItem(text: channel.name, detailText: now?.title ?? "—")
            item.handler = { [weak self] _, completion in
                self?.playChannel(channel)
                completion()
            }
            return item
        }
        var sections: [CPListSection] = []
        if items.isEmpty {
            sections.append(CPListSection(items: [CPListItem(text: "No sports channels found", detailText: "Add a playlist on your phone")]))
        } else {
            sections.append(CPListSection(items: Array(items), header: "Sports Channels", sectionIndexTitle: nil))
        }

        let podcastItems = env.podcastStore.catalog.filter { env.podcastStore.subscribedIDs.contains($0.feedURL.absoluteString) }
            .prefix(15).map { feed -> CPListItem in
                let item = CPListItem(text: feed.title, detailText: "Latest Episode")
                item.handler = { [weak self] _, completion in
                    self?.playLatestEpisode(forFeed: feed)
                    completion()
                }
                return item
            }
        if !podcastItems.isEmpty {
            sections.append(CPListSection(items: Array(podcastItems), header: "Followed Podcasts", sectionIndexTitle: nil))
        }

        listenTemplate?.updateSections(sections)
    }

    private func playChannel(_ channel: Channel) {
        playback.playChannelDirectly(channel)
    }

    private func playLatestEpisode(forFeed feed: PodcastCatalog.CatalogFeed) {
        let podcast = feed.toPodcast()
        guard let episode = env.podcastStore.episodes(for: podcast).first else { return }
        env.podcastStore.play(episode)
    }

    // MARK: - More

    private func refreshMore() {
        let sportsDrive = CPListItem(text: "Sports Drive", detailText: "Personalized sports radio")
        sportsDrive.handler = { [weak self] _, completion in
            self?.startSportsDrive()
            completion()
        }
        let upcoming = CPListItem(text: "Upcoming Games", detailText: nil)
        upcoming.handler = { [weak self] _, completion in
            self?.showUpcoming()
            completion()
        }
        let leagues = CPListItem(text: "Leagues", detailText: env.preferences.followedLeagues.map(\.shortName).joined(separator: ", "))
        let recent = CPListItem(text: "Recently Played", detailText: nil)
        moreTemplate?.updateSections([CPListSection(items: [sportsDrive, upcoming, leagues, recent])])
    }

    private func startSportsDrive() {
        let task = Task { [weak self] in
            guard let self else { return }
            let leagues = self.env.preferences.followedLeagues
            let snapshot = await SportsRepository.shared.liveMatchSnapshot(leagues: leagues, startingSoonWindow: 24 * 3600, nextLimit: 5)
            let favoriteLive = snapshot.live.filter { self.env.preferences.isFavoriteMatch($0) }
            let upcomingFavorites = (snapshot.startingSoon + snapshot.next).filter { self.env.preferences.isFavoriteMatch($0) }
            SportsDrivePlayer.shared.start(favoriteMatches: favoriteLive, otherLiveMatches: snapshot.live, upcomingFavoriteMatches: upcomingFavorites)
            self.interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
        _ = task
    }

    private func showUpcoming() {
        let leagues = env.preferences.followedLeagues
        let task = Task { [weak self] in
            guard let self else { return }
            let snapshot = await SportsRepository.shared.liveMatchSnapshot(leagues: leagues, startingSoonWindow: 7 * 24 * 3600, nextLimit: 40)
            let calendar = Calendar.current
            var byDay: [String: [Match]] = [:]
            var order: [String] = []
            for match in (snapshot.next + snapshot.startingSoon).sorted(by: { $0.date < $1.date }) {
                let key = self.dayLabel(for: match.date, calendar: calendar)
                if byDay[key] == nil { order.append(key) }
                byDay[key, default: []].append(match)
            }
            let sections = order.map { key in
                CPListSection(items: (byDay[key] ?? []).map { self.matchListItem($0) }, header: key, sectionIndexTitle: nil)
            }
            let template = CPListTemplate(title: "Upcoming Games", sections: sections.isEmpty
                ? [CPListSection(items: [CPListItem(text: "No upcoming games", detailText: nil)])] : sections)
            self.interfaceController.pushTemplate(template, animated: true, completion: nil)
        }
        _ = task
    }
}
