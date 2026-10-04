import SwiftUI

/// The reusable Basketball Game Center shell — tabs, polling wiring, premium/
/// spoiler gating, pregame/live/final/cache states. Provider-agnostic: every
/// subview it renders takes only canonical Basketball domain types, and the
/// provider identity (which client, which polling/cache, which league config)
/// is injected by the call site — see the `basketball/nba` and `basketball/wnba`
/// branches in `MatchDetailView`. No basketball league gets its own Game Center view.
struct BasketballGameCenterView<WatchContent: View, RelatedContent: View>: View {
    let match: Match
    let config: BasketballLeagueConfiguration
    let providerID: SportsDataProviderID
    @ViewBuilder let watchContent: () -> WatchContent
    @ViewBuilder let relatedContent: () -> RelatedContent
    @State private var model: BasketballGameCenterViewModel
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var revealed = false
    @State private var showingPaywall = false
    @State private var revision = 0
    @State private var fullRefresh = true

    init(match: Match, config: BasketballLeagueConfiguration, providerID: SportsDataProviderID,
         service: any BasketballGameCenterServing, cache: BasketballGameCenterCache,
         @ViewBuilder watchContent: @escaping () -> WatchContent,
         @ViewBuilder relatedContent: @escaping () -> RelatedContent) {
        self.match = match; self.config = config; self.providerID = providerID
        self.watchContent = watchContent; self.relatedContent = relatedContent
        _model = State(wrappedValue: BasketballGameCenterViewModel(service: service, cache: cache))
    }

    private var gameID: BasketballGameID? {
        guard match.league.path == config.leaguePath, let canonical = match.canonicalID,
              let raw = SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: providerID) else { return nil }
        return BasketballGameID.validated(raw, league: config.league)
    }
    private var snapshot: BasketballGameSnapshot? { model.snapshot?.gameID == gameID ? model.snapshot : nil }
    private var hideScore: Bool { preferences.spoilerFreeMode && (snapshot?.game?.status == .final || match.state == .final) && !revealed }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let game = snapshot?.game { BasketballGameHeaderView(game: game, league: match.league) }
                else {
                    VStack(spacing: 12) {
                        Text(match.shortName).font(.title2.bold()); Text(match.statusDetail).font(.subheadline)
                        if model.errors.isEmpty { ProgressView("Loading Game Centre") }
                    }.frame(maxWidth: .infinity).padding().background(Theme.surface)
                }
                watchContent()
                GameTabBar(tabs: BasketballGameTab.allCases, selection: Binding(
                    get: { model.selectedTab },
                    set: { fullRefresh = false; model.selectedTab = $0 }
                ))
                if model.showingCache {
                    Text("Saved data · \(snapshot?.fetchedAt.formatted(date: .abbreviated, time: .shortened) ?? "")").font(.caption).foregroundStyle(.secondary).padding(4)
                }
                if gameID == nil {
                    ContentUnavailableView("\(config.displayName) game unavailable", systemImage: "basketball", description: Text("Open this game from the \(config.displayName) schedule."))
                } else if entitlements.isPremium {
                    content(wide: geometry.size.width > 850)
                } else {
                    ScrollView {
                        PremiumGateOverlay(icon: "basketball", title: "Game Centre", description: "Live plays, player statistics and shot charts.", showPaywall: $showingPaywall)
                        relatedContent()
                    }
                }
            }.background(Theme.background).foregroundStyle(Theme.textPrimary)
        }.tint(Theme.accessibleAccent)
        .blur(radius: hideScore ? 12 : 0).accessibilityHidden(hideScore).allowsHitTesting(!hideScore)
        .overlay { if hideScore { Button("Reveal final score") { revealed = true }.padding().background(Theme.surface, in: Capsule()).accessibilityHidden(false) } }
        .sheet(isPresented: $showingPaywall) {
            #if os(tvOS)
            TVPaywallView()
            #else
            PaywallView()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { fullRefresh = true } }
        .task {
            var previous: Bool?
            for await connected in SportsConnectivity.changes() {
                guard !Task.isCancelled else { return }
                if connected, previous == false { fullRefresh = true; revision += 1 }
                previous = connected
            }
        }
        .task(id: "\(gameID?.providerID ?? ""):\(scenePhase == .active):\(model.selectedTab.id):\(revision)") {
            if let gameID { await model.run(gameID: gameID, active: scenePhase == .active, seed: seed(gameID), fullRefresh: fullRefresh) }
        }
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        VStack(spacing: 0) {
            if let error = model.errors[errorKey] ?? model.errors["overview"] { errorNotice(error) }
            if let snapshot, snapshot.fetchedAt != .distantPast || !model.isRefreshing {
                switch model.selectedTab {
                case .plays:
                    BasketballPlayByPlayView(plays: snapshot.plays, game: snapshot.game).id(snapshot.gameID)
                case .boxscore:
                    ScrollView { BasketballBoxScoreView(snapshot: snapshot, league: match.league, config: config).frame(maxWidth: 1000).frame(maxWidth: .infinity) }
                case .shots:
                    ScrollView {
                        VStack(spacing: 16) {
                            BasketballShotChartView(shots: snapshot.shots).frame(maxWidth: 460)
                            if wide { BasketballPlayByPlayView(plays: snapshot.plays.filter { $0.isFieldGoal }, game: snapshot.game).frame(maxHeight: 400) }
                        }.padding().frame(maxWidth: .infinity)
                    }
                case .overview:
                    GameOverviewScroll {
                        if let game = snapshot.game {
                            BasketballLineScoreView(game: game).padding(.horizontal, Theme.Spacing.md)
                        }

                        let timeline = BasketballGamePresentation.leadChangeTimeline(plays: snapshot.plays, game: snapshot.game)
                        GameDetailSection(title: "Scoring", actionTitle: "All plays", action: { fullRefresh = false; model.selectedTab = .plays }) {
                            EventTimeline(events: timeline, league: match.league, emptyText: "No lead changes yet.")
                        }

                        let leaders = BasketballGamePresentation.leaders(snapshot: snapshot)
                        if !leaders.isEmpty {
                            GameDetailSection(title: "Game Leaders") {
                                GameLeadersStrip(leaders: leaders)
                            }
                        }

                        if !snapshot.shots.isEmpty {
                            GameDetailSection(title: "Shot Chart", actionTitle: "Full chart", action: { fullRefresh = false; model.selectedTab = .shots }) {
                                BasketballShotChartView(shots: snapshot.shots).frame(maxWidth: 320)
                            }
                        }

                        let keyStats = BasketballGamePresentation.keyStats(awayStats: snapshot.awayTeamStats, homeStats: snapshot.homeTeamStats,
                                                                            awayName: snapshot.game?.away.displayName ?? "Away", homeName: snapshot.game?.home.displayName ?? "Home")
                        if !keyStats.isEmpty {
                            GameDetailSection(title: "Team Stats", actionTitle: "View all stats", action: { fullRefresh = false; model.selectedTab = .boxscore }) {
                                TeamStatsComparison(stats: keyStats, awayAbbreviation: snapshot.game?.away.tricode ?? "Away", homeAbbreviation: snapshot.game?.home.tricode ?? "Home")
                            }
                        }

                        let infoItems = BasketballGamePresentation.gameInfo(game: snapshot.game)
                        if !infoItems.isEmpty {
                            GameDetailSection(title: "Game Info") {
                                GameInfoCard(items: infoItems)
                            }
                        }

                        relatedContent()
                    }
                }
            } else { loading }
        }
    }

    private var errorKey: String {
        switch model.selectedTab {
        case .plays: return "plays"
        case .boxscore, .shots: return "overview"
        case .overview: return "overview"
        }
    }
    private func errorNotice(_ error: String) -> some View {
        VStack(spacing: 8) {
            if model.isBlocked {
                // A persistent host block (Akamai 403 / connection drop) won't clear on
                // its own timeline — offering Retry here would just repeat the failure.
                Text("\(config.displayName) data isn't available on this network.")
            } else {
                Text(model.selectedTab == .plays ? "Play-by-play is temporarily unavailable." : "Some game information is temporarily unavailable.")
                Button("Retry") { fullRefresh = true; revision += 1 }
            }
        }.font(.subheadline).padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private var loading: some View {
        VStack(spacing: 18) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surfaceElevated).frame(height: 64).redacted(reason: .placeholder) } }.padding()
    }
    private func seed(_ id: BasketballGameID) -> BasketballGame? {
        guard let awayID = match.away.teamID.flatMap(Int.init), let homeID = match.home.teamID.flatMap(Int.init) else { return nil }
        func team(_ id: Int, side: TeamSide) -> BasketballTeam {
            BasketballTeam(id: id, city: "", name: side.displayName, tricode: side.abbreviation, slug: nil,
                wins: nil, losses: nil, score: side.score.flatMap(Int.init), timeoutsRemaining: nil, inBonus: nil, periods: [], seed: nil)
        }
        return BasketballGame(id: id, gameCode: nil, start: match.date, away: team(awayID, side: match.away), home: team(homeID, side: match.home),
            status: match.state == .final ? .final : match.state == .live ? .live : .scheduled, rawStatus: nil, statusText: match.statusDetail,
            period: 0, regulationPeriods: 4, gameClock: nil, arena: nil, attendance: nil, officials: [],
            seriesGameNumber: nil, seriesText: nil, gameLabel: nil, gameSubLabel: nil, gameSubtype: nil,
            homeLeader: nil, awayLeader: nil, broadcasts: match.broadcasts)
    }
}
