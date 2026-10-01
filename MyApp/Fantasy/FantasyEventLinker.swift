import Foundation

struct FantasyEventLinker: FantasyEventLinking {
    private let nowProvider: @Sendable () -> Date

    init(nowProvider: @escaping @Sendable () -> Date = { Date() }) {
        self.nowProvider = nowProvider
    }

    func linkPlayerGames(
        players: [FantasyPlayer],
        resolutions: [String: FantasyPlayerResolution],
        matchup: FantasyMatchup?,
        channels: [Channel],
        preferredLanguages: Set<String>,
        knownMatches: [Match]? = nil
    ) async -> [FantasyPlayerGame] {
        let fantasyLeague = players.first?.sport.bannerLeague
        let matches: [Match]
        if let knownMatches {
            matches = knownMatches
        } else if let fantasyLeague {
            let today = Calendar.current.startOfDay(for: nowProvider())
            matches = (try? await SportsRepository.shared.legacyScoreboards(for: fantasyLeague, starting: today, days: 8)) ?? []
        } else {
            matches = []
        }

        let pointsByPlayerID = fantasyPointsByPlayerID(from: matchup)

        // This linker has no access to the app's EPG store, so it builds a name/broadcast-only
        // StreamLinker (no guide programmes) once, off the main actor, and reuses it for every
        // player — still gets team-channel, event-channel and broadcast-rights tiers, just not
        // the guide-listing ones (which need EPGRepository/EPGProgrammeStore; see
        // MatchLinkService, used instead wherever those are available).
        let streamAdapters = channels.map(StreamLinkerAdapters.stream)
        var channelByID: [String: Channel] = [:]
        for channel in channels { channelByID[StreamLinkerAdapters.streamID(channel)] = channel }
        let linker = await Task.detached(priority: .utility) {
            StreamLinker(streams: streamAdapters, programmes: [])
        }.value

        return players.map { player in
            let identity = resolutions[player.id]?.identity
            let match = self.match(for: player, identity: identity, in: matches)
            let opponent = match.flatMap { self.opponent(for: player, identity: identity, match: $0) }
            let ranked = match.map {
                StreamLinkerAdapters.rankedSources(for: linker.link(StreamLinkerAdapters.event($0)).groupedByFamily(), channelByID: channelByID)
            } ?? []
            return FantasyPlayerGame(
                id: "\(player.id)-\(match?.id ?? "none")",
                fantasyPlayer: player,
                bannerPlayer: identity,
                event: match,
                opponent: opponent,
                gameState: match.map(Self.gameLinkState) ?? .noGame,
                fantasyPoints: pointsByPlayerID[player.id],
                projectedPoints: nil,
                matchedChannel: ranked.first
            )
        }
    }

    private func fantasyPointsByPlayerID(from matchup: FantasyMatchup?) -> [String: Double] {
        // Sleeper's matchup endpoint supplies team totals for this implementation;
        // individual player point totals remain nil until a reliable provider field is added.
        guard matchup != nil else { return [:] }
        return [:]
    }

    private func match(for player: FantasyPlayer, identity: BannerPlayerIdentity?, in matches: [Match]) -> Match? {
        let team = identity?.teamAbbreviation ?? player.teamAbbreviation
        guard let team, !team.isEmpty else { return nil }
        let relevant = matches.filter { match in
            match.home.abbreviation.caseInsensitiveCompare(team) == .orderedSame
                || match.away.abbreviation.caseInsensitiveCompare(team) == .orderedSame
        }
        return relevant.sorted { lhs, rhs in
            switch (lhs.state, rhs.state) {
            case (.live, .live): return lhs.date < rhs.date
            case (.live, _): return true
            case (_, .live): return false
            default: return lhs.date < rhs.date
            }
        }.first
    }

    private func opponent(for player: FantasyPlayer, identity: BannerPlayerIdentity?, match: Match) -> TeamSide? {
        let team = identity?.teamAbbreviation ?? player.teamAbbreviation
        guard let team else { return nil }
        if match.home.abbreviation.caseInsensitiveCompare(team) == .orderedSame { return match.away }
        if match.away.abbreviation.caseInsensitiveCompare(team) == .orderedSame { return match.home }
        return nil
    }

    private static func gameLinkState(for match: Match) -> FantasyGameLinkState {
        switch match.state {
        case .pre: return .upcoming
        case .live: return .live
        case .final: return .final
        }
    }
}
