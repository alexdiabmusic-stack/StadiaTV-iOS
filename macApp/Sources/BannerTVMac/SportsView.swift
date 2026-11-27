import BannerCore
import SwiftUI

private enum SportsTab: String, CaseIterable, Identifiable {
    case mine = "My Sports", all = "All Events", leagues = "Leagues"
    var id: String { rawValue }
}

/// Sports: games and results for the sports and teams you follow, matched to the channels and add-on streams you already have.
struct SportsView: View {
    @EnvironmentObject private var sports: SportsModel
    @EnvironmentObject private var live: LiveTvModel
    @State private var tab: SportsTab = .all
    @State private var chose = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let problem = sports.status?.problem, !problem.isEmpty {
                Text(problem).font(.jb(14)).foregroundStyle(.red.opacity(0.9)).lineLimit(2).padding(.horizontal, 32).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch tab {
            case .mine: MySportsTab(onPick: { tab = .leagues })
            case .all: AllEventsTab()
            case .leagues: LeaguesTab()
            }
        }
        .onAppear {
            sports.start(); sports.setViewing(true)
            chooseStartTab()
        }
        .onDisappear { sports.setViewing(false) }
        .onChange(of: sports.status?.followsAnything) { _, _ in chooseStartTab() }
    }

    /// Opens on My Sports when something is followed (once, as soon as that is known), and leaves the person's own choice alone after that.
    private func chooseStartTab() {
        guard !chose, let status = sports.status else { return }
        chose = true
        if status.followsAnything { tab = .mine }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Sports").font(.jb(40, .bold))
            if sports.status?.loading == true || sports.status?.matching == true { ProgressView().controlSize(.small) }
            Spacer()
            HStack(spacing: 8) {
                ForEach(SportsTab.allCases) { t in Chip(title: t.rawValue, selected: tab == t) { tab = t; chose = true } }
            }
            Button { sports.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(GlassCircleButtonStyle(size: 40)).help("Refresh scores")
            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(GlassCircleButtonStyle(size: 40)).help("Sports settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SportsSettingsView() }
        }
        .padding(.horizontal, Theme.gutter).padding(.top, 84).padding(.bottom, 10)
    }
}

// MARK: - All Events

private struct AllEventsTab: View {
    @EnvironmentObject private var sports: SportsModel
    @State private var day = 0
    @State private var sport: String?
    @State private var page: MacSportsBrowse?

    private var offsets: [Int] { Array(-Int(MacSports.shared.daysBack())...Int(MacSports.shared.daysAhead())) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(offsets, id: \.self) { offset in
                                Chip(title: SportsFormat.day(offset), selected: day == offset) { day = offset; sport = nil }.id(offset)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(0, anchor: .center) }
                }
                if let sports = page?.sports, sports.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Chip(title: "All", selected: sport == nil) { sport = nil }
                            ForEach(sports, id: \.self) { name in Chip(title: name, selected: sport == name) { sport = name } }
                        }
                    }
                }
                if let page {
                    if page.sections.isEmpty {
                        EmptyNote(title: "Nothing on this day", message: sports.status?.loading == true ? "Loading games…" : "No games match your filters. Try another day, or choose more leagues under Leagues.")
                    }
                    ForEach(page.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title).font(.jb(22, .semibold))
                            GameGrid(games: section.games)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.bottom, 60)
        }
        .onAppear(perform: reload)
        .onChange(of: sports.tick) { _, _ in reload() }
        .onChange(of: day) { _, _ in reload() }
        .onChange(of: sport) { _, _ in reload() }
    }

    @EnvironmentObject private var router: Router
    @State private var autoOpened = false

    private func reload() {
        page = MacSports.shared.browse(dayOffset: Int32(day), sport: sport)
        if DebugHarness.openFirstGame, !autoOpened, let first = page?.sections.first?.games.first {
            autoOpened = true
            router.path.append(.game(first.id))
        }
    }
}

// MARK: - My Sports

private struct MySportsTab: View {
    let onPick: () -> Void
    @EnvironmentObject private var sports: SportsModel
    @State private var page: MacSportsPage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let page, !page.rows.isEmpty {
                    ForEach(page.rows, id: \.key) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                if row.kind == "team" { TeamLogo(url: row.teamLogo, size: 22) }
                                Text(row.title).font(.jb(22, .semibold))
                            }
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 14) {
                                        ForEach(row.games, id: \.id) { game in GameCard(game: game).frame(width: 300).id(game.id) }
                                    }
                                }
                                .onAppear {
                                    if Int(row.startIndex) < row.games.count { proxy.scrollTo(row.games[Int(row.startIndex)].id, anchor: .leading) }
                                }
                            }
                        }
                    }
                } else if sports.status?.followsAnything == true {
                    EmptyNote(title: "Nothing scheduled yet", message: sports.status?.loading == true ? "Loading games…" : "Games for the teams and leagues you follow show up here as they are announced.")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        EmptyNote(title: "Follow what you watch", message: "Pick teams and leagues and their games, scores and streams collect here.")
                        Button("Choose Teams and Leagues", action: onPick).buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.bottom, 60).padding(.top, 6)
        }
        .onAppear(perform: reload)
        .onChange(of: sports.tick) { _, _ in reload() }
    }

    private func reload() { page = MacSports.shared.mine() }
}

// MARK: - Leagues

private struct LeaguesTab: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var sports: SportsModel
    @State private var leagues: [MacLeague] = []
    @State private var follows: MacSportsFollows?
    @State private var query = ""

    private var filtered: [MacLeague] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? leagues : leagues.filter { $0.name.lowercased().contains(q) || $0.sport.lowercased().contains(q) }
    }

    private var sportNames: [String] {
        var seen = Set<String>(); var order: [String] = []
        for league in filtered where seen.insert(league.sport).inserted { order.append(league.sport) }
        return order
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Search leagues and sports", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                if let follows, !follows.teams.isEmpty || !follows.words.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Following").font(.jb(22, .semibold))
                        FlowRow {
                            ForEach(follows.teams, id: \.key) { team in
                                Button { MacSports.shared.toggleTeam(leagueId: team.leagueId, teamId: team.teamId); reload() } label: {
                                    HStack(spacing: 6) { TeamLogo(url: team.logo, size: 18); Text(team.name); Image(systemName: "xmark").font(.jb(11)) }
                                }.buttonStyle(.plain).font(.jb(14, .semibold)).padding(.horizontal, 12).padding(.vertical, 6).background(Color.white.opacity(0.10), in: Capsule())
                            }
                        }
                    }
                }
                ForEach(sportNames, id: \.self) { sport in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sport).font(.jb(22, .semibold))
                        VStack(spacing: 0) {
                            ForEach(filtered.filter { $0.sport == sport }, id: \.id) { league in
                                LeagueRow(league: league, onChange: reload)
                                Divider().opacity(0.4)
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.bottom, 60).padding(.top, 6)
        }
        .onAppear(perform: reload)
        .onChange(of: sports.tick) { _, _ in reload() }
    }

    private func reload() {
        leagues = MacSports.shared.leagues()
        follows = MacSports.shared.follows()
    }
}

private struct LeagueRow: View {
    let league: MacLeague
    let onChange: () -> Void
    @EnvironmentObject private var router: Router

    var body: some View {
        HStack {
            Button { router.path.append(.league(league.id)) } label: {
                HStack {
                    Text(league.name).font(.jb(15))
                    Spacer()
                    Image(systemName: "chevron.right").font(.jb(12)).foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(league.followed ? "Following" : "Follow") { MacSports.shared.toggleLeague(leagueId: league.id); onChange() }
                .buttonStyle(.bordered).controlSize(.small).tint(league.followed ? Theme.accentStart : nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

// MARK: - Games

struct GameGrid: View {
    let games: [MacSportsGame]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 380), spacing: 14, alignment: .top)], spacing: 14) {
            ForEach(games, id: \.id) { GameCard(game: $0) }
        }
    }
}

struct GameCard: View {
    let game: MacSportsGame
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var sports: SportsModel

    var body: some View {
        Button { router.path.append(.game(game.id)) } label: { content }
            .buttonStyle(.plain)
    }

    private var content: some View {
        let hide = sports.hideScores && game.state != "pre"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(game.leagueShort.isEmpty ? game.leagueName : game.leagueShort).font(.jb(12, .semibold)).foregroundStyle(Theme.textSecondary)
                if game.mine { Image(systemName: "star.fill").font(.jb(11)).foregroundStyle(Theme.accentStart) }
                Spacer()
                Text(SportsFormat.status(game, hideScores: hide))
                    .font(.jb(12, .semibold))
                    .foregroundStyle(game.state == "live" ? Color.red : Theme.textSecondary)
            }
            if game.sides.count == 2 {
                ForEach(0..<2, id: \.self) { i in
                    SideLine(side: game.sides[i], showScore: game.hasScore && !hide, loser: game.state == "post" && game.hasScore && !game.sides[i].winner && game.sides[1 - i].winner)
                }
            } else {
                Text(game.title).font(.jb(17, .semibold)).lineLimit(2)
                if let subtitle = game.subtitle, !subtitle.isEmpty { Text(subtitle).font(.jb(14)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            }
            HStack(spacing: 8) {
                if game.streams > 0 {
                    Label("\(game.streams) \(game.streams == 1 ? "stream" : "streams")", systemImage: "play.circle.fill")
                        .font(.jb(12, .semibold)).foregroundStyle(Theme.accentStart)
                }
                if !game.broadcasts.isEmpty {
                    Text(game.broadcasts.prefix(2).joined(separator: " · ")).font(.jb(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 16)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(game.state == "live" ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1))
        .hoverLift(1.02)
    }
}

struct SideLine: View {
    let side: MacSide
    let showScore: Bool
    var loser = false

    var body: some View {
        HStack(spacing: 10) {
            TeamLogo(url: side.logo, size: 26)
            Text(side.name).font(.jb(16, side.winner ? .bold : .semibold)).lineLimit(1)
            if let record = side.record, !record.isEmpty { Text(record).font(.jb(12)).foregroundStyle(Theme.textSecondary) }
            Spacer(minLength: 4)
            if showScore, let score = side.score { Text(score).font(.jb(20, .bold).monospacedDigit()) }
        }
        .opacity(loser ? 0.55 : 1)
    }
}

// MARK: - Settings

private struct SportsSettingsView: View {
    @State private var settings = MacSports.shared.settings()
    @State private var regions: [[String]] = MacSports.shared.regions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sports Settings").font(.jb(17, .semibold))
            Picker("Region", selection: Binding(get: { settings.region }, set: { MacSports.shared.setRegion(code: $0); reload() })) {
                ForEach(regions, id: \.self) { Text($0[1]).tag($0[0]) }
            }
            Toggle("Choose a stream before playing", isOn: Binding(get: { settings.chooseStream }, set: { MacSports.shared.setChooseStream(on: $0); reload() }))
            Toggle("Prefer standard definition (uses less data)", isOn: Binding(get: { settings.sdOnly }, set: { MacSports.shared.setSdOnly(on: $0); reload() }))
            Toggle("Hide scores until I open a game", isOn: Binding(get: { settings.hideScores }, set: { MacSports.shared.setHideScores(on: $0); reload() }))
            Toggle("Only show games on my channels", isOn: Binding(get: { settings.onlyOnMyChannels }, set: { MacSports.shared.setOnlyOnMyChannels(on: $0); reload() }))
            Text("Streams come from your IPTV sources and the add-ons you have installed.").font(.jb(12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(18).frame(width: 360)
    }

    private func reload() { settings = MacSports.shared.settings() }
}

// MARK: - Small pieces

struct EmptyNote: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.jb(22, .semibold))
            Text(message).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays its children out left to right, wrapping onto new lines.
struct FlowRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: 8) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
