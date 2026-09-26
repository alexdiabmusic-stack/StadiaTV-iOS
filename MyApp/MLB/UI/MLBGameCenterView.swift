import SwiftUI
import Charts

struct MLBGameCenterView<WatchContent: View, RelatedContent: View>: View {
    let match: Match
    @ViewBuilder let watchContent: () -> WatchContent
    @ViewBuilder let relatedContent: () -> RelatedContent
    @State private var model = MLBGameCenterViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var revealed = false
    @State private var showingPaywall = false
    @State private var revision = 0
    @State private var fullRefresh = true
    private var gamePk: Int? {
        guard match.league.path == "baseball/mlb", let canonical = match.canonicalID,
              let raw = SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: .mlb) else { return nil }
        return Int(raw)
    }
    private var snapshot: BaseballGameSnapshot? { model.snapshot?.gamePk == gamePk ? model.snapshot : nil }
    private var hideScore: Bool { preferences.spoilerFreeMode && (snapshot?.game?.status == .final || match.state == .final) && !revealed }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let game = snapshot?.game { MLBGameHeaderView(game: game, line: snapshot?.line, league: match.league) }
                else {
                    VStack(spacing: 12) {
                        Text(match.shortName).font(.title2.bold()); Text(match.statusDetail).font(.subheadline)
                        if model.errors.isEmpty { ProgressView("Loading Game Centre") }
                    }.frame(maxWidth: .infinity).padding().background(Theme.surface)
                }
                watchContent()
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(MLBGameTab.allCases) { tab in
                            Button { fullRefresh = false; model.selectedTab = tab } label: {
                                Text(tab.rawValue).font(.subheadline.bold()).padding(.horizontal, 12).frame(minHeight: 44)
                                    .background(model.selectedTab == tab ? Theme.surfaceElevated : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.bordered).accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
                        }
                    }.padding(8)
                }
                if model.showingCache {
                    Text("Saved data · \(snapshot?.fetchedAt.formatted(date: .abbreviated, time: .shortened) ?? "")").font(.caption).foregroundStyle(.secondary).padding(4)
                }
                if gamePk == nil {
                    ContentUnavailableView("MLB game unavailable", systemImage: "baseball", description: Text("Open this game from the MLB schedule."))
                } else if entitlements.isPremium {
                    content(wide: geometry.size.width > 850)
                } else {
                    ScrollView {
                        PremiumGateOverlay(icon: "baseball", title: "Game Centre", description: "Live plays, player statistics and game analysis.", showPaywall: $showingPaywall)
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
        .task(id: "\(gamePk ?? 0):\(scenePhase == .active):\(model.selectedTab.id):\(revision)") {
            if let gamePk { await model.run(gamePk: gamePk, active: scenePhase == .active, seed: seed(gamePk), fullRefresh: fullRefresh) }
        }
    }
    @ViewBuilder private func content(wide: Bool) -> some View {
        VStack(spacing: 0) {
            if let error = model.errors[errorKey] ?? model.errors["overview"] { errorNotice(error) }
            if let snapshot, snapshot.fetchedAt != .distantPast || !model.isRefreshing {
                switch model.selectedTab {
                case .plays:
                    HStack(alignment: .top, spacing: 20) {
                        MLBPlayByPlayView(plays: snapshot.atBats, game: snapshot.game, league: match.league).id(snapshot.gamePk)
                        #if !os(tvOS)
                        if wide { ScrollView { MLBCurrentMatchupView(snapshot: snapshot, league: match.league) }.frame(width: 280) }
                        #endif
                    }
                case .boxscore:
                    ScrollView { MLBBoxScoreView(snapshot: snapshot, league: match.league).frame(maxWidth: 1000).frame(maxWidth: .infinity) }
                case .overview:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let game = snapshot.game {
                                if let line = snapshot.line { MLBLineScoreView(line: line, game: game) }
                                MLBCurrentMatchupView(snapshot: snapshot, league: match.league)
                                if let venue = game.venue { Label(venue, systemImage: "mappin.and.ellipse") }
                                if let weather = game.weather, !weather.isEmpty { Label(weather, systemImage: "cloud.sun") }
                                if let series = game.seriesDescription ?? ["W": "World Series", "L": "League Championship Series", "D": "Division Series", "F": "Wild Card", "S": "Spring Training", "A": "All-Star Game"][game.gameType ?? ""] { Text(series).font(.subheadline) }
                                Text([game.away.record.map { "\(game.away.abbreviation) \($0)" }, game.home.record.map { "\(game.home.abbreviation) \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                            }
                            MLBGameLeadersView(players: snapshot.box, league: match.league)
                            Text("Scoring summary").font(.title3.bold())
                            ForEach(snapshot.atBats.filter(\.isScoringPlay).reversed()) { play in MLBAtBatRow(play: play, game: snapshot.game, league: match.league) }
                            ForEach(snapshot.highlights) { highlight in Link(destination: highlight.url) { Label(highlight.title, systemImage: "play.circle").frame(minHeight: 44) } }
                            relatedContent()
                        }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
                    }
                case .stats:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let game = snapshot.game, let line = snapshot.line { MLBLineScoreView(line: line, game: game) }
                            Text("Home win probability · MLB").font(.headline)
                            if snapshot.probabilities.isEmpty { Text("Win probability is not available for this game.").foregroundStyle(.secondary) }
                            else {
                                Chart(snapshot.probabilities) { point in LineMark(x: .value("At-bat", point.atBatIndex), y: .value("Home win probability", point.homePercent)) }
                                    .chartYScale(domain: 0...100).frame(height: 220)
                                    .accessibilityLabel("MLB home team win probability by plate appearance")
                            }
                        }.padding().frame(maxWidth: 900).frame(maxWidth: .infinity)
                    }
                }
            } else { loading }
        }
    }
    private var errorKey: String { model.selectedTab == .plays ? "plays" : model.selectedTab == .boxscore ? "boxscore" : model.selectedTab == .stats ? "stats" : "overview" }
    private func errorNotice(_ error: String) -> some View {
        VStack(spacing: 8) {
            Text(model.selectedTab == .plays ? "Play-by-play is temporarily unavailable." : "Some game information is temporarily unavailable.")
            Button("Retry") { fullRefresh = true; revision += 1 }
        }.font(.subheadline).padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private var loading: some View {
        VStack(spacing: 18) { ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated).frame(height: 64).redacted(reason: .placeholder) } }.padding()
    }
    private func seed(_ id: Int) -> BaseballGame? {
        guard let away = match.away.teamID.flatMap(Int.init), let home = match.home.teamID.flatMap(Int.init) else { return nil }
        return BaseballGame(id: id, start: match.date,
            away: BaseballTeam(id: away, name: match.away.displayName, abbreviation: match.away.abbreviation, runs: match.away.score.flatMap(Int.init), record: match.away.record),
            home: BaseballTeam(id: home, name: match.home.displayName, abbreviation: match.home.abbreviation, runs: match.home.score.flatMap(Int.init), record: match.home.record),
            status: match.state == .final ? .final : match.state == .live ? .live : .scheduled, detailedStatus: match.statusDetail, venue: match.venue, broadcasts: match.broadcasts)
    }
}
