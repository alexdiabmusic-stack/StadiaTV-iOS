import SwiftUI

struct NFLGameCenterView<RelatedContent: View>: View {
    let match: Match
    @ViewBuilder let relatedContent: () -> RelatedContent
    @State private var model = NFLGameCenterViewModel()
    @State private var revision = 0
    @State private var revealed = false
    @State private var showingPaywall = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    private var gameID: String? {
        guard let canonical = match.canonicalID else { return nil }
        return SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: .nfl)
    }
    private var game: NFLGameState? { model.game?.id == gameID ? model.game : nil }
    private var hideScore: Bool { preferences.spoilerFreeMode && (game?.status == .final || match.state == .final) && !revealed }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let game { NFLGameHeaderView(game: game) }
                else { VStack(spacing: 12) { Text(match.shortName).font(.title2.bold()); Text(match.statusDetail); if model.error == nil { ProgressView("Loading Game Centre") } }.padding().frame(maxWidth: .infinity).background(Theme.surface) }
                ScrollView(.horizontal) {
                    HStack { ForEach(["Overview", "Plays", "Box Score", "Stats"], id: \.self) { tab in
                        Button(tab) { model.tab = tab }.buttonStyle(.bordered).tint(model.tab == tab ? Theme.accessibleAccent : .secondary).frame(minHeight: 44)
                    } }.padding(8)
                }
                if let error = model.error { HStack { Text(error).font(.caption); Button("Retry") { revision += 1 } }.padding(8) }
                if let game {
                    NavigationLink("Calendar & results") { NFLCalendarView(week: game.week) }.font(.caption).frame(minHeight: 44)
                    TimelineView(.periodic(from: .now, by: 10)) { context in
                        if model.cached || (game.status == .live && context.date.timeIntervalSince(game.summaryUpdated) > 30) {
                            Text("\(model.cached ? "Saved data" : "Live data delayed") · \(game.summaryUpdated.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if entitlements.isPremium {
                        HStack(alignment: .top, spacing: 16) {
                            selected(game)
                            if geometry.size.width > 950, model.tab == "Plays" {
                                ScrollView { overview(game) }.frame(width: 300)
                            }
                        }
                    } else {
                        ScrollView { PremiumGateOverlay(icon: "american.football", title: "Game Centre", description: "Live drives, plays and player statistics.", showPaywall: $showingPaywall); relatedContent() }
                    }
                } else if gameID == nil {
                    ContentUnavailableView("NFL game unavailable", systemImage: "american.football", description: Text("Open this game from the NFL schedule."))
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
        .task {
            var previous: Bool?
            for await connected in SportsConnectivity.changes() {
                guard !Task.isCancelled else { return }
                if connected, previous == false { revision += 1 }
                previous = connected
            }
        }
    }
    @ViewBuilder private func selected(_ game: NFLGameState) -> some View {
        switch model.tab {
        case "Plays": NFLPlaysView(game: game).id(game.id)
        case "Box Score": ScrollView { NFLBoxScoreView(game: game).frame(maxWidth: 900).frame(maxWidth: .infinity) }
        case "Stats": ScrollView { NFLStatsView(game: game).frame(maxWidth: 900).frame(maxWidth: .infinity) }
        default: ScrollView { overview(game).frame(maxWidth: 900).frame(maxWidth: .infinity); relatedContent() }
        }
    }
    private func overview(_ game: NFLGameState) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(String(game.week.season)) • \(game.week.seasonType == .preseason ? "Preseason" : game.week.seasonType == .postseason ? "Postseason" : "Regular season") • Week \(game.week.week)").font(.subheadline).foregroundStyle(.secondary)
            NFLQuarterScoreView(game: game)
            if game.status == .live, let field = game.field { NFLFieldView(position: field) }
            if let drive = game.currentDrive {
                Text("Current drive").font(.title3.bold())
                Text([drive.playCount.map { "\($0) plays" }, drive.yards.map { "\($0) yards" }, drive.timeOfPossession].compactMap { $0 }.joined(separator: " • "))
            }
            let scoring = game.plays.filter(\.scoring).suffix(4)
            if !scoring.isEmpty { Text("Recent scoring").font(.title3.bold()); ForEach(scoring.reversed()) { NFLPlayRow(play: $0) } }
            if let venue = game.venue { Label(venue, systemImage: "mappin.and.ellipse") }
            if let weather = game.weather { Label(weather, systemImage: "cloud.sun") }
        }.padding()
    }
}
