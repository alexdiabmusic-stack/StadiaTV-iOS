import SwiftUI

struct MLBGameHeaderView: View {
    let game: BaseballGame
    let line: BaseballLineScore?
    let league: League
    var body: some View {
        VStack(spacing: 8) {
            Text(game.status == .live ? line?.label.uppercased() ?? game.detailedStatus : game.detailedStatus.uppercased())
                .font(.subheadline.bold())
            if game.doubleHeader != nil && game.doubleHeader != "N", let number = game.gameNumber { Text("Game \(number)").font(.caption) }
            HStack(spacing: 12) {
                team(game.away, hits: line?.awayHits, errors: line?.awayErrors)
                if [.scheduled, .pregame, .warmup].contains(game.status) {
                    Text(game.start, style: .time).font(.title2.bold())
                } else {
                    Text("\(game.away.runs.map(String.init) ?? "–") – \(game.home.runs.map(String.init) ?? "–")")
                        .font(.largeTitle.bold().monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1)
                        .accessibilityLabel("\(game.away.name) \(game.away.runs.map(String.init) ?? "unknown"), \(game.home.name) \(game.home.runs.map(String.init) ?? "unknown")")
                }
                team(game.home, hits: line?.homeHits, errors: line?.homeErrors)
            }
            if game.status == .live, let line, !line.betweenInnings {
                HStack(spacing: 22) {
                    MLBBaseDiamondView(bases: line.bases).frame(width: 80, height: 60)
                    MLBCountView(count: line.count)
                }
            }
        }.padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private func team(_ team: BaseballTeam, hits: Int?, errors: Int?) -> some View {
        NavigationLink {
            TeamRosterView(league: league, teamID: String(team.id), teamName: team.name)
        } label: {
            VStack(spacing: 4) {
                TeamLogo(url: team.logo, size: 44).accessibilityHidden(true)
                Text(team.abbreviation).font(.headline)
                if let hits, let errors { Text("H \(hits) · E \(errors)").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("\(team.name). Team roster")
    }
}
struct MLBBaseDiamondView: View {
    let bases: BaseballBaseState
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: w / 2, y: h - 6)); path.addLine(to: CGPoint(x: w - 10, y: h / 2))
                    path.addLine(to: CGPoint(x: w / 2, y: 8)); path.addLine(to: CGPoint(x: 10, y: h / 2)); path.closeSubpath()
                }.stroke(.secondary.opacity(0.5), lineWidth: 1)
                base(bases.second != nil).position(x: geometry.size.width / 2, y: 8)
                base(bases.first != nil).position(x: geometry.size.width - 10, y: geometry.size.height / 2)
                base(bases.third != nil).position(x: 10, y: geometry.size.height / 2)
                Image(systemName: "house.fill").font(.caption2).position(x: geometry.size.width / 2, y: geometry.size.height - 6)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(bases.accessibilityLabel)
    }
    private func base(_ occupied: Bool) -> some View {
        Image(systemName: occupied ? "diamond.fill" : "diamond").font(.body.bold()).foregroundStyle(occupied ? Theme.accessibleAccent : Theme.textSecondary)
            .background(Theme.surface)
    }
}
struct MLBCountView: View {
    let count: BaseballCount
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let balls = count.balls, let strikes = count.strikes { Text("\(balls)–\(strikes) COUNT").font(.subheadline.bold().monospacedDigit()).accessibilityLabel("\(balls) balls, \(strikes) strikes") }
            if let outs = count.outs {
                HStack(spacing: 5) {
                    Text("OUTS").font(.caption.bold())
                    ForEach(0..<3) { index in Image(systemName: index < outs ? "circle.fill" : "circle").font(.caption) }
                }.accessibilityElement(children: .ignore).accessibilityLabel("\(outs) outs")
            }
        }.accessibilityElement(children: .combine)
    }
}
