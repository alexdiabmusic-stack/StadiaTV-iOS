import SwiftUI

struct CFLGameCenterView<WatchContent: View, RelatedContent: View>: View {
    let match: Match
    @ViewBuilder let watchContent: () -> WatchContent
    @ViewBuilder let relatedContent: () -> RelatedContent
    @State private var model = CFLGameCenterViewModel()
    @State private var revision = 0
    @State private var revealed = false
    @State private var showingPaywall = false
    @State private var players: [CFLPlayerGameLine] = []
    @State private var homeSeasonStats: CFLValue = .null
    @State private var awaySeasonStats: CFLValue = .null
    @State private var statsLoaded = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    private var gameID: String? {
        guard let canonical = match.canonicalID else { return nil }
        return SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: .cfl)
    }
    private var game: CFLGameState? { model.game?.id == gameID ? model.game : nil }
    private var hideScore: Bool { preferences.spoilerFreeMode && (game?.status == .final || match.state == .final) && !revealed }
    var body: some View {
        VStack(spacing: 0) {
            if let game { CFLGameHeaderView(game: game, league: match.league) }
            else { VStack(spacing: 12) { Text(match.shortName).font(.title2.bold()); Text(match.statusDetail); if model.error == nil { ProgressView("Loading Game Centre") } }.padding().frame(maxWidth: .infinity).background(Theme.surface) }
            watchContent()
            GameTabBar(tabs: CFLGameTab.allCases, selection: $model.tab)
            if let error = model.error { HStack { Text(error).font(.caption); Button("Retry") { revision += 1 } }.padding(8) }
            if let game {
                if entitlements.isPremium {
                    content(game)
                } else {
                    ScrollView { PremiumGateOverlay(icon: "american.football", title: "Game Centre", description: "Live drives, plays and player statistics.", showPaywall: $showingPaywall); relatedContent() }
                }
            } else if gameID == nil {
                ContentUnavailableView("CFL game unavailable", systemImage: "american.football", description: Text("Open this game from the CFL schedule."))
            } else { Spacer() }
        }.background(Theme.background).foregroundStyle(Theme.textPrimary)
        .blur(radius: hideScore ? 12 : 0).accessibilityHidden(hideScore).allowsHitTesting(!hideScore)
        .overlay { if hideScore { Button("Reveal final score") { revealed = true }.padding().background(Theme.surface, in: Capsule()).accessibilityHidden(false) } }
        .sheet(isPresented: $showingPaywall) {
            #if os(tvOS)
            TVPaywallView()
            #else
            PaywallView()
            #endif
        }
        .task(id: "\(gameID ?? ""):\(scenePhase == .active):\(model.tab.rawValue):\(revision)") {
            if let gameID { await model.run(id: gameID, date: match.date, active: scenePhase == .active) }
        }
        .task(id: gameID) {
            guard let gameID, !statsLoaded else { return }
            await loadStats(gameID: gameID)
        }
    }
    private func loadStats(gameID: String) async {
        guard let game else { return }
        async let seasonRecords = try? CFLClient.shared.get(.teamRecords(seasonID: game.seasonID), as: [CFLValue].self, maxAge: 900)
        async let playerRecords = try? CFLClient.shared.get(.playerRecords(seasonID: game.seasonID), as: [CFLValue].self, maxAge: 900)
        if let records = await seasonRecords {
            homeSeasonStats = records.first { $0["team_id"].string == game.home.id }?["seasons"].array.first ?? .null
            awaySeasonStats = records.first { $0["team_id"].string == game.away.id }?["seasons"].array.first ?? .null
        }
        if let records = await playerRecords {
            players = CFLPlayerStatsMapper.players(records, fixtureID: game.id)
        }
        statsLoaded = true
    }
    @ViewBuilder private func content(_ game: CFLGameState) -> some View {
        switch model.tab {
        case .plays:
            CFLPlaysView(game: game).id(game.id)
        case .boxscore:
            ScrollView { CFLBoxScoreView(game: game, players: players).frame(maxWidth: 900).frame(maxWidth: .infinity) }
        case .stats:
            ScrollView { CFLStatsView(home: homeSeasonStats, away: awaySeasonStats, homeAbbreviation: game.home.abbreviation, awayAbbreviation: game.away.abbreviation).frame(maxWidth: 900).frame(maxWidth: .infinity) }
        case .overview:
            GameOverviewScroll {
                FootballQuarterScoreView(home: game.home, away: game.away, overtimeActive: game.isOvertime)
                    .padding(.horizontal, Theme.Spacing.md)

                let leaders = CFLGamePresentation.leaders(players: players, game: game)
                if !leaders.isEmpty {
                    GameDetailSection(title: "Game Leaders") {
                        GameLeadersStrip(leaders: leaders)
                    }
                }

                let keyStats = CFLGamePresentation.keyStats(home: homeSeasonStats, away: awaySeasonStats, awayName: game.away.name, homeName: game.home.name)
                if !keyStats.isEmpty {
                    GameDetailSection(title: "Team Stats", actionTitle: "View all stats", action: { model.tab = .stats }) {
                        TeamStatsComparison(stats: keyStats, awayAbbreviation: game.away.abbreviation, homeAbbreviation: game.home.abbreviation)
                    }
                }

                let infoItems = CFLGamePresentation.gameInfo(game: game)
                if !infoItems.isEmpty {
                    GameDetailSection(title: "Game Info") {
                        GameInfoCard(items: infoItems)
                    }
                }

                relatedContent()
            }
        }
    }
}
