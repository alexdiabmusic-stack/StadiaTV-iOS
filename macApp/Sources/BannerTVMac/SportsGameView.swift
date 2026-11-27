import BannerCore
import SwiftUI

/// One game: the score, the streams that show it, and (when the feed has them) what happened, the stats and the line-ups.
struct SportsGameView: View {
    let id: String
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var sports: SportsModel
    @State private var live: MacGameLive?
    @State private var detail: MacGameDetail?
    @State private var detailLoaded = false
    @State private var watch: MacWatch?
    @State private var tab = "Summary"

    var body: some View {
        ScrollView {
            if let game = live?.game {
                VStack(alignment: .leading, spacing: 24) {
                    Scoreboard(game: game, hideScores: sports.hideScores && game.state != "pre")
                    streamsSection(game)
                    detailSection(game)
                }
                .padding(.horizontal, Theme.gutter).padding(.top, 84).padding(.bottom, 60)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .navigationTitle(live?.game?.title ?? "Game")
        .onAppear {
            sports.start(); sports.setViewing(true)
            guard watch == nil else { return }
            watch = MacSports.shared.watchGame(id: id) { value in Task { @MainActor in live = value } }
            loadDetail()
        }
        .onDisappear {
            watch?.cancel(); watch = nil
            MacSports.shared.closeGame(id: id)
            sports.setViewing(false)
        }
        .onChange(of: live?.game?.status) { _, _ in if live?.game?.state == "live" { loadDetail() } }
    }

    private func loadDetail() {
        MacSports.shared.loadDetail(id: id) { value in Task { @MainActor in detail = value; detailLoaded = true } }
    }

    // MARK: Streams

    @ViewBuilder private func streamsSection(_ game: MacSportsGame) -> some View {
        let streams = live?.streams ?? []
        let replays = live?.replays ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(game.state == "post" ? "Replays" : "Watch").font(.jb(22, .semibold))
                if live?.finding == true { ProgressView().controlSize(.small) }
            }
            if game.state == "post" {
                if replays.isEmpty { quiet(live?.finding == true ? "Looking for replays and highlights…" : "No replays or highlights found in your add-ons.") }
                ForEach(replays, id: \.key) { StreamRow(stream: $0, game: game, primary: false) }
            } else if streams.isEmpty {
                quiet(emptyStreamsMessage)
            } else {
                ForEach(Array(streams.enumerated()), id: \.element.key) { index, stream in
                    StreamRow(stream: stream, game: game, primary: index == 0)
                }
            }
        }
    }

    private var emptyStreamsMessage: String {
        if live?.finding == true { return "Looking through your channels and add-ons…" }
        if sports.status?.hasChannels != true { return "Add an IPTV source in Settings, or install a sports add-on, to find streams for this game." }
        return "No stream found for this game yet. Channels are matched from the guide, so it may appear closer to the start."
    }

    private func quiet(_ text: String) -> some View {
        Text(text).foregroundStyle(Theme.textSecondary).padding(.vertical, 4)
    }

    // MARK: Detail

    @ViewBuilder private func detailSection(_ game: MacSportsGame) -> some View {
        if !game.standings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Leaderboard").font(.jb(22, .semibold))
                VStack(spacing: 0) {
                    ForEach(Array(game.standings.enumerated()), id: \.offset) { _, line in
                        HStack { Text(line.pos).frame(width: 36, alignment: .leading).foregroundStyle(Theme.textSecondary); Text(line.name); Spacer(); Text(line.detail ?? "").foregroundStyle(Theme.textSecondary) }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        Divider().opacity(0.3)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        if let about = game.about, !about.isEmpty {
            Text(about).foregroundStyle(Theme.textSecondary).frame(maxWidth: 720, alignment: .leading)
        }
        if let detail {
            let tabs = availableTabs(detail)
            if !tabs.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) { ForEach(tabs, id: \.self) { name in Chip(title: name, selected: tab == name) { tab = name } } }
                    switch tab {
                    case "Stats": StatsPanel(detail: detail, game: game)
                    case "Line-ups": LineupsPanel(detail: detail)
                    case "Table": TablePanel(detail: detail)
                    default: SummaryPanel(detail: detail)
                    }
                }
                .onAppear { if !tabs.contains(tab) { tab = tabs[0] } }
            }
        } else if !detailLoaded && game.state != "pre" {
            ProgressView().controlSize(.small)
        }
        if game.state != "post", let league = SportsLeagueLink(game: game) { league }
    }

    private func availableTabs(_ d: MacGameDetail) -> [String] {
        var tabs: [String] = []
        if !d.scoring.isEmpty || !d.plays.isEmpty || !d.leaders.isEmpty || !d.info.isEmpty || !d.form.isEmpty || !d.meetings.isEmpty { tabs.append("Summary") }
        if !d.stats.isEmpty { tabs.append("Stats") }
        if !d.lineups.isEmpty { tabs.append("Line-ups") }
        if !d.table.isEmpty { tabs.append("Table") }
        return tabs
    }
}

/// A button to the game's league page (table, teams and all its games).
private struct SportsLeagueLink: View {
    let game: MacSportsGame
    @EnvironmentObject private var router: Router

    init?(game: MacSportsGame) {
        guard game.leagueId != "guide/other" else { return nil }
        self.game = game
    }

    var body: some View {
        Button { router.path.append(.league(game.leagueId)) } label: {
            Label("\(game.leagueName) table and games", systemImage: "list.number")
        }
        .buttonStyle(.bordered)
    }
}

private struct Scoreboard: View {
    let game: MacSportsGame
    let hideScores: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(game.leagueName).font(.jb(14, .semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(SportsFormat.status(game, hideScores: hideScores)).font(.jb(14, .semibold)).foregroundStyle(game.state == "live" ? Color.red : Theme.textSecondary)
            }
            if game.sides.count == 2 {
                HStack(alignment: .center, spacing: 0) {
                    BigSide(side: game.sides[0], showScore: game.hasScore && !hideScores)
                    VStack(spacing: 4) {
                        Text(game.state == "pre" ? game.separator : "–").font(.jb(20)).foregroundStyle(Theme.textSecondary)
                        if game.state == "pre" { Text(game.hasTime ? SportsFormat.dayAndTime(game.startMs) : "All day").font(.jb(12)).foregroundStyle(Theme.textSecondary) }
                    }
                    .frame(width: 130)
                    BigSide(side: game.sides[1], showScore: game.hasScore && !hideScores)
                }
            } else {
                Text(game.title).font(.jb(34, .bold))
                if let subtitle = game.subtitle, !subtitle.isEmpty { Text(subtitle).foregroundStyle(Theme.textSecondary) }
                Text(game.hasTime ? SportsFormat.dayAndTime(game.startMs) : "All day").foregroundStyle(Theme.textSecondary)
            }
            if let situation = game.situation, !situation.isEmpty, !hideScores { Text(situation).font(.jb(14)).foregroundStyle(Theme.textSecondary) }
            if game.progress >= 0, game.state == "live", !hideScores {
                ProgressView(value: Double(game.progress)).tint(Theme.accentStart).frame(maxWidth: 360)
            }
            if !game.broadcasts.isEmpty { Text("On " + game.broadcasts.joined(separator: ", ")).font(.jb(14)).foregroundStyle(Theme.textSecondary) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct BigSide: View {
    let side: MacSide
    let showScore: Bool

    var body: some View {
        VStack(spacing: 8) {
            TeamLogo(url: side.logo, size: 72)
            Text(side.name).font(.jb(22, .semibold)).multilineTextAlignment(.center).lineLimit(2)
            if let record = side.record, !record.isEmpty { Text(record).font(.jb(12)).foregroundStyle(Theme.textSecondary) }
            if showScore, let score = side.score {
                Text(score).font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit()).opacity(side.winner || !hasWinner ? 1 : 0.6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var hasWinner: Bool { side.winner }
}

private struct StreamRow: View {
    let stream: MacSportsStream
    let game: MacSportsGame
    let primary: Bool
    @EnvironmentObject private var router: Router

    var body: some View {
        HStack(spacing: 12) {
            TeamLogo(url: stream.logo, size: 40, placeholder: "tv")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stream.name).font(.body.weight(.semibold)).lineLimit(1)
                    if let quality = stream.quality, !quality.isEmpty { Tag(text: quality) }
                    if !stream.sure { Tag(text: "Possible match") }
                }
                Text([stream.isAddon ? "Add-on" : stream.group, stream.airing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.jb(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Button { SportsPlayback.play(stream, game: game, router: router); MacSports.shared.pickStream(gameId: game.id, streamKey: stream.key) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent).tint(primary ? Theme.accentStart : nil).controlSize(.regular)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            if primary, DebugHarness.playFirstStream { SportsPlayback.play(stream, game: game, router: router) }
        }
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.jb(11, .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.surfaceRaised, in: Capsule()).foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Panels

private struct SummaryPanel: View {
    let detail: MacGameDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !detail.info.isEmpty {
                VStack(alignment: .leading, spacing: 4) { ForEach(detail.info, id: \.self) { Text($0).foregroundStyle(Theme.textSecondary) } }
            }
            if detail.homeWin >= 0, detail.awayWin >= 0 {
                HStack(spacing: 16) {
                    Text("Chance: away \(Int(detail.awayWin.rounded()))%")
                    if detail.draw > 0 { Text("draw \(Int(detail.draw.rounded()))%") }
                    Text("home \(Int(detail.homeWin.rounded()))%")
                }
                .font(.jb(14)).foregroundStyle(Theme.textSecondary)
            }
            if !detail.scoring.isEmpty { PlayList(title: "Scoring", plays: detail.scoring) }
            if !detail.leaders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Leaders").font(.jb(17, .semibold))
                    ForEach(Array(detail.leaders.enumerated()), id: \.offset) { _, leader in
                        HStack { Text(leader.category).foregroundStyle(Theme.textSecondary).frame(width: 150, alignment: .leading); Text(leader.name); Spacer(); Text(leader.value).monospacedDigit() }
                    }
                }
                .frame(maxWidth: 620)
            }
            if !detail.form.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent form").font(.jb(17, .semibold))
                    ForEach(Array(detail.form.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            Text(row.team).frame(width: 200, alignment: .leading)
                            ForEach(Array(row.results.enumerated()), id: \.offset) { _, r in FormDot(result: r) }
                        }
                    }
                }
            }
            if !detail.meetings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Previous meetings").font(.jb(17, .semibold))
                    ForEach(Array(detail.meetings.enumerated()), id: \.offset) { _, m in
                        HStack { Text(m.dateMs > 0 ? Date(timeIntervalSince1970: Double(m.dateMs) / 1000).formatted(date: .abbreviated, time: .omitted) : "").foregroundStyle(Theme.textSecondary).frame(width: 120, alignment: .leading); Text(m.text) }
                    }
                }
            }
            if !detail.plays.isEmpty { PlayList(title: "Key moments", plays: detail.plays) }
        }
    }
}

private struct FormDot: View {
    let result: String
    var body: some View {
        Text(result.prefix(1).uppercased()).font(.jb(12, .bold)).frame(width: 22, height: 22)
            .background(color, in: Circle()).foregroundStyle(.black.opacity(0.85))
    }
    private var color: Color {
        switch result.uppercased().prefix(1) {
        case "W": return Color(red: 0.35, green: 0.78, blue: 0.5)
        case "L": return Color(red: 0.92, green: 0.4, blue: 0.4)
        default: return Color.white.opacity(0.5)
        }
    }
}

private struct PlayList: View {
    let title: String
    let plays: [MacPlay]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.jb(17, .semibold))
            ForEach(Array(plays.prefix(40).enumerated()), id: \.offset) { _, play in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(play.clock).font(.jb(14).monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 56, alignment: .leading)
                    if let team = play.team, !team.isEmpty { Text(team).font(.jb(12, .bold)).frame(width: 40, alignment: .leading) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(play.headline)
                        if let detail = play.detail, !detail.isEmpty { Text(detail).font(.jb(12)).foregroundStyle(Theme.textSecondary) }
                    }
                    Spacer()
                    if let score = play.scoreAfter, !score.isEmpty { Text(score).font(.jb(14).monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                }
            }
        }
        .frame(maxWidth: 720)
    }
}

private struct StatsPanel: View {
    let detail: MacGameDetail
    let game: MacSportsGame

    var body: some View {
        VStack(spacing: 14) {
            if game.sides.count == 2 {
                HStack { Text(game.sides[0].abbr.isEmpty ? game.sides[0].name : game.sides[0].abbr); Spacer(); Text(game.sides[1].abbr.isEmpty ? game.sides[1].name : game.sides[1].abbr) }
                    .font(.jb(14, .semibold)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(detail.stats.enumerated()), id: \.offset) { _, stat in
                VStack(spacing: 4) {
                    HStack { Text(stat.away).monospacedDigit(); Spacer(); Text(stat.label).foregroundStyle(Theme.textSecondary); Spacer(); Text(stat.home).monospacedDigit() }.font(.jb(14))
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            Capsule().fill(Theme.accentStart.opacity(0.85)).frame(width: max(4, proxy.size.width * stat.awayShare))
                            Capsule().fill(Color.white.opacity(0.35))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .frame(maxWidth: 620)
    }
}

private struct LineupsPanel: View {
    let detail: MacGameDetail
    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            ForEach(Array(detail.lineups.enumerated()), id: \.offset) { _, lineup in
                VStack(alignment: .leading, spacing: 4) {
                    Text(lineup.team).font(.jb(17, .semibold))
                    if let formation = lineup.formation, !formation.isEmpty { Text(formation).font(.jb(12)).foregroundStyle(Theme.textSecondary) }
                    ForEach(lineup.players, id: \.self) { Text($0) }
                }
            }
        }
    }
}

private struct TablePanel: View {
    let detail: MacGameDetail
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = detail.tableTitle { Text(title).font(.jb(17, .semibold)) }
            if detail.tableHead.count >= 4 {
                HStack { Text("").frame(width: 36); Text(detail.tableHead[0]); Spacer(); Text(detail.tableHead[1]).frame(width: 50); Text(detail.tableHead[2]).frame(width: 50); Text(detail.tableHead[3]).frame(width: 50) }
                    .font(.jb(12)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(detail.table.enumerated()), id: \.offset) { _, row in
                HStack { Text(row.pos).frame(width: 36, alignment: .leading).foregroundStyle(Theme.textSecondary); Text(row.team).fontWeight(row.mine ? .bold : .regular); Spacer(); Text(row.a).frame(width: 50); Text(row.b).frame(width: 50); Text(row.c).frame(width: 50) }
                    .font(.jb(14).monospacedDigit())
            }
        }
        .frame(maxWidth: 560)
    }
}
