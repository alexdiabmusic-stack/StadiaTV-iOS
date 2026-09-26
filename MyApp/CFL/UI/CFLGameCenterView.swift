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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let game { CFLGameHeaderView(game: game) }
                else { VStack(spacing: 12) { Text(match.shortName).font(.title2.bold()); Text(match.statusDetail); if model.error == nil { ProgressView("Loading Game Centre") } }.padding().frame(maxWidth: .infinity).background(Theme.surface) }
                watchContent()
                ScrollView(.horizontal) {
                    HStack { ForEach(["Overview", "Plays", "Box Score", "Stats"], id: \.self) { tab in
                        Button(tab) { model.tab = tab }.buttonStyle(.bordered).tint(model.tab == tab ? Theme.accessibleAccent : .secondary).frame(minHeight: 44)
                    } }.padding(8)
                }
                if let error = model.error { HStack { Text(error).font(.caption); Button("Retry") { revision += 1 } }.padding(8) }
                if let game {
                    if entitlements.isPremium {
                        ScrollView { selected(game).frame(maxWidth: 900).frame(maxWidth: .infinity); if model.tab == "Overview" { relatedContent() } }
                    } else {
                        ScrollView { PremiumGateOverlay(icon: "american.football", title: "Game Centre", description: "Live drives, plays and player statistics.", showPaywall: $showingPaywall); relatedContent() }
                    }
                } else if gameID == nil {
                    ContentUnavailableView("CFL game unavailable", systemImage: "american.football", description: Text("Open this game from the CFL schedule."))
                } else { Spacer() }
            }.background(Theme.background).foregroundStyle(Theme.textPrimary)
        }
        .blur(radius: hideScore ? 12 : 0).accessibilityHidden(hideScore).allowsHitTesting(!hideScore)
        .overlay { if hideScore { Button("Reveal final score") { revealed = true }.padding().background(Theme.surface, in: Capsule()).accessibilityHidden(false) } }
        .sheet(isPresented: $showingPaywall) {
            #if os(tvOS)
            TVPaywallView()
            #else
            PaywallView()
            #endif
        }
        .task(id: "\(gameID ?? ""): \(scenePhase == .active):\(model.tab):\(revision)") {
            if let gameID { await model.run(id: gameID, date: match.date, active: scenePhase == .active) }
        }
        .task(id: "\(gameID ?? ""):\(model.tab)") {
            guard let gameID, ["Box Score", "Stats"].contains(model.tab), !statsLoaded else { return }
            await loadStats(gameID: gameID)
        }
    }
    private func loadStats(gameID: String) async {
        guard let game else { return }
        let provider = CFLProvider()
        async let seasonRecords = try? CFLClient.shared.get(.teamRecords(seasonID: game.seasonID), as: [CFLValue].self, maxAge: 900)
        async let playerRecords = try? CFLClient.shared.get(.playerRecords(seasonID: game.seasonID), as: [CFLValue].self, maxAge: 900)
        _ = provider
        if let records = await seasonRecords {
            homeSeasonStats = records.first { $0["team_id"].string == game.home.id }?["seasons"].array.first ?? .null
            awaySeasonStats = records.first { $0["team_id"].string == game.away.id }?["seasons"].array.first ?? .null
        }
        if let records = await playerRecords {
            players = CFLPlayerStatsMapper.players(records, fixtureID: game.id)
        }
        statsLoaded = true
    }
    @ViewBuilder private func selected(_ game: CFLGameState) -> some View {
        switch model.tab {
        case "Plays": CFLPlaysView(game: game).id(game.id)
        case "Box Score": CFLBoxScoreView(game: game, players: players)
        case "Stats": CFLStatsView(home: homeSeasonStats, away: awaySeasonStats, homeAbbreviation: game.home.abbreviation, awayAbbreviation: game.away.abbreviation)
        default: overview(game)
        }
    }
    private func overview(_ game: CFLGameState) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(String(game.year)) • \(CFLGameTypeMapper.label(game.gameType, homeZone: nil, awayZone: nil)) • Week \(game.week)").font(.subheadline).foregroundStyle(.secondary)
            FootballQuarterScoreView(home: game.home, away: game.away, overtimeActive: game.isOvertime)
            if let venue = game.venue { Label(venue, systemImage: "mappin.and.ellipse") }
            if !game.broadcasts.isEmpty { Label(game.broadcasts.joined(separator: ", "), systemImage: "tv") }
        }.padding()
    }
}
