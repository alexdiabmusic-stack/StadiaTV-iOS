#if os(tvOS)
import SwiftUI

struct TVMatchDetailView: View {
    let match: Match
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @EnvironmentObject private var streamStore: StreamAvailabilityStore
    @State private var rankedSources: [RankedSource] = []
    @State private var playingChannel: Channel?
    @State private var matchNews: [ESPNArticle] = []

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if match.league.path == "hockey/nhl" {
                NHLGameCenterView(match: match) {
                    if !rankedSources.isEmpty {
                        TVShelfRow(title: "Stream Sources", systemImage: "play.tv.fill") {
                            ForEach(rankedSources) { source in
                                TVSourceTile(channel: source.channel, score: source.score,
                                             subtitle: source.epgProgramme?.title,
                                             evidenceCategories: source.evidenceCategories) {
                                    playingChannel = source.channel
                                }
                            }
                        }
                    } else if !playlistStore.playlists.isEmpty {
                        noSourcesNote
                    }
                    if !matchNews.isEmpty { newsSection }
                }
            } else if match.league.path == "baseball/mlb" {
                MLBGameCenterView(match: match) {
                    if !rankedSources.isEmpty {
                        TVShelfRow(title: "Stream Sources", systemImage: "play.tv.fill") {
                            ForEach(rankedSources) { source in
                                TVSourceTile(channel: source.channel, score: source.score,
                                             subtitle: source.epgProgramme?.title,
                                             evidenceCategories: source.evidenceCategories) {
                                    playingChannel = source.channel
                                }
                            }
                        }
                    } else if !playlistStore.playlists.isEmpty {
                        noSourcesNote
                    }
                    if !matchNews.isEmpty { newsSection }
                }
            } else if match.league.path == "football/nfl" {
                NFLGameCenterView(match: match) {
                    if !rankedSources.isEmpty {
                        TVShelfRow(title: "Stream Sources", systemImage: "play.tv.fill") {
                            ForEach(rankedSources) { source in
                                TVSourceTile(channel: source.channel, score: source.score,
                                             subtitle: source.epgProgramme?.title,
                                             evidenceCategories: source.evidenceCategories) {
                                    playingChannel = source.channel
                                }
                            }
                        }
                    } else if !playlistStore.playlists.isEmpty {
                        noSourcesNote
                    }
                    if !matchNews.isEmpty { newsSection }
                }
            } else if match.league.path == "racing/f1" {
                F1RaceCentreView(match: match) {
                    if !rankedSources.isEmpty {
                        TVShelfRow(title: "Stream Sources", systemImage: "play.tv.fill") {
                            ForEach(rankedSources) { source in
                                TVSourceTile(channel: source.channel, score: source.score,
                                             subtitle: source.epgProgramme?.title,
                                             evidenceCategories: source.evidenceCategories) {
                                    playingChannel = source.channel
                                }
                            }
                        }
                    } else if !playlistStore.playlists.isEmpty {
                        noSourcesNote
                    }
                    if !matchNews.isEmpty { newsSection }
                }
            } else if match.league.path == "basketball/nba" {
                NBAGameCenterView(match: match) {
                    if !rankedSources.isEmpty {
                        TVShelfRow(title: "Stream Sources", systemImage: "play.tv.fill") {
                            ForEach(rankedSources) { source in
                                TVSourceTile(channel: source.channel, score: source.score,
                                             subtitle: source.epgProgramme?.title,
                                             evidenceCategories: source.evidenceCategories) {
                                    playingChannel = source.channel
                                }
                            }
                        }
                    } else if !playlistStore.playlists.isEmpty {
                        noSourcesNote
                    }
                    if !matchNews.isEmpty { newsSection }
                }
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    matchHero
                    if !rankedSources.isEmpty {
                        TVShelfRow(title: "Stream Sources", systemImage: "play.tv.fill") {
                            ForEach(rankedSources) { source in
                                TVSourceTile(channel: source.channel, score: source.score,
                                             subtitle: source.epgProgramme?.title,
                                             evidenceCategories: source.evidenceCategories) {
                                    playingChannel = source.channel
                                }
                            }
                        }
                    } else if !playlistStore.playlists.isEmpty {
                        noSourcesNote
                    }
                    if !match.broadcasts.isEmpty {
                        broadcastsSection
                    }
                    matchInfoSection
                    if !matchNews.isEmpty {
                        newsSection
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 48)
            }
            }
        }
        .navigationTitle(match.shortName)
        .task(id: "\(match.id)-\(playlistStore.allChannels.count)-\(prefs.preferredStreamLanguages.sorted().joined(separator: ","))-\(Int(epgRepository.lastUpdated?.timeIntervalSince1970 ?? 0))") {
            await rankSources()
        }
        .task(id: match.id) {
            matchNews = (try? await SportsRepository.shared.legacyNews(for: match.league, limit: 6)) ?? []
        }
        .fullScreenCover(item: $playingChannel) { channel in
            TVPlayerView(channel: channel, initialMatch: match)
        }
    }

    private func rankSources() async {
        guard match.state != .final else { rankedSources = []; return }

        let channels = playlistStore.allChannels
        let match = self.match

        // Fast path: background scan already ran for this match — display immediately.
        if let cached = streamStore.sourcesByMatchId[match.id], !cached.isEmpty {
            rankedSources = cached
            return
        }

        // Primary: channels confirmed by the EPG programme guide.
        let titleHints = [match.name, match.shortName, match.home.displayName, match.away.displayName]
            .filter { !$0.isEmpty }
        let broadcastNetworks = match.broadcasts.filter { !$0.isEmpty }
        let joins = epgRepository.programmesNear(
            start: match.date,
            titleHints: titleHints,
            broadcastNetworks: broadcastNetworks
        )

        var bestJoinByCanonical: [String: ProgrammeEventJoin] = [:]
        for join in joins where SourceMatcher.confirms(programme: join.programme, for: match) {
            if let existing = bestJoinByCanonical[join.canonicalChannelId] {
                if join.score > existing.score { bestJoinByCanonical[join.canonicalChannelId] = join }
            } else {
                bestJoinByCanonical[join.canonicalChannelId] = join
            }
        }

        let channelToCanonical = epgRepository.channelToCanonicalMap
        var canonicalToChannels: [String: [Channel]] = [:]
        for channel in channels {
            if let cid = channelToCanonical[channel.id] {
                canonicalToChannels[cid, default: []].append(channel)
            }
        }

        var primarySources: [RankedSource] = []
        var primaryIds = Set<String>()
        for (canonicalId, join) in bestJoinByCanonical {
            for channel in (canonicalToChannels[canonicalId] ?? []) {
                guard SourceMatcher.isEligible(channel: channel, for: match) else { continue }
                var source = RankedSource(channel: channel, score: 100 + Int(join.titleSimilarity * 50))
                source.evidenceCategories = [.guideListsMatch]
                source.epgProgramme = join.programme
                source.canonicalChannelId = canonicalId
                primarySources.append(source)
                primaryIds.insert(channel.id)
            }
        }
        primarySources.sort(by: SourceMatcher.ranksBefore)

        // Backup: every channel whose name contains a team name or event/series keyword.
        let backupSources = await Task.detached(priority: .userInitiated) {
            SourceMatcher.teamNameBackups(match: match, channels: channels, excludeIds: primaryIds)
        }.value

        rankedSources = primarySources + backupSources
    }

    // MARK: - Hero scoreboard

    private var matchHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [Theme.surface, Theme.surfaceElevated],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.hairline)
                )
            HStack(spacing: 0) {
                // Home
                teamColumn(side: match.home)
                // Center status
                VStack(spacing: 14) {
                    if match.state == .live { TVLiveBadge() }
                    Text(match.state == .pre ? "VS" : match.statusDetail)
                        .font(match.state == .pre ? .title.weight(.bold) : .headline.weight(.bold))
                        .foregroundStyle(match.state == .pre ? Theme.textSecondary : Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(match.league.shortName.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(1.5)
                }
                .frame(maxWidth: 180)
                // Away
                teamColumn(side: match.away)
            }
            .padding(.vertical, 40)
        }
    }

    private func teamColumn(side: TeamSide) -> some View {
        VStack(spacing: 12) {
            TVTeamLogo(url: side.logoURL, size: 90)
            Text(side.abbreviation)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if let score = side.score {
                Text(score)
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(side.isWinner ? Theme.accent : Theme.textPrimary)
                    .monospacedDigit()
            }
            if let record = side.record {
                Text(record)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - No sources note

    private var noSourcesNote: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No matching streams found")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("The source matcher didn't find a channel that matches this match.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: - Broadcasts

    private var broadcastsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Broadcasts", systemImage: "antenna.radiowaves.left.and.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                ForEach(match.broadcasts, id: \.self) { network in
                    Text(network)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
            }
        }
    }

    // MARK: - Match info

    private var matchInfoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Match Info", systemImage: "info.circle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                infoRow(label: "League", value: match.league.name)
                Divider().background(Theme.hairline)
                infoRow(label: "Status", value: match.statusDetail)
                if let venue = match.venue {
                    Divider().background(Theme.hairline)
                    infoRow(label: "Venue", value: venue)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - News

    private var newsSection: some View {
        TVShelfRow(title: "Related News", systemImage: "newspaper.fill") {
            ForEach(matchNews) { article in
                TVNewsCard(article: article)
            }
        }
    }
}

private struct TVNewsCard: View {
    let article: ESPNArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: article.imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "newspaper.fill")
                        .font(.title)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 280, height: 158)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(article.headline)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let published = article.published {
                    Text(published, style: .relative)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(width: 280)
    }
}
#endif
