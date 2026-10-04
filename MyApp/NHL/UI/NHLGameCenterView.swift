import SwiftUI

struct NHLGameCenterView<WatchContent: View, RelatedContent: View>: View {
    let match: Match
    @ViewBuilder let watchContent: () -> WatchContent
    @ViewBuilder let relatedContent: () -> RelatedContent
    @State private var model = NHLGameCenterViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var revealed = false
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var showingPaywall = false
    @State private var connectivityRevision = 0
    @State private var retryRevision = 0
    private var gameID: Int? {
        guard match.league.path == "hockey/nhl",
              let canonical = match.canonicalID,
              let raw = SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: .nhl) else { return nil }
        return Int(raw)
    }
    private var hideScore: Bool { preferences.spoilerFreeMode && (snapshot?.game?.status == .final || match.state == .final) && !revealed }
    private var snapshot: HockeyGameCenterSnapshot? { model.snapshot?.gameID == gameID ? model.snapshot : nil }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let game = snapshot?.game {
                    NHLGameHeaderView(game: game, league: match.league)
                } else {
                    VStack(spacing: 12) {
                        Text(match.shortName).font(.title2.bold())
                        Text(match.statusDetail).font(.subheadline)
                        if model.errors.isEmpty { ProgressView("Loading Game Centre") }
                    }.frame(maxWidth: .infinity).padding(24).background(Theme.surface)
                }
                watchContent()
                GameTabBar(tabs: NHLGameTab.allCases, selection: $model.selectedTab)
                if model.showingCache {
                    Text("Saved data · Last updated \(snapshot?.fetchedAt.formatted(date: .abbreviated, time: .shortened) ?? "unknown")").font(.caption).foregroundStyle(Theme.textSecondary).padding(6)
                }
                if gameID == nil {
                    ContentUnavailableView("NHL game unavailable", systemImage: "hockey.puck",
                        description: Text("Open this game from the NHL schedule to load its NHL Game Centre."))
                } else {
                    if entitlements.isPremium {
                        tabContent(wide: geometry.size.width > 850)
                    } else {
                        ScrollView {
                            VStack(spacing: 20) {
                                PremiumGateOverlay(icon: "hockey.puck", title: "Game Centre",
                                    description: "Live plays, player statistics and game analysis.", showPaywall: $showingPaywall)
                                relatedContent()
                            }
                        }
                    }
                }
            }
            .background(Theme.background)
            .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accessibleAccent)
        .blur(radius: hideScore ? 12 : 0)
        .accessibilityHidden(hideScore)
        .allowsHitTesting(!hideScore)
        .overlay {
            if hideScore {
                Button("Reveal final score") { revealed = true }
                    .padding().background(Theme.surface, in: Capsule())
                    .accessibilityHidden(false)
            }
        }
        .sheet(isPresented: $showingPaywall) {
            #if os(tvOS)
            TVPaywallView()
            #else
            PaywallView()
            #endif
        }
        .task {
            var wasConnected: Bool?
            for await connected in NHLConnectivity.changes() {
                guard !Task.isCancelled else { return }
                if connected, wasConnected == false, scenePhase == .active { connectivityRevision += 1 }
                wasConnected = connected
            }
        }
        .task(id: "\(gameID ?? 0):\(scenePhase == .active):\(connectivityRevision):\(retryRevision)") {
            if let gameID { await model.run(gameID: gameID, active: scenePhase == .active) }
        }
    }
    @ViewBuilder private func tabContent(wide: Bool) -> some View {
        switch model.selectedTab {
        case .plays:
            VStack(spacing: 0) {
                if let error = model.errors["plays"] { errorNotice("Play-by-play is temporarily unavailable.", detail: error) }
                if snapshot?.playsLoaded == true || !(snapshot?.events.isEmpty ?? true) {
                    HStack(alignment: .top, spacing: 20) {
                        NHLPlayByPlayView(events: snapshot?.events ?? [], game: snapshot?.game, league: match.league)
                        #if !os(tvOS)
                        if wide { ScrollView { NHLTeamStatsView(stats: snapshot?.teamStats ?? [], game: snapshot?.game) }.frame(width: 280) }
                        #endif
                    }
                } else if model.errors["plays"] == nil { loadingRows }
            }
        case .overview:
            GameOverviewScroll {
                if let error = model.errors["landing"] { errorNotice("Game overview is temporarily unavailable.", detail: error) }

                let scoringEvents = snapshot?.scoringSummary.isEmpty == false ? (snapshot?.scoringSummary ?? []) : (snapshot?.events ?? []).filter { $0.eventType == .goal }
                GameDetailSection(title: "Scoring") {
                    EventTimeline(events: NHLGamePresentation.timeline(events: scoringEvents, game: snapshot?.game), league: match.league,
                                  emptyText: match.state == .pre ? "No scoring yet." : "No goals in this game yet.")
                    if let recap = snapshot?.recapURL {
                        Link("Game recap", destination: recap)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accessibleAccent)
                            .frame(minHeight: 44)
                    }
                }

                let leaders = NHLGamePresentation.leaders(players: snapshot?.players ?? [], game: snapshot?.game)
                if !leaders.isEmpty {
                    GameDetailSection(title: "Game Leaders") {
                        GameLeadersStrip(leaders: leaders)
                    }
                }

                let keyStats = NHLGamePresentation.keyStats(teamStats: snapshot?.teamStats ?? [], game: snapshot?.game)
                if !keyStats.isEmpty {
                    GameDetailSection(title: "Team Stats", actionTitle: "View all stats", action: { model.selectedTab = .boxscore }) {
                        TeamStatsComparison(stats: keyStats, awayAbbreviation: snapshot?.game?.away.abbreviation ?? "Away",
                                             homeAbbreviation: snapshot?.game?.home.abbreviation ?? "Home")
                    }
                }

                let infoItems = NHLGamePresentation.gameInfo(game: snapshot?.game)
                if !infoItems.isEmpty {
                    GameDetailSection(title: "Game Info") {
                        GameInfoCard(items: infoItems)
                    }
                }

                relatedContent()
            }
        case .boxscore:
            ScrollView {
                VStack {
                    if let error = model.errors["boxscore"] { errorNotice("Box score is temporarily unavailable.", detail: error) }
                    NHLBoxScoreView(players: snapshot?.players ?? [], teamStats: snapshot?.teamStats ?? [], game: snapshot?.game, league: match.league)
                }.frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
        }
    }
    private var loadingRows: some View {
        VStack(alignment: .leading, spacing: 24) {
            ProgressView("Loading plays")
            ForEach(0..<4) { _ in
                VStack(alignment: .leading) {
                    Text("Period · 00:00").font(.caption)
                    Text("Loading game event").font(.headline)
                    Text("Player and event details").font(.subheadline)
                }.redacted(reason: .placeholder)
            }
            Spacer()
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
    }
    private func errorNotice(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Label(title, systemImage: "wifi.exclamationmark").font(.callout)
            Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
            Button("Retry") { retryRevision += 1 }.frame(minHeight: 44).disabled(model.isRefreshing)
        }.padding().frame(maxWidth: .infinity)
    }
}
