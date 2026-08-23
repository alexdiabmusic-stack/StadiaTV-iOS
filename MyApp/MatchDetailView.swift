import SwiftUI
#if os(iOS)
import UIKit
import SafariServices
#endif

struct MatchDetailView: View {
    let match: Match
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var predictions: PredictionsStore
    @State private var showingAllChannels = false
    @State private var spoilerRevealed = false
    @State private var playingChannel: Channel?
    @State private var isPickingMultiscreen = false
    @State private var multiscreenSlots: [MultiscreenSlot] = []
    @State private var liveMatchesForMultiscreen: [LiveGameOption] = []
    @State private var isLoadingLiveGames = false
    @State private var multiscreenShowAllSports = false
    @State private var multiscreenSportFilter: SportGroup? = nil
    @State private var multiscreenSession: MultiscreenSession?
    @State private var gameSummary: GameSummary?
    @State private var isLoadingGameSummary = false
    @State private var didAttemptGameSummaryLoad = false
    @State private var showPaywall = false
    @State private var browsingWatchLink: WatchLink?
    // Ranking a big playlist is expensive, so it runs once off the main thread
    // instead of inside every body evaluation.
    @State private var rankedSources: [RankedSource] = []
    @State private var isRankingSources = true
    @State private var channelQuery = ""
    @State private var selectedGameCenterTeam: GameCenterTeam = .away
    @State private var rosterPreviewByTeamID: [String: [RosterAthlete]] = [:]
    @State private var selectedRosterPosition: String?
    @State private var isShowingFullRosterPreview = false
    @State private var odds: MatchOddsDisplay?
    @State private var isLoadingOdds = false
    @State private var showPickCelebration = false
    @State private var gameCenterTab: GameCenterTab = .players

    private enum GameCenterTab: String, CaseIterable, Identifiable {
        case players = "Players"
        case gameStats = "Game Stats"
        case standings = "Standings"
        var id: String { rawValue }
    }

    private var filteredMatchedSources: [RankedSource] {
        guard showingAllChannels else { return Array(rankedSources.prefix(3)) }
        let trimmed = channelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rankedSources }
        return rankedSources.filter {
            ($0.channel.name + " " + ($0.channel.group ?? "") + " " + $0.channel.playlistName)
                .localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var displayedChannels: [Channel] {
        filteredMatchedSources.map(\.channel)
    }

    private var selectedTeamID: String? {
        (selectedGameCenterTeam == .away ? match.away : match.home).teamID
    }

    private var hasAvailableGameStats: Bool {
        guard let gameSummary else { return false }
        return !gameSummary.isEmpty
    }

    private var availableGameCenterTabs: [GameCenterTab] {
        hasAvailableGameStats ? [.players, .gameStats, .standings] : [.players, .standings]
    }

    private var effectiveGameCenterTab: GameCenterTab {
        availableGameCenterTabs.contains(gameCenterTab) ? gameCenterTab : .players
    }

    private var selectedMultiscreenChannels: [Channel] {
        multiscreenSlots.compactMap { $0.channel }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    scoreboard
                    picksSection
                    headToHeadSection
                    if match.state == .final {
                        highlightsSection
                        scoringSummarySection
                    }
                    if match.state != .final && (!playlists.allChannels.isEmpty || !watchLinks.isEmpty) {
                        sourcesSection
                    }
                    if match.league.group == .racing {
                        RacersSection(league: match.league)
                    } else {
                        gameCenterSection
                    }
                    playByPlaySection
                    if match.state != .final {
                        highlightsSection
                    }
                }
                .padding(16)
                .padding(.bottom, isPickingMultiscreen ? 92 : 0)
            }

            if isPickingMultiscreen {
                multiscreenFooter
            }
        }
        .navigationTitle(match.league.name)
        .fullScreenCover(item: $playingChannel) { channel in
            PlayerView(channel: channel, showsLiveTVControls: false)
        }
        .fullScreenCover(item: $multiscreenSession) { session in
            MultiScreenPlayerView(channels: session.channels)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $browsingWatchLink) { link in
            #if os(iOS)
            SafariSheet(url: link.url).ignoresSafeArea()
            #endif
        }
        .task(id: match.id) {
            await loadGameSummary()
        }
        .task(id: match.id) {
            await loadOdds()
        }
        .task(id: "\(playlists.allChannels.count)-\(prefs.preferredStreamLanguages.sorted().joined(separator: ","))") {
            await rankSources()
        }
        .task(id: selectedTeamID) {
            selectedRosterPosition = nil
            isShowingFullRosterPreview = false
            await loadRosterPreviewForSelectedTeam()
        }
    }

    /// Scores the playlist channels against this match off the main thread.
    private func rankSources() async {
        guard match.state != .final else {
            rankedSources = []
            isRankingSources = false
            return
        }

        let channels = playlists.allChannels
        let match = self.match
        let preferredLanguages = prefs.preferredStreamLanguages
        let ranked = await Task.detached(priority: .userInitiated) {
            SourceMatcher.rank(match: match, channels: channels, preferredLanguages: preferredLanguages)
        }.value
        rankedSources = Array(ranked.prefix(30))
        isRankingSources = false
    }

    private func loadRosterPreviewForSelectedTeam() async {
        guard let teamID = selectedTeamID, rosterPreviewByTeamID[teamID] == nil else { return }
        let service = ESPNService()
        let groups = (try? await service.roster(for: match.league, teamID: teamID)) ?? []
        rosterPreviewByTeamID[teamID] = groups.flatMap(\.athletes)
    }

    private func loadOdds() async {
        guard AppConfiguration.isOddsEnabled else { return }
        isLoadingOdds = true
        defer { isLoadingOdds = false }
        odds = try? await OddsService().odds(for: match)
    }

    /// Loads boxscore stats once, then keeps polling while the game is live.
    private func loadGameSummary() async {
        gameSummary = nil
        gameCenterTab = .players
        didAttemptGameSummaryLoad = false
        guard match.state != .pre else { return }

        let service = ESPNService()
        while !Task.isCancelled {
            isLoadingGameSummary = gameSummary == nil
            let summary = try? await service.gameSummary(for: match.league, eventID: match.id)
            didAttemptGameSummaryLoad = true
            isLoadingGameSummary = false

            if let summary, !summary.isEmpty {
                gameSummary = summary
            }

            guard match.state == .live else { break }
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if Task.isCancelled { break }
        }
    }

    // MARK: Scoreboard header

    private var scoreboard: some View {
        VStack(spacing: 16) {
            statusLine
            HStack(alignment: .center) {
                teamColumn(match.away)
                VStack(spacing: 4) {
                    if match.state == .pre {
                        Text("VS").font(.headline).foregroundStyle(Theme.textSecondary)
                    } else if prefs.spoilerFreeMode && match.state == .final && !spoilerRevealed {
                        VStack(spacing: 6) {
                            Text("? – ?")
                                .font(.title.weight(.heavy).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                            Button("Reveal Score") {
                                withAnimation(.snappy) { spoilerRevealed = true }
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                        }
                    } else {
                        Text("\(match.away.score ?? "-")  –  \(match.home.score ?? "-")")
                            .font(.title.weight(.heavy).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                teamColumn(match.home)
            }
            compactMoneyline
            if let venue = match.venue {
                Label(venue, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !match.broadcasts.isEmpty {
                Label(match.broadcasts.joined(separator: ", "), systemImage: "tv")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if match.state == .live {
                Circle().fill(Theme.live).frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(.footnote.weight(.bold))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
        }
    }

    private var statusText: String {
        switch match.state {
        case .live: return "LIVE · \(match.statusDetail)"
        case .final: return "FINAL"
        case .pre:
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: match.date)
        }
    }

    private func teamColumn(_ team: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: team.logoURL, size: 56)
            Text(team.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let record = team.record, !record.isEmpty {
                Text(record).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var compactMoneyline: some View {
        if let odds {
            CompactMoneylineOdds(match: match, odds: odds)
        } else if isLoadingOdds {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
                Text("Loading moneyline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, -4)
        }
    }

    private struct CompactMoneylineOdds: View {
        let match: Match
        let odds: MatchOddsDisplay

        private var moneylineColumns: [OddsColumn] {
            var columns = [OddsColumn(label: match.away.abbreviation.isEmpty ? match.away.shortName : match.away.abbreviation, price: odds.awayPrice)]
            if let drawPrice = odds.drawPrice {
                columns.append(OddsColumn(label: "Draw", price: drawPrice))
            }
            columns.append(OddsColumn(label: match.home.abbreviation.isEmpty ? match.home.shortName : match.home.abbreviation, price: odds.homePrice))
            return columns
        }

        var body: some View {
            HStack(spacing: 8) {
                Text("ML")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(moneylineColumns) { column in
                    HStack(spacing: 3) {
                        Text(column.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(format(price: column.price))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary.opacity(0.92))
                            .lineLimit(1)
                    }
                }
                Text(odds.bookmakerName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.11)))
        }

        private func format(price: Int?) -> String {
            guard let price else { return "—" }
            return price > 0 ? "+\(price)" : "\(price)"
        }
    }

    private struct OddsColumn: Identifiable {
        let id = UUID()
        let label: String
        let price: Int?
    }

    // MARK: In-game stats (boxscore + leaders)

    /// The boxscore column for a side, matched by ESPN team id with a
    /// positional fallback (ESPN lists away first).
    private func teamBox(for side: TeamSide, fallbackIndex: Int) -> GameSummary.TeamBox? {
        guard let summary = gameSummary else { return nil }
        if let id = side.teamID, let box = summary.teams.first(where: { $0.id == id }) {
            return box
        }
        return summary.teams.indices.contains(fallbackIndex) ? summary.teams[fallbackIndex] : nil
    }

    @ViewBuilder private var inGameStatsSection: some View {
        if let summary = gameSummary, match.state != .pre, !summary.isEmpty {
            if entitlements.isPremium {
                inGameStatsBody(summary: summary)
            } else {
                ZStack {
                    inGameStatsBody(summary: summary)
                        .blur(radius: 8)
                        .allowsHitTesting(false)
                    PremiumGateOverlay(
                        icon: "chart.bar.xaxis",
                        title: "Game Stats",
                        description: "Live boxscore comparison, game leaders and in-game analytics.",
                        showPaywall: $showPaywall
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder private func inGameStatsBody(summary: GameSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                Text(match.state == .live ? "In-Game Stats" : "Game Stats")
                Spacer()
                if match.state == .live {
                    Text("LIVE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.live)
                }
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)

            let awayBox = teamBox(for: match.away, fallbackIndex: 0)
            let homeBox = teamBox(for: match.home, fallbackIndex: 1)

            if let awayBox, let homeBox, !awayBox.stats.isEmpty {
                statComparison(away: awayBox, home: homeBox)
            }

            if !summary.leaders.isEmpty {
                gameLeaders(summary.leaders)
            }
        }
    }

    private func statComparison(away: GameSummary.TeamBox, home: GameSummary.TeamBox) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(away.abbreviation.isEmpty ? match.away.abbreviation : away.abbreviation)
                    .frame(width: 74, alignment: .leading)
                Spacer()
                Text(home.abbreviation.isEmpty ? match.home.abbreviation : home.abbreviation)
                    .frame(width: 74, alignment: .trailing)
            }
            .font(.caption.weight(.heavy))
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, 8)

            ForEach(Array(away.stats.prefix(14)), id: \.label) { stat in
                let homeValue = home.stats.first { $0.label == stat.label }?.displayValue ?? "–"
                HStack {
                    Text(stat.displayValue)
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 74, alignment: .leading)
                    Spacer()
                    Text(stat.label)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(homeValue)
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 74, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) {
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func gameLeaders(_ leaders: [GameSummary.GameLeader]) -> some View {
        VStack(spacing: 0) {
            ForEach(leaders) { leader in
                HStack(spacing: 10) {
                    Text(leader.category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(1)
                    Text(leader.athleteName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let team = leader.teamAbbreviation, !team.isEmpty {
                        Text(team)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text(leader.displayValue)
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    if leader.id != leaders.first?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: Scoring / Play by Play

    private var scoringPlays: [PlayByPlayEntry] {
        gameSummary?.plays.filter(\.isScoringPlay) ?? []
    }

    @ViewBuilder private var scoringSummarySection: some View {
        if match.state == .final, !scoringPlays.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sportscourt.fill")
                    Text("Scoring Summary")
                    Spacer()
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)

                VStack(spacing: 0) {
                    ForEach(Array(scoringPlays.prefix(12).enumerated()), id: \.element.id) { index, play in
                        ScoringPlayRow(play: play, match: match)
                        if index < min(scoringPlays.count, 12) - 1 {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }

    @ViewBuilder private var playByPlaySection: some View {
        if let summary = gameSummary, match.state != .pre, !summary.plays.isEmpty {
            if entitlements.isPremium {
                PlayByPlaySectionView(plays: summary.plays, match: match)
            } else {
                ZStack {
                    PlayByPlaySectionView(plays: Array(summary.plays.prefix(4)), match: match)
                        .blur(radius: 7)
                        .allowsHitTesting(false)
                    PremiumGateOverlay(
                        icon: "list.bullet.clipboard.fill",
                        title: "Play by Play",
                        description: "Real-time feed of every key moment as it happens.",
                        showPaywall: $showPaywall
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: Picks & Predictions

    @ViewBuilder private var picksSection: some View {
        if match.state == .pre || predictions.hasPrediction(for: match.id) {
            let existing = predictions.prediction(for: match.id)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                    Text(existing == nil ? "Make Your Pick" : "Your Pick")
                    Spacer()
                    if let p = existing, let correct = p.isCorrect {
                        Label(correct ? "Correct" : "Incorrect",
                              systemImage: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(correct ? Color(hex: 0x3DBE6B) : Theme.live)
                    }
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)

                if let p = existing {
                    HStack(spacing: 8) {
                        Image(systemName: p.pick.systemImage)
                        Text(p.pick.label(away: match.away.shortName, home: match.home.shortName))
                            .fontWeight(.semibold)
                        Spacer()
                        if !p.isResolved {
                            Text("Pending result")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else if let pts = p.pointsEarned {
                            VStack(alignment: .trailing, spacing: 2) {
                                if pts > 0 {
                                    Text("+\(pts) pts")
                                        .font(.subheadline.weight(.heavy))
                                        .foregroundStyle(Color(hex: 0x3DBE6B))
                                }
                                if let streak = p.streakAtTime, streak >= 2 {
                                    Text("🔥 \(streak) streak")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color(hex: 0xFF6B35))
                                }
                            }
                        }
                    }
                    .foregroundStyle(Theme.accent)
                } else {
                    HStack(spacing: 10) {
                        pickButton(.away, label: match.away.shortName)
                        if match.league.group == .soccer {
                            pickButton(.draw, label: "Draw")
                        }
                        pickButton(.home, label: match.home.shortName)
                    }
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .overlay(alignment: .top) {
                if showPickCelebration, let pts = existing?.pointsEarned, pts > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("You called it! +\(pts) pts")
                        if let streak = existing?.streakAtTime, streak >= 2 {
                            Text("🔥 \(streak)")
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: 0x3DBE6B), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, -8)
                }
            }
            .clipped()
            .animation(.spring(response: 0.4), value: showPickCelebration)
            .sensoryFeedback(.success, trigger: showPickCelebration) { _, new in new }
            .task(id: match.id) {
                predictions.resolveIfNeeded(for: match)
            }
            .onChange(of: predictions.prediction(for: match.id)?.isCorrect) { _, newValue in
                if newValue == true {
                    withAnimation { showPickCelebration = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showPickCelebration = false }
                    }
                }
            }
        }
    }

    private func pickButton(_ outcome: PickOutcome, label: String) -> some View {
        Button {
            predictions.place(pick: outcome, for: match)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: outcome.systemImage)
                    .font(.title3)
                Text(label)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(match.state != .pre)
    }

    // MARK: Head-to-Head

    @ViewBuilder private var headToHeadSection: some View {
        if let h2h = gameSummary?.headToHead {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                    Text("Head to Head")
                    Spacer()
                    Text(h2h.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)

                HStack(spacing: 0) {
                    h2hStatColumn(value: "\(h2h.awayWins)", label: match.away.shortName)
                    if h2h.draws > 0 {
                        h2hStatColumn(value: "\(h2h.draws)", label: "Draws")
                    }
                    h2hStatColumn(value: "\(h2h.homeWins)", label: match.home.shortName)
                }
                .padding(.horizontal, 8)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func h2hStatColumn(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Highlights

    @ViewBuilder private var highlightsSection: some View {
        if let highlights = gameSummary?.highlights, !highlights.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle.fill")
                    Text("Highlights")
                    Spacer()
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(highlights) { clip in
                            HighlightCard(clip: clip)
                        }
                    }
                }
            }
        }
    }

    // MARK: Game Centre (premium ESPN data)

    @ViewBuilder private var gameCenterSection: some View {
        if entitlements.isPremium {
            gameCenterContent
        } else {
            ZStack {
                gameCenterContent
                    .blur(radius: 8)
                    .allowsHitTesting(false)
                PremiumGateOverlay(
                    icon: "sportscourt.fill",
                    title: "Game Centre",
                    description: "Players, live stats, standings and deep team analytics.",
                    showPaywall: $showPaywall
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var gameCenterContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sportscourt.fill")
                Text("Game Centre")
                Spacer()
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)

            // Tab bar
            HStack(spacing: 0) {
                ForEach(availableGameCenterTabs) { tab in
                    Button {
                        withAnimation(.snappy) { gameCenterTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(gameCenterTab == tab ? .white : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                gameCenterTab == tab ? Theme.accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))

            Group {
                switch effectiveGameCenterTab {
                case .players: gameCenterPlayersTab
                case .gameStats: gameCenterStatsTab
                case .standings: gameCenterStandingsTab
                }
            }
        }
    }

    @ViewBuilder private var gameCenterPlayersTab: some View {
        Picker("Team", selection: $selectedGameCenterTeam) {
            Text(match.away.shortName).tag(GameCenterTeam.away)
            Text(match.home.shortName).tag(GameCenterTeam.home)
        }
        .pickerStyle(.segmented)

        selectedTeamHub

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
            gameCenterTile(title: "Leaders", subtitle: match.league.shortName, systemImage: "chart.bar.fill") {
                LeadersView(league: match.league)
            }
            gameCenterTile(title: "Injuries", subtitle: "Report", systemImage: "cross.case.fill") {
                InjuriesView(league: match.league)
            }
        }
    }

    @ViewBuilder private var gameCenterStatsTab: some View {
        if let summary = gameSummary, !summary.isEmpty {
            inGameStatsBody(summary: summary)
        } else if match.state == .pre {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                Text("Stats available once the game begins")
            }
            .font(.callout)
            .foregroundStyle(Theme.textSecondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        } else if isLoadingGameSummary && !didAttemptGameSummaryLoad {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("Loading stats...")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
        } else {
            gameStatsUnavailableState
        }
    }

    private var gameStatsUnavailableState: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(Theme.textSecondary)
            Text(match.state == .live ? "Stats are not available yet." : "Stats are not available for this game.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Try Again") {
                Task { await loadGameSummary() }
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var gameCenterStandingsTab: some View {
        MatchStandingsPreview(
            league: match.league,
            highlightedTeamIDs: Set([match.away.teamID, match.home.teamID].compactMap { $0 })
        )
    }

    @ViewBuilder private var selectedTeamHub: some View {
        let team = selectedGameCenterTeam == .away ? match.away : match.home
        if let teamID = team.teamID {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TeamLogo(url: team.logoURL, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.displayName)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let record = team.record, !record.isEmpty {
                            Text(record)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                }

                TeamRosterPreview(league: match.league,
                                  teamID: teamID,
                                  teamName: team.shortName,
                                  athletes: rosterPreviewByTeamID[teamID] ?? [],
                                  selectedPosition: $selectedRosterPosition,
                                  isShowingAll: $isShowingFullRosterPreview)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    gameCenterTile(title: "Players", subtitle: "Roster", systemImage: "person.3.fill") {
                        TeamRosterView(league: match.league, teamID: teamID, teamName: team.shortName)
                    }
                    gameCenterTile(title: "Bios", subtitle: "Profiles", systemImage: "person.text.rectangle") {
                        TeamRosterView(league: match.league, teamID: teamID, teamName: team.shortName)
                    }
                    gameCenterTile(title: "Stats", subtitle: "Season", systemImage: "chart.xyaxis.line") {
                        TeamRosterView(league: match.league, teamID: teamID, teamName: team.shortName)
                    }
                }
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private struct TeamRosterPreview: View {
        let league: League
        let teamID: String
        let teamName: String
        let athletes: [RosterAthlete]
        @Binding var selectedPosition: String?
        @Binding var isShowingAll: Bool

        private var positions: [String] {
            Array(Set(athletes.map(positionLabel))).sorted()
        }

        private var filteredAthletes: [RosterAthlete] {
            guard let selectedPosition else { return athletes }
            return athletes.filter { positionLabel(for: $0) == selectedPosition }
        }

        private var displayedAthletes: [RosterAthlete] {
            isShowingAll ? filteredAthletes : Array(filteredAthletes.prefix(5))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Players", systemImage: "person.3.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    NavigationLink("Full Roster") {
                        TeamRosterView(league: league, teamID: teamID, teamName: teamName)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                }

                if athletes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.accent)
                        Text("Loading players")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    positionFilter
                    VStack(spacing: 0) {
                        ForEach(displayedAthletes) { athlete in
                            NavigationLink {
                                PlayerDetailView(league: league, athlete: athlete)
                            } label: {
                                TeamRosterPreviewRow(athlete: athlete, position: positionLabel(for: athlete))
                            }
                            .buttonStyle(.plain)
                            if athlete.id != displayedAthletes.last?.id {
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if filteredAthletes.count > 5 {
                        Button {
                            withAnimation(.snappy) { isShowingAll.toggle() }
                        } label: {
                            HStack {
                                Text(isShowingAll ? "Show fewer" : "More players")
                                    .font(.subheadline.weight(.bold))
                                Spacer()
                                Image(systemName: isShowingAll ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(12)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        private var positionFilter: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    positionChip(title: "All", isSelected: selectedPosition == nil) {
                        selectedPosition = nil
                        isShowingAll = false
                    }
                    ForEach(positions, id: \.self) { position in
                        positionChip(title: position, isSelected: selectedPosition == position) {
                            selectedPosition = position
                            isShowingAll = false
                        }
                    }
                }
            }
        }

        private func positionChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
            }
            .buttonStyle(.plain)
        }

        private func positionLabel(for athlete: RosterAthlete) -> String {
            athlete.position ?? athlete.positionName ?? "Position"
        }
    }

    private struct TeamRosterPreviewRow: View {
        let athlete: RosterAthlete
        let position: String

        var body: some View {
            HStack(spacing: 10) {
                PlayerHeadshot(url: athlete.headshotURL, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(athlete.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let jersey = athlete.jersey, !jersey.isEmpty {
                            Text("#\(jersey)")
                        }
                        Text(position)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if athlete.isInjured {
                    Image(systemName: "cross.case.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.live)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(10)
        }
    }

    private struct TeamPositionPreview: View {
        let sport: SportGroup
        let athletes: [RosterAthlete]

        private var plottedPlayers: [PositionedAthlete] {
            Array(athletes.prefix(14)).enumerated().map { index, athlete in
                PositionedAthlete(athlete: athlete,
                                  point: SportPositionMapper.point(for: athlete, sport: sport, fallbackIndex: index))
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Player Positions", systemImage: sport.systemImage)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(sport.rawValue.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                }

                if athletes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.accent)
                        Text("Loading roster positions")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    VirtualFieldView(sport: sport, players: plottedPlayers)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(fieldAspectRatio, contentMode: .fit)
                }
            }
        }

        private var fieldAspectRatio: CGFloat {
            switch sport {
            case .basketball, .hockey: return 1.58
            case .baseball: return 1.05
            case .football, .golf, .racing, .tennis, .cycling, .wrestling, .esports: return 1.9
            case .soccer: return 1.52
            }
        }
    }

    private struct PositionedAthlete: Identifiable {
        let athlete: RosterAthlete
        let point: CGPoint
        var id: String { athlete.id }
    }

    private struct VirtualFieldView: View {
        let sport: SportGroup
        let players: [PositionedAthlete]

        var body: some View {
            GeometryReader { proxy in
                ZStack {
                    fieldBackground
                    fieldMarkings
                    ForEach(players) { player in
                        PlayerPositionToken(athlete: player.athlete)
                            .position(x: player.point.x * proxy.size.width,
                                      y: player.point.y * proxy.size.height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }

        private var fieldBackground: some View {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        }

        private var backgroundColor: Color {
            switch sport {
            case .soccer, .football: return Color(hex: 0x153B2C)
            case .basketball: return Color(hex: 0x5A3520)
            case .baseball: return Color(hex: 0x234329)
            case .hockey: return Color(hex: 0xD7E4EF)
            case .golf: return Color(hex: 0x1B3B2A)
            case .racing: return Color(hex: 0x2A2C31)
            case .tennis: return Color(hex: 0x3B6E2A)
            case .cycling, .wrestling, .esports: return Color(hex: 0x2A2C31)
            }
        }

        @ViewBuilder private var fieldMarkings: some View {
            switch sport {
            case .soccer:
                SoccerFieldLines()
            case .football:
                FootballFieldLines()
            case .basketball:
                BasketballCourtLines()
            case .baseball:
                BaseballDiamondLines()
            case .hockey:
                HockeyRinkLines()
            case .golf, .racing, .tennis, .cycling, .wrestling, .esports:
                EmptyView()
            }
        }
    }

    private struct PlayerPositionToken: View {
        let athlete: RosterAthlete

        var body: some View {
            VStack(spacing: 2) {
                Text(initials)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.45)))
                Text(label)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 48)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.58), in: Capsule())
            }
        }

        private var initials: String {
            let parts = athlete.displayName.split(separator: " ")
            let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
            return letters.isEmpty ? (athlete.position ?? "P") : letters.uppercased()
        }

        private var label: String {
            if let jersey = athlete.jersey, !jersey.isEmpty {
                return "#\(jersey) \(position)"
            }
            return position
        }

        private var position: String {
            athlete.position ?? athlete.positionName ?? "POS"
        }
    }

    private enum SportPositionMapper {
        static func point(for athlete: RosterAthlete, sport: SportGroup, fallbackIndex: Int) -> CGPoint {
            let key = ((athlete.position ?? athlete.positionName ?? "") as NSString)
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
            let mapped: CGPoint?
            switch sport {
            case .soccer: mapped = soccerPoint(for: key)
            case .football: mapped = footballPoint(for: key)
            case .basketball: mapped = basketballPoint(for: key)
            case .baseball: mapped = baseballPoint(for: key)
            case .hockey: mapped = hockeyPoint(for: key)
            case .golf, .racing, .tennis, .cycling, .wrestling, .esports: mapped = nil
            }
            return jitter(mapped ?? fallbackPoint(for: fallbackIndex), index: fallbackIndex)
        }

        private static func jitter(_ point: CGPoint, index: Int) -> CGPoint {
            let offsets: [CGFloat] = [-0.035, 0.035, 0, -0.02, 0.02]
            let dx = offsets[index % offsets.count]
            let dy = offsets[(index / offsets.count) % offsets.count] * 0.7
            return CGPoint(x: min(0.92, max(0.08, point.x + dx)),
                           y: min(0.9, max(0.1, point.y + dy)))
        }

        private static func fallbackPoint(for index: Int) -> CGPoint {
            let columns: [CGFloat] = [0.2, 0.4, 0.6, 0.8]
            let rows: [CGFloat] = [0.25, 0.42, 0.6, 0.77]
            return CGPoint(x: columns[index % columns.count], y: rows[(index / columns.count) % rows.count])
        }

        private static func soccerPoint(for key: String) -> CGPoint? {
            if key.contains("goal") || key == "gk" { return CGPoint(x: 0.5, y: 0.88) }
            if key.contains("back") || key.contains("def") || ["cb", "lb", "rb", "lwb", "rwb"].contains(key) { return CGPoint(x: 0.5, y: 0.68) }
            if key.contains("mid") || ["cm", "dm", "am", "lm", "rm"].contains(key) { return CGPoint(x: 0.5, y: 0.47) }
            if key.contains("wing") || key.contains("forward") || key.contains("striker") || ["fw", "st", "cf", "lw", "rw"].contains(key) { return CGPoint(x: 0.5, y: 0.24) }
            return nil
        }

        private static func footballPoint(for key: String) -> CGPoint? {
            if key == "qb" || key.contains("quarterback") { return CGPoint(x: 0.5, y: 0.45) }
            if ["rb", "fb"].contains(key) || key.contains("running") { return CGPoint(x: 0.5, y: 0.58) }
            if key == "wr" || key.contains("receiver") { return CGPoint(x: 0.78, y: 0.38) }
            if key == "te" || key.contains("tight") { return CGPoint(x: 0.64, y: 0.42) }
            if ["c", "g", "og", "ot", "t"].contains(key) || key.contains("offensive") { return CGPoint(x: 0.5, y: 0.35) }
            if key.contains("linebacker") || key == "lb" { return CGPoint(x: 0.5, y: 0.62) }
            if key.contains("corner") || key == "cb" { return CGPoint(x: 0.78, y: 0.68) }
            if key.contains("safety") || ["s", "fs", "ss"].contains(key) { return CGPoint(x: 0.5, y: 0.78) }
            if key.contains("defensive") || ["dt", "de", "dl"].contains(key) { return CGPoint(x: 0.5, y: 0.55) }
            if key.contains("kicker") || key == "k" || key == "p" { return CGPoint(x: 0.2, y: 0.82) }
            return nil
        }

        private static func basketballPoint(for key: String) -> CGPoint? {
            if key.contains("point") || key == "pg" { return CGPoint(x: 0.5, y: 0.78) }
            if key.contains("shooting") || key == "sg" { return CGPoint(x: 0.72, y: 0.62) }
            if key.contains("small") || key == "sf" { return CGPoint(x: 0.28, y: 0.62) }
            if key.contains("power") || key == "pf" { return CGPoint(x: 0.68, y: 0.34) }
            if key.contains("center") || key == "c" { return CGPoint(x: 0.5, y: 0.24) }
            if key.contains("guard") { return CGPoint(x: 0.5, y: 0.68) }
            if key.contains("forward") { return CGPoint(x: 0.5, y: 0.38) }
            return nil
        }

        private static func baseballPoint(for key: String) -> CGPoint? {
            if key == "p" || key.contains("pitcher") { return CGPoint(x: 0.5, y: 0.52) }
            if key == "c" || key.contains("catcher") { return CGPoint(x: 0.5, y: 0.84) }
            if key == "1b" || key.contains("first") { return CGPoint(x: 0.72, y: 0.61) }
            if key == "2b" || key.contains("second") { return CGPoint(x: 0.62, y: 0.42) }
            if key == "3b" || key.contains("third") { return CGPoint(x: 0.28, y: 0.61) }
            if key == "ss" || key.contains("shortstop") { return CGPoint(x: 0.38, y: 0.42) }
            if key == "lf" || key.contains("left") { return CGPoint(x: 0.22, y: 0.22) }
            if key == "cf" || key.contains("center") { return CGPoint(x: 0.5, y: 0.14) }
            if key == "rf" || key.contains("right") { return CGPoint(x: 0.78, y: 0.22) }
            if key.contains("designated") || key == "dh" { return CGPoint(x: 0.86, y: 0.8) }
            return nil
        }

        private static func hockeyPoint(for key: String) -> CGPoint? {
            if key.contains("goal") || key == "g" { return CGPoint(x: 0.5, y: 0.86) }
            if key.contains("defense") || key == "d" { return CGPoint(x: 0.5, y: 0.62) }
            if key.contains("center") || key == "c" { return CGPoint(x: 0.5, y: 0.42) }
            if key.contains("left") || key == "lw" { return CGPoint(x: 0.3, y: 0.32) }
            if key.contains("right") || key == "rw" { return CGPoint(x: 0.7, y: 0.32) }
            if key.contains("wing") { return CGPoint(x: 0.5, y: 0.32) }
            return nil
        }
    }

    private struct SoccerFieldLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 16, dy: 12)
                    path.addRect(rect)
                    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    path.addEllipse(in: CGRect(x: rect.midX - 36, y: rect.midY - 36, width: 72, height: 72))
                    path.addRect(CGRect(x: rect.midX - 54, y: rect.maxY - 50, width: 108, height: 50))
                    path.addRect(CGRect(x: rect.midX - 54, y: rect.minY, width: 108, height: 50))
                }
                .stroke(.white.opacity(0.35), lineWidth: 1.2)
            }
        }
    }

    private struct FootballFieldLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 14, dy: 12)
                    path.addRect(rect)
                    for index in 1..<10 {
                        let x = rect.minX + rect.width * CGFloat(index) / 10
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    }
                }
                .stroke(.white.opacity(0.32), lineWidth: 1)
            }
        }
    }

    private struct BasketballCourtLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 16, dy: 12)
                    path.addRect(rect)
                    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    path.addEllipse(in: CGRect(x: rect.midX - 28, y: rect.midY - 28, width: 56, height: 56))
                    path.addRect(CGRect(x: rect.midX - 42, y: rect.minY, width: 84, height: 52))
                    path.addRect(CGRect(x: rect.midX - 42, y: rect.maxY - 52, width: 84, height: 52))
                }
                .stroke(.white.opacity(0.34), lineWidth: 1.2)
            }
        }
    }

    private struct BaseballDiamondLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let w = proxy.size.width
                    let h = proxy.size.height
                    let home = CGPoint(x: w * 0.5, y: h * 0.84)
                    let first = CGPoint(x: w * 0.72, y: h * 0.62)
                    let second = CGPoint(x: w * 0.5, y: h * 0.4)
                    let third = CGPoint(x: w * 0.28, y: h * 0.62)
                    path.move(to: home)
                    path.addLine(to: first)
                    path.addLine(to: second)
                    path.addLine(to: third)
                    path.closeSubpath()
                    path.move(to: home)
                    path.addLine(to: CGPoint(x: w * 0.16, y: h * 0.16))
                    path.move(to: home)
                    path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.16))
                    path.addEllipse(in: CGRect(x: w * 0.44, y: h * 0.46, width: w * 0.12, height: h * 0.08))
                }
                .stroke(.white.opacity(0.36), lineWidth: 1.2)
            }
        }
    }

    private struct HockeyRinkLines: View {
        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 16, dy: 12)
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 28, height: 28))
                    for x in [rect.minX + rect.width * 0.25, rect.midX, rect.minX + rect.width * 0.75] {
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    }
                    path.addEllipse(in: CGRect(x: rect.midX - 24, y: rect.midY - 24, width: 48, height: 48))
                }
                .stroke(Color(hex: 0x2458A6).opacity(0.5), lineWidth: 1.2)
            }
        }
    }

    private func gameCenterTile<Destination: View>(title: String, subtitle: String, systemImage: String,
                                                   @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func gameCenterLink<Destination: View>(title: String, subtitle: String, systemImage: String,
                                                   @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcesHeader

            if playlists.allChannels.count >= 2 && !isPickingMultiscreen {
                splitScreenButton
            }

            if isPickingMultiscreen {
                multiscreenPickerContent
            } else if playlists.allChannels.isEmpty {
                noPlaylistWatchOptions
            } else if showingAllChannels {
                channelSearchField
                if filteredMatchedSources.isEmpty {
                    Text("No matched sources fit that search.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredMatchedSources) { source in
                            SourceRow(name: source.channel.name,
                                      subtitle: source.channel.group ?? source.channel.playlistName,
                                      logoURL: source.channel.logoURL,
                                      score: source.score,
                                      isPicking: false,
                                      isSelected: false) {
                                handleSourceTap(source.channel)
                            }
                        }
                    }
                }
            } else if isRankingSources && rankedSources.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Matching your channels to this game…")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            } else if rankedSources.isEmpty {
                emptyMatches
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredMatchedSources) { source in
                        SourceRow(name: source.channel.name,
                                  subtitle: source.channel.group ?? source.channel.playlistName,
                                  logoURL: source.channel.logoURL,
                                  score: source.score,
                                  isPicking: false,
                                  isSelected: false) {
                            handleSourceTap(source.channel)
                        }
                    }
                    if rankedSources.count > 3 {
                        Button {
                            withAnimation { showingAllChannels = true }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "ellipsis.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                Text("More sources")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text("\(rankedSources.count - 3)+")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Multiscreen game picker

    @ViewBuilder private var multiscreenPickerContent: some View {
        // Slot 1: This game
        multiscreenGameSlot(
            label: "\(match.shortName) — This Game",
            leagueShortName: match.league.shortName,
            sources: Array(rankedSources.prefix(3)),
            matchID: match.id,
            canRemove: false
        )

        // Additional live games section
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
                Text("Add Live Games")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(multiscreenSlots.count)/4 slots")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }

            Picker("Sport filter", selection: $multiscreenShowAllSports) {
                Text("My Favorites").tag(false)
                Text("All Sports").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: multiscreenShowAllSports) { _, _ in
                liveMatchesForMultiscreen = []
                multiscreenSportFilter = nil
                Task { await loadLiveGamesForMultiscreen() }
            }

            if isLoadingLiveGames {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Finding live games in your leagues…")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            } else if liveMatchesForMultiscreen.isEmpty {
                Text("No other live games found right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                // Sport filter chips
                let availableSports = SportGroup.allCases.filter { sport in
                    liveMatchesForMultiscreen.contains { $0.match.league.group == sport }
                }
                if availableSports.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            multiscreenSportChip(title: "All", systemImage: "sportscourt", sport: nil)
                            ForEach(availableSports) { sport in
                                multiscreenSportChip(title: sport.rawValue, systemImage: sport.systemImage, sport: sport)
                            }
                        }
                    }
                }

                let filtered = multiscreenSportFilter == nil
                    ? liveMatchesForMultiscreen
                    : liveMatchesForMultiscreen.filter { $0.match.league.group == multiscreenSportFilter }

                if filtered.isEmpty {
                    Text("No live games for this sport right now.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { option in
                            let isAdded = multiscreenSlots.contains { $0.matchID == option.match.id }
                            multiscreenLiveGameCard(option: option, isAdded: isAdded)
                        }
                    }
                }
            }
        }
    }

    private func multiscreenGameSlot(label: String, leagueShortName: String, sources: [RankedSource], matchID: String, canRemove: Bool) -> some View {
        let selectedChannelID = multiscreenSlots.first { $0.matchID == matchID }?.channel?.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(leagueShortName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if canRemove {
                    Button {
                        withAnimation(.snappy) {
                            multiscreenSlots.removeAll { $0.matchID == matchID }
                        }
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.live)
                    }
                    .buttonStyle(.plain)
                }
            }

            if sources.isEmpty {
                Text("No matching sources found for this game.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sources) { source in
                            let isSelected = selectedChannelID == source.channel.id
                            Button {
                                multiscreenSelectChannel(source.channel, forMatchID: matchID)
                            } label: {
                                Text(source.channel.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                                    .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selectedChannelID != nil ? Theme.accent.opacity(0.45) : Theme.hairline))
    }

    @ViewBuilder private func multiscreenLiveGameCard(option: LiveGameOption, isAdded: Bool) -> some View {
        let canAddMore = multiscreenSlots.count < 4
        let selectedChannelID = multiscreenSlots.first { $0.matchID == option.match.id }?.channel?.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // MatchRow-style match info
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(option.match.league.shortName)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Label(option.match.statusDetail, systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.live, in: Capsule())
                    }
                    VStack(spacing: 8) {
                        multiscreenTeamRow(option.match.away)
                        multiscreenTeamRow(option.match.home)
                    }
                }

                Button {
                    withAnimation(.snappy) { toggleMultiscreenLiveGame(option) }
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                } label: {
                    Image(systemName: isAdded ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isAdded ? Theme.live : (canAddMore ? Theme.accent : Theme.textSecondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!isAdded && !canAddMore)
                .padding(.top, 2)
            }
            .padding(14)

            if isAdded {
                Divider().overlay(Theme.hairline).padding(.horizontal, 14)
                if option.topSources.isEmpty {
                    Text("No matching sources found.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(14)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(option.topSources) { source in
                                let isSelected = selectedChannelID == source.channel.id
                                Button {
                                    multiscreenSelectChannel(source.channel, forMatchID: option.match.id)
                                } label: {
                                    Text(source.channel.name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                        .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                                        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isAdded ? Theme.accent.opacity(0.45) : Theme.hairline))
    }

    private func multiscreenTeamRow(_ team: TeamSide) -> some View {
        HStack(spacing: 10) {
            TeamLogo(url: team.logoURL, size: 28)
            Text(team.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            if let score = team.score {
                Text(score)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(team.isWinner ? Theme.textPrimary : Theme.textSecondary)
            }
        }
    }

    private func multiscreenSportChip(title: String, systemImage: String, sport: SportGroup?) -> some View {
        let isSelected = multiscreenSportFilter == sport
        return Button {
            withAnimation(.snappy) { multiscreenSportFilter = sport }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func multiscreenSelectChannel(_ channel: Channel, forMatchID matchID: String) {
        if let idx = multiscreenSlots.firstIndex(where: { $0.matchID == matchID }) {
            multiscreenSlots[idx].channel = channel
        }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func toggleMultiscreenLiveGame(_ option: LiveGameOption) {
        if let idx = multiscreenSlots.firstIndex(where: { $0.matchID == option.match.id }) {
            multiscreenSlots.remove(at: idx)
        } else {
            guard multiscreenSlots.count < 4 else { return }
            multiscreenSlots.append(MultiscreenSlot(
                matchID: option.match.id,
                matchShortName: option.match.shortName,
                channel: option.topSources.first?.channel
            ))
        }
    }

    private var channelSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search channels", text: $channelQuery)
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
            if !channelQuery.isEmpty {
                Button {
                    channelQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var sourcesHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if playlists.allChannels.isEmpty {
                    // No playlist connected: nothing to "match", so point the
                    // viewer to where the game officially streams instead.
                    Text("Where to Watch")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    if !watchLinks.isEmpty {
                        Text("Tap a broadcaster to open their live stream.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text(showingAllChannels ? "More Matched Sources" : "Matched Sources")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Only algorithm-detected game streams are shown here.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if !playlists.allChannels.isEmpty && rankedSources.count > 3 {
                Button(showingAllChannels ? "Top" : "More") {
                    withAnimation {
                        showingAllChannels.toggle()
                        channelQuery = ""
                        resetMultiscreenSelection()
                    }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Prominent entry point into multiscreen so split screen is easy to find.
    private var splitScreenButton: some View {
        Button {
            toggleMultiscreenPicking()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Split Screen")
                        .font(.subheadline.weight(.bold))
                    Text("Watch up to 4 sources at once")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start split screen selection")
    }

    private var multiscreenFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label("\(multiscreenSlots.count) game\(multiscreenSlots.count == 1 ? "" : "s")", systemImage: "rectangle.grid.2x2")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(canStartMultiscreen ? "Tap Watch to begin" : "Select a source for each game")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { resetMultiscreenSelection() }
                }
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    startMultiscreen()
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .foregroundStyle(.white)
                .background(canStartMultiscreen ? Theme.accent : Theme.accent.opacity(0.36),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(!canStartMultiscreen)
            }
        }
        .padding(12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var canStartMultiscreen: Bool {
        selectedMultiscreenChannels.count >= 2
    }

    private func toggleMultiscreenPicking() {
        guard entitlements.isPremium else {
            showPaywall = true
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            return
        }
        withAnimation {
            if isPickingMultiscreen {
                resetMultiscreenSelection()
            } else {
                isPickingMultiscreen = true
                multiscreenSportFilter = nil
                multiscreenSlots = [MultiscreenSlot(
                    matchID: match.id,
                    matchShortName: match.shortName,
                    channel: rankedSources.first?.channel
                )]
                Task { await loadLiveGamesForMultiscreen() }
            }
        }
    }

    private func handleSourceTap(_ channel: Channel) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        playingChannel = channel
    }

    private func startMultiscreen() {
        let channels = Array(selectedMultiscreenChannels.prefix(4))
        guard channels.count >= 2 else { return }
        multiscreenSession = MultiscreenSession(channels: channels)
        resetMultiscreenSelection()
    }

    private func resetMultiscreenSelection() {
        isPickingMultiscreen = false
        multiscreenSlots = []
        liveMatchesForMultiscreen = []
    }

    private func loadLiveGamesForMultiscreen() async {
        guard !isLoadingLiveGames else { return }
        isLoadingLiveGames = true
        defer { isLoadingLiveGames = false }

        let service = ESPNService()
        let leagues = multiscreenShowAllSports ? League.all : prefs.followedLeagues
        let allChannels = playlists.allChannels
        let preferredLanguages = prefs.preferredStreamLanguages
        let currentMatchID = match.id

        // Phase 1: fetch all league scoreboards in parallel
        var liveMatches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask {
                    guard let matches = try? await service.scoreboard(for: league) else { return [] }
                    return Array(matches.filter { $0.state == .live && $0.id != currentMatchID }.prefix(2))
                }
            }
            for await matches in group {
                liveMatches.append(contentsOf: matches)
            }
        }

        guard !Task.isCancelled else { return }

        // Phase 2: rank channels for every live match in parallel
        var options: [LiveGameOption] = []
        await withTaskGroup(of: LiveGameOption.self) { group in
            for liveMatch in liveMatches {
                group.addTask {
                    let ranked = await Task.detached(priority: .background) {
                        SourceMatcher.rank(match: liveMatch, channels: allChannels, preferredLanguages: preferredLanguages)
                    }.value
                    return LiveGameOption(match: liveMatch, topSources: Array(ranked.prefix(3)))
                }
            }
            for await option in group {
                options.append(option)
            }
        }

        liveMatchesForMultiscreen = options
    }

    /// Broadcasters carrying this game, each linking out to where it streams.
    /// Only used before the viewer connects a playlist.
    private var watchLinks: [WatchLink] {
        var seen: Set<String> = []
        return match.broadcasts.compactMap { broadcaster -> WatchLink? in
            let name = broadcaster.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            guard let url = Self.streamingURL(for: name) else { return nil }
            return WatchLink(name: name, url: url)
        }
    }

    /// Shown when no playlist is connected: broadcaster shortcut buttons for
    /// known networks. Only rendered when watchLinks is non-empty.
    @ViewBuilder private var noPlaylistWatchOptions: some View {
        FlowLayout(spacing: 10) {
            ForEach(watchLinks) { link in
                broadcasterButton(link)
            }
        }
    }

    private func broadcasterButton(_ link: WatchLink) -> some View {
        Button {
            browsingWatchLink = link
        } label: {
            HStack(spacing: 6) {
                Text(link.name)
                    .font(.subheadline.weight(.bold))
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch on \(link.name)")
        .accessibilityHint("Opens the \(link.name) live stream")
    }

    private var noPlaylistsHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.and.film")
                .font(.title)
                .foregroundStyle(Theme.textSecondary)
            Text("Connect a personal subscription playlist in the Playlists tab.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var emptyMatches: some View {
        VStack(spacing: 8) {
            Text("No channels matched this game automatically.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Browse all channels") { withAnimation { showingAllChannels = true } }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// Maps an ESPN broadcast network name to where it streams online. Matching
    /// is done on a lowercased substring so entries like "ESPN2" or "NBC Sports"
    /// resolve to the right service. Unknown broadcasters fall back to a web
    /// search so the arrow always leads somewhere useful.
    static func streamingURL(for broadcaster: String) -> URL? {
        let key = broadcaster.lowercased()
        // Order matters: more specific keys (e.g. "espn+") must precede their
        // shorter prefixes ("espn").
        let known: [(needle: String, url: String)] = [
            ("espn+", "https://plus.espn.com"),
            ("espn", "https://www.espn.com/watch/"),
            ("abc", "https://abc.com/watch-live"),
            ("nbcsn", "https://www.nbcsports.com/live"),
            ("nbc sports", "https://www.nbcsports.com/live"),
            ("nbc", "https://www.nbc.com/live"),
            ("peacock", "https://www.peacocktv.com"),
            ("cbs", "https://www.paramountplus.com/live-tv/"),
            ("paramount", "https://www.paramountplus.com"),
            ("fs1", "https://www.foxsports.com/live"),
            ("fs2", "https://www.foxsports.com/live"),
            ("fox", "https://www.foxsports.com/live"),
            ("tnt", "https://www.max.com"),
            ("tbs", "https://www.max.com"),
            ("max", "https://www.max.com"),
            ("prime", "https://www.amazon.com/gp/video/storefront"),
            ("amazon", "https://www.amazon.com/gp/video/storefront"),
            ("apple", "https://tv.apple.com"),
            ("nfl network", "https://www.nfl.com/network/watch/nfl-network-live"),
            ("nfl", "https://www.nfl.com/plus/"),
            ("nba tv", "https://www.nba.com/watch"),
            ("nhl network", "https://www.nhl.com/tv"),
            ("mlb network", "https://www.mlb.com/network"),
            ("golf channel", "https://www.nbcsports.com/golf"),
            ("tennis channel", "https://www.tennischannel.com"),
            ("usa network", "https://www.usanetwork.com/live"),
            ("sky sports", "https://www.skysports.com/watch"),
            ("sky sport", "https://www.skysports.com/watch"),
            ("tnt sports", "https://www.tntsports.co.uk"),
            ("dazn", "https://www.dazn.com"),
            ("bein", "https://www.beinsports.com"),
            ("telemundo", "https://www.telemundo.com/now"),
            ("univision", "https://www.univision.com"),
            ("tudn", "https://www.tudn.com")
        ]
        return known.first(where: { key.contains($0.needle) }).flatMap { URL(string: $0.url) }
    }
}

/// A broadcaster carrying a match, linking out to where it streams. Surfaced
/// before the viewer connects a playlist.
private struct WatchLink: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
}

private struct MultiscreenSlot: Identifiable {
    let id = UUID()
    let matchID: String
    let matchShortName: String
    var channel: Channel?
}

private struct LiveGameOption: Identifiable {
    let id: String
    let match: Match
    let topSources: [RankedSource]

    nonisolated init(match: Match, topSources: [RankedSource]) {
        self.id = match.id
        self.match = match
        self.topSources = topSources
    }
}

private enum GameCenterTeam: String, Hashable {
    case away
    case home
}

private struct MatchStandingsPreview: View {
    let league: League
    let highlightedTeamIDs: Set<String>
    @State private var groups: [StandingsGroup] = []
    @State private var isLoading = true
    private let service = ESPNService()

    private var previewRows: [StandingRow] {
        let allRows = uniqueRows(from: groups)
        let highlighted = allRows.filter { highlightedTeamIDs.contains($0.teamID) }
        let topRows = allRows.prefix(5).filter { !highlightedTeamIDs.contains($0.teamID) }
        return Array((highlighted + topRows).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.number")
                Text("Standings")
                Spacer()
                NavigationLink("Full Table") {
                    StandingsView(league: league)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.textPrimary)

            if isLoading && previewRows.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Loading table")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if previewRows.isEmpty {
                Text("Standings are not available for this league right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    standingsHeader
                    ForEach(Array(previewRows.enumerated()), id: \.element.id) { index, row in
                        MatchStandingPreviewRow(rank: rank(for: row), row: row, isHighlighted: highlightedTeamIDs.contains(row.teamID))
                        if index < previewRows.count - 1 {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
        .task { await load() }
    }

    private var standingsHeader: some View {
        HStack(spacing: 8) {
            Text("#")
                .frame(width: 24, alignment: .center)
            Text("Team")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Record")
                .frame(width: 58, alignment: .trailing)
            Text("PCT/GB")
                .frame(width: 54, alignment: .trailing)
            Text("Strk")
                .frame(width: 38, alignment: .trailing)
        }
        .font(.caption2.weight(.heavy))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated)
    }

    private func rank(for row: StandingRow) -> Int {
        let allRows = uniqueRows(from: groups)
        guard let index = allRows.firstIndex(where: { $0.teamID == row.teamID }) else { return 0 }
        return index + 1
    }

    private func uniqueRows(from groups: [StandingsGroup]) -> [StandingRow] {
        var seen: Set<String> = []
        return groups.flatMap(\.rows).filter { row in
            seen.insert(row.teamID).inserted
        }
    }

    private func load() async {
        isLoading = true
        groups = (try? await service.standings(for: league)) ?? []
        isLoading = false
    }
}

private struct MatchStandingPreviewRow: View {
    let rank: Int
    let row: StandingRow
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(rank > 0 ? "\(rank)" : "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(isHighlighted ? Theme.accent : Theme.textSecondary)
                .frame(width: 24, alignment: .center)
            TeamLogo(url: row.logoURL, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.abbreviation.isEmpty ? row.displayName : row.abbreviation)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(row.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.record)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 58, alignment: .trailing)
            Text(row.gamesBack ?? row.winPercent ?? "-")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 54, alignment: .trailing)
            Text(row.streak?.isEmpty == false ? row.streak! : "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(streakColor)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHighlighted ? Theme.accent.opacity(0.12) : Color.clear)
    }

    private var streakColor: Color {
        guard let streak = row.streak?.lowercased() else { return Theme.textSecondary }
        if streak.hasPrefix("w") { return Color(hex: 0x37C871) }
        if streak.hasPrefix("l") { return Theme.live }
        return Theme.textSecondary
    }
}

private struct MultiscreenSession: Identifiable {
    let id = UUID()
    let channels: [Channel]
}

// MARK: - Source row

private struct SourceRow: View {
    let name: String
    let subtitle: String
    let logoURL: URL?
    let score: Int?
    let isPicking: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncImage(url: logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "play.tv")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if let score, !isPicking {
                    MatchStrengthBadge(score: score)
                }
                trailingIcon
            }
            .padding(12)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailingIcon: some View {
        if isPicking {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
        } else {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
        }
    }

    private var rowBackground: Color {
        isSelected ? Theme.accent.opacity(0.15) : Theme.surface
    }

    private var rowBorder: Color {
        isSelected ? Theme.accent : Theme.hairline
    }
}

/// Shows how confident the matcher is about a source.
private struct MatchStrengthBadge: View {
    let score: Int

    private var label: String {
        switch score {
        case 100...: return "Best"
        case 50..<100: return "Strong"
        case 25..<50: return "Likely"
        default: return "Possible"
        }
    }

    private var color: Color {
        switch score {
        case 100...: return Theme.accent
        case 50..<100: return Color(hex: 0x3DBE6B)
        default: return Theme.textSecondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Play by play view

private struct ScoringPlayRow: View {
    let play: PlayByPlayEntry
    let match: Match

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Text(play.period ?? "Game")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if let clock = play.clock {
                    Text(clock)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(play.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let away = play.awayScore, let home = play.homeScore {
                    Text("\(match.away.abbreviation) \(away) – \(home) \(match.home.abbreviation)")
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct PlayByPlaySectionView: View {
    let plays: [PlayByPlayEntry]
    let match: Match

    @State private var isExpanded = true
    @State private var showAll = false

    private var periods: [(String, [PlayByPlayEntry])] {
        var buckets: [(String, [PlayByPlayEntry])] = []
        var seen: [String: Int] = [:]
        for play in plays {
            let key = play.period ?? "Game"
            if let idx = seen[key] {
                buckets[idx].1.append(play)
            } else {
                seen[key] = buckets.count
                buckets.append((key, [play]))
            }
        }
        return buckets
    }

    private var displayedPlays: [PlayByPlayEntry] {
        showAll ? plays : Array(plays.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                    Text("Play by Play")
                    Spacer()
                    if match.state == .live {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.live)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(displayedPlays.enumerated()), id: \.element.id) { index, play in
                        PlayRowView(play: play, match: match)
                        if index < displayedPlays.count - 1 {
                            Divider().overlay(Theme.hairline).padding(.leading, 42)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))

                if plays.count > 20 {
                    Button {
                        withAnimation(.snappy) { showAll.toggle() }
                    } label: {
                        HStack {
                            Text(showAll ? "Show less" : "Show all \(plays.count) plays")
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Image(systemName: showAll ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct PlayRowView: View {
    let play: PlayByPlayEntry
    let match: Match

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Period + clock badge
            VStack(spacing: 2) {
                if let clock = play.clock {
                    Text(clock)
                        .font(.caption2.weight(.heavy).monospacedDigit())
                        .foregroundStyle(play.isScoringPlay ? Theme.textPrimary : Theme.textSecondary)
                }
            }
            .frame(width: 32, alignment: .center)

            // Optional team dot
            Circle()
                .fill(teamColor(abbreviation: play.teamAbbreviation))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            // Play text
            VStack(alignment: .leading, spacing: 2) {
                Text(play.text)
                    .font(.footnote.weight(play.isScoringPlay ? .semibold : .regular))
                    .foregroundStyle(play.isScoringPlay ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if play.isScoringPlay, let away = play.awayScore, let home = play.homeScore {
                    Text("\(match.away.abbreviation) \(away) – \(home) \(match.home.abbreviation)")
                        .font(.caption2.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(play.isScoringPlay ? Theme.accent.opacity(0.06) : Color.clear)
    }

    private func teamColor(abbreviation: String?) -> Color {
        guard let abbr = abbreviation, !abbr.isEmpty else { return Color.clear }
        if abbr.localizedCaseInsensitiveCompare(match.away.abbreviation) == .orderedSame {
            return Color(hex: 0x4A90E2)
        }
        if abbr.localizedCaseInsensitiveCompare(match.home.abbreviation) == .orderedSame {
            return Color(hex: 0xE24A6B)
        }
        return Theme.textSecondary.opacity(0.5)
    }
}

// MARK: - Highlight card

struct HighlightCard: View {
    let clip: MatchHighlight
    @State private var showSafari = false

    var body: some View {
        Button {
            if clip.webURL != nil { showSafari = true }
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSafari) {
            if let url = clip.webURL {
                #if os(iOS)
                SafariSheet(url: url).ignoresSafeArea()
                #endif
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Theme.surfaceElevated
                AsyncImage(url: clip.thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(width: 200, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                if let dur = clip.formattedDuration {
                    Text(dur)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            Text(clip.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(width: 200)
    }
}

// MARK: - In-app Safari browser

#if os(iOS)
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
#endif
