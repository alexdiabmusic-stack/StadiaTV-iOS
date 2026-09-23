import SwiftUI

struct NBAGameHeaderView: View {
    let game: BasketballGame
    let league: League
    private var clockText: String? {
        guard let seconds = game.gameClock else { return nil }
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
    var body: some View {
        VStack(spacing: 8) {
            Text(statusLine.uppercased()).font(.subheadline.bold())
            if let label = game.gameLabel { Text(label).font(.caption) }
            HStack(spacing: 12) {
                team(game.away)
                if game.status == .scheduled || game.status == .pregame {
                    Text(game.start, style: .time).font(.title2.bold())
                } else {
                    Text("\(game.away.score.map(String.init) ?? "–") – \(game.home.score.map(String.init) ?? "–")")
                        .font(.largeTitle.bold().monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1)
                        .accessibilityLabel("\(game.away.displayName) \(game.away.score.map(String.init) ?? "unknown"), \(game.home.displayName) \(game.home.score.map(String.init) ?? "unknown")")
                }
                team(game.home)
            }
            if game.status == .live {
                HStack(spacing: 20) {
                    timeouts(game.away, label: "\(game.away.tricode) TO")
                    if let broadcast = game.broadcasts.first { Text(broadcast).font(.caption).foregroundStyle(.secondary) }
                    timeouts(game.home, label: "\(game.home.tricode) TO")
                }
            }
        }.padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private var statusLine: String {
        switch game.status {
        case .final: return game.finalLabel
        case .live, .halftime: return [game.periodLabel, clockText].compactMap { $0 }.joined(separator: " ")
        default: return game.statusText
        }
    }
    private func team(_ team: BasketballTeam) -> some View {
        NavigationLink {
            TeamRosterView(league: league, teamID: String(team.id), teamName: team.displayName)
        } label: {
            VStack(spacing: 4) {
                TeamLogo(url: team.logo, size: 44).accessibilityHidden(true)
                Text(team.tricode).font(.headline)
                if let bonus = team.inBonus, bonus { Text("BONUS").font(.caption2.bold()).foregroundStyle(Theme.accessibleAccent) }
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("\(team.displayName). Team roster")
    }
    private func timeouts(_ team: BasketballTeam, label: String) -> some View {
        Group {
            if let remaining = team.timeoutsRemaining {
                HStack(spacing: 3) {
                    Text(label).font(.caption2.bold())
                    ForEach(0..<remaining, id: \.self) { _ in Image(systemName: "circle.fill").font(.caption2) }
                }
            }
        }.accessibilityElement(children: .combine)
    }
}
