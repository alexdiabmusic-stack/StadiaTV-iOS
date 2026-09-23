import SwiftUI

struct NBAGameCenterView<RelatedContent: View>: View {
    let match: Match
    @ViewBuilder let relatedContent: () -> RelatedContent
    @State private var model = NBAGameCenterViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var revealed = false
    @State private var showingPaywall = false
    @State private var revision = 0
    @State private var fullRefresh = true

    private var gameID: NBAProviderGameID? {
        guard match.league.path == "basketball/nba", let canonical = match.canonicalID,
              let raw = SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: .nba) else { return nil }
        return NBAProviderGameID(raw)
    }
    private var snapshot: BasketballGameSnapshot? { model.snapshot?.gameID == gameID ? model.snapshot : nil }
    private var hideScore: Bool { preferences.spoilerFreeMode && (snapshot?.game?.status == .final || match.state == .final) && !revealed }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let game = snapshot?.game { NBAGameHeaderView(game: game, league: match.league) }
                else {
                    VStack(spacing: 12) {
                        Text(match.shortName).font(.title2.bold()); Text(match.statusDetail).font(.subheadline)
                        if model.errors.isEmpty { ProgressView("Loading Game Centre") }
                    }.frame(maxWidth: .infinity).padding().background(Theme.surface)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(NBAGameTab.allCases) { tab in
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
                if gameID == nil {
                    ContentUnavailableView("NBA game unavailable", systemImage: "basketball", description: Text("Open this game from the NBA schedule."))
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
        .task(id: "\(gameID?.rawValue ?? ""):\(scenePhase == .active):\(model.selectedTab.id):\(revision)") {
            if let gameID { await model.run(gameID: gameID, active: scenePhase == .active, seed: seed(gameID), fullRefresh: fullRefresh) }
        }
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        VStack(spacing: 0) {
            if let error = model.errors[errorKey] ?? model.errors["overview"] { errorNotice(error) }
            if let snapshot, snapshot.fetchedAt != .distantPast || !model.isRefreshing {
                switch model.selectedTab {
                case .plays:
                    NBAPlayByPlayView(plays: snapshot.plays, game: snapshot.game).id(snapshot.gameID)
                case .boxscore:
                    ScrollView { NBABoxScoreView(snapshot: snapshot, league: match.league).frame(maxWidth: 1000).frame(maxWidth: .infinity) }
                case .shots:
                    ScrollView {
                        VStack(spacing: 16) {
                            NBAShotChartView(shots: snapshot.shots).frame(maxWidth: 460)
                            if wide { NBAPlayByPlayView(plays: snapshot.plays.filter { $0.isFieldGoal }, game: snapshot.game).frame(maxHeight: 400) }
                        }.padding().frame(maxWidth: .infinity)
                    }
                case .overview:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let game = snapshot.game {
                                NBALineScoreView(game: game)
                                if let venue = game.arena?.name { Label(venue, systemImage: "mappin.and.ellipse") }
                                if let series = game.seriesText { Text(series).font(.subheadline) }
                                Text([game.away.record.map { "\(game.away.tricode) \($0)" }, game.home.record.map { "\(game.home.tricode) \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                            }
                            NBAGameLeadersView(snapshot: snapshot, league: match.league)
                            if !snapshot.shots.isEmpty { NBAShotChartView(shots: snapshot.shots).frame(maxWidth: 320) }
                            Text("Scoring summary").font(.title3.bold())
                            ForEach(snapshot.plays.filter { $0.type.isScoring }.reversed()) { play in NBAPlayRow(play: play) }
                            relatedContent()
                        }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
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
                Text("NBA data isn't available on this network.")
            } else {
                Text(model.selectedTab == .plays ? "Play-by-play is temporarily unavailable." : "Some game information is temporarily unavailable.")
                Button("Retry") { fullRefresh = true; revision += 1 }
            }
        }.font(.subheadline).padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private var loading: some View {
        VStack(spacing: 18) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated).frame(height: 64).redacted(reason: .placeholder) } }.padding()
    }
    private func seed(_ id: NBAProviderGameID) -> BasketballGame? {
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
