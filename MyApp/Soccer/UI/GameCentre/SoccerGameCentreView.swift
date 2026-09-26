import SwiftUI

/// The reusable Soccer Game Centre shell — tabs, polling wiring, premium/spoiler
/// gating, pregame/live/final/cache states. Provider-agnostic: every subview it
/// renders (`SoccerScoreHeaderView`, `SoccerOverviewView`, `SoccerTimelineView`,
/// `SoccerLineupsView`, `SoccerStatsView`, `SoccerCommentaryView`) takes only
/// canonical Soccer domain types, and the provider identity (which endpoint client,
/// which polling cadence, which cache namespace, which league path) is injected by
/// the call site — see the `soccer/eng.1` and `soccer/usa.1` branches in
/// `MatchDetailView`. No soccer provider gets its own Game Centre view.
struct SoccerGameCentreView<WatchContent: View, RelatedContent: View>: View {
    let match: Match
    let leaguePath: String
    let providerID: SportsDataProviderID
    let providerDisplayName: String
    let seed: (Match) -> SoccerMatch?
    /// Tabs to show, in order. Defaults to the five every provider supports; only a
    /// provider that actually populates `SoccerGameCentreSnapshot.shots` should add
    /// `.shots` here (Step 24 is explicitly optional) — EPL/MLS never pass this.
    let availableTabs: [SoccerGameTab]
    @ViewBuilder let watchContent: () -> WatchContent
    @ViewBuilder let relatedContent: () -> RelatedContent
    @State private var model: SoccerGameCentreViewModel
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var revealed = false
    @State private var showingPaywall = false
    @State private var revision = 0
    @State private var fullRefresh = true

    init(match: Match, leaguePath: String, providerID: SportsDataProviderID, providerDisplayName: String,
         service: any SoccerGameCentreServing, cache: SoccerGameCentreCache, pollingPolicy: SoccerPollingPolicy,
         availableTabs: [SoccerGameTab] = [.overview, .timeline, .lineups, .stats, .commentary],
         seed: @escaping (Match) -> SoccerMatch?,
         @ViewBuilder watchContent: @escaping () -> WatchContent,
         @ViewBuilder relatedContent: @escaping () -> RelatedContent) {
        self.match = match; self.leaguePath = leaguePath; self.providerID = providerID; self.providerDisplayName = providerDisplayName
        self.availableTabs = availableTabs
        self.seed = seed; self.watchContent = watchContent; self.relatedContent = relatedContent
        _model = State(wrappedValue: SoccerGameCentreViewModel(service: service, cache: cache, pollingPolicy: pollingPolicy))
    }

    private var matchID: String? {
        guard match.league.path == leaguePath, let canonical = match.canonicalID,
              let raw = SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: providerID) else { return nil }
        return raw
    }
    private var snapshot: SoccerGameCentreSnapshot? { model.snapshot?.matchID == matchID ? model.snapshot : nil }
    private var hideScore: Bool { preferences.spoilerFreeMode && (snapshot?.match?.status == .fullTime || match.state == .final) && !revealed }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let soccerMatch = snapshot?.match {
                    SoccerScoreHeaderView(match: soccerMatch, homeLogo: match.home.logoURL, awayLogo: match.away.logoURL, hideScore: hideScore)
                } else {
                    VStack(spacing: 12) {
                        Text(match.shortName).font(.title2.bold())
                        Text(match.statusDetail).font(.subheadline)
                        if model.errors.isEmpty { ProgressView("Loading Game Centre") }
                    }.frame(maxWidth: .infinity).padding().background(Theme.surface)
                }
                watchContent()
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(availableTabs) { tab in
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
                if matchID == nil {
                    ContentUnavailableView("Match unavailable", systemImage: "soccerball", description: Text("Open this match from the \(providerDisplayName) schedule."))
                } else if entitlements.isPremium {
                    content(wide: geometry.size.width > 850)
                } else {
                    ScrollView {
                        PremiumGateOverlay(icon: "soccerball", title: "Game Centre", description: "Live match events, lineups, and statistics.", showPaywall: $showingPaywall)
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
        .task(id: "\(matchID ?? ""):\(scenePhase == .active):\(model.selectedTab.id):\(revision)") {
            if let matchID { await model.run(matchID: matchID, active: scenePhase == .active, seed: seed(match), fullRefresh: fullRefresh) }
        }
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        VStack(spacing: 0) {
            if let error = model.errors[errorKey] ?? model.errors["overview"] { errorNotice(error) }
            if let snapshot {
                switch model.selectedTab {
                case .overview:
                    ScrollView {
                        VStack(alignment: .leading) {
                            SoccerOverviewView(snapshot: snapshot)
                            relatedContent()
                        }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
                    }
                case .timeline:
                    SoccerTimelineView(snapshot: snapshot, wide: wide)
                case .lineups:
                    SoccerLineupsView(homeLineup: snapshot.homeLineup, awayLineup: snapshot.awayLineup, wide: wide)
                case .stats:
                    SoccerStatsView(home: snapshot.homeStats, away: snapshot.awayStats,
                        homeAbbr: snapshot.match?.home.team.abbreviation ?? "", awayAbbr: snapshot.match?.away.team.abbreviation ?? "")
                case .commentary:
                    SoccerCommentaryView(entries: snapshot.commentary, hasMore: snapshot.commentaryNextCursor != nil, onLoadMore: { await model.loadMoreCommentary() })
                case .shots:
                    SoccerShotMapView(shots: snapshot.shots, homeAbbr: snapshot.match?.home.team.abbreviation ?? "",
                        awayAbbr: snapshot.match?.away.team.abbreviation ?? "", homeTeamID: snapshot.match?.home.team.id,
                        awayTeamID: snapshot.match?.away.team.id)
                }
            } else { loading }
        }
    }

    private var errorKey: String {
        switch model.selectedTab {
        case .overview: return "overview"
        case .timeline: return "events"
        case .lineups: return "lineups"
        case .stats: return "stats"
        case .commentary: return "commentary"
        case .shots: return "shots"
        }
    }

    private func errorNotice(_ error: String) -> some View {
        VStack(spacing: 8) {
            if model.isBlocked {
                Text("\(providerDisplayName) data isn't available on this network.")
            } else {
                Text("Some match information is temporarily unavailable.")
                Button("Retry") { fullRefresh = true; revision += 1 }
            }
        }.font(.subheadline).padding().frame(maxWidth: .infinity).background(Theme.surface)
    }

    private var loading: some View {
        VStack(spacing: 18) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated).frame(height: 64).redacted(reason: .placeholder) } }.padding()
    }
}
