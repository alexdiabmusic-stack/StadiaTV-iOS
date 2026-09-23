import SwiftUI

struct NFLGameHeaderView: View {
    let game: NFLGameState
    var body: some View {
        VStack(spacing: 10) {
            Text(status).font(.subheadline.weight(.semibold))
            HStack(alignment: .center, spacing: 20) {
                team(game.away)
                if ![.scheduled, .pregame].contains(game.status), game.home.score != nil || game.away.score != nil {
                    Text("\(game.away.score.map(String.init) ?? "–") — \(game.home.score.map(String.init) ?? "–")")
                        .font(.largeTitle.bold()).monospacedDigit().minimumScaleFactor(0.6)
                        .accessibilityLabel("\(game.away.name) \(game.away.score.map(String.init) ?? "unknown"), \(game.home.name) \(game.home.score.map(String.init) ?? "unknown")")
                } else { Text(game.start, style: .time).font(.title2.bold()) }
                team(game.home)
            }
            if [.live, .halftime, .delayed].contains(game.status), let possession = game.possession {
                HStack { Label("\(possession.abbreviation) BALL", systemImage: "american.football.fill")
                    if let down = game.downDistance { Text(down).bold() }
                    if let field = game.field { Text(field.text) }
                }.font(.subheadline)
                if game.isRedZone == true { Text("RED ZONE").font(.caption.bold()) }
            }
        }.padding().frame(maxWidth: .infinity).background(Theme.surface)
    }
    private var status: String {
        if game.status == .halftime { return "HALFTIME" }
        if game.status == .live {
            let period = game.quarter.flatMap { value -> String? in
                if let number = Int(value) { return number > 4 ? "OT \(number - 4)" : "Q\(number)" }
                return ["FIRST": "Q1", "SECOND": "Q2", "THIRD": "Q3", "FOURTH": "Q4", "OVERTIME": "OT"][value] ?? value.replacingOccurrences(of: "_", with: " ")
            }
            return [period, game.clock].compactMap { $0 }.joined(separator: " • ")
        }
        return game.statusText.uppercased()
    }
    private func team(_ team: NFLTeamState) -> some View {
        NavigationLink {
            TeamRosterView(league: League(name: "NFL", shortName: "NFL", path: "football/nfl", group: .football), teamID: team.id, teamName: team.name)
        } label: {
            VStack(spacing: 5) {
                TeamLogo(url: team.logo, size: 44).accessibilityHidden(true)
                Text(team.abbreviation).font(.headline)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("\(team.name). Team roster")
    }
}
struct NFLFieldView: View {
    let position: NFLFieldPosition
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(position.text).font(.headline)
            if let yards = position.yardsToGoal {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.18))
                        HStack { ForEach(0..<11, id: \.self) { _ in Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1); Spacer(minLength: 0) } }.padding(.horizontal, 10)
                        Image(systemName: "american.football.fill").foregroundStyle(Theme.textPrimary)
                            .offset(x: max(0, (geometry.size.width - 24) * Double(100 - yards) / 100))
                    }
                }.frame(height: 48).accessibilityLabel("Ball at \(position.text), \(yards) yards to goal")
            }
        }
    }
}
struct NFLQuarterScoreView: View {
    let game: NFLGameState
    private var quarters: [String] {
        Set(game.home.quarters.keys).union(game.away.quarters.keys).filter { key in
            !key.hasPrefix("ot") || (game.home.quarters[key] ?? 0) > 0 || (game.away.quarters[key] ?? 0) > 0 || game.quarter?.contains("OVERTIME") == true
        }.sorted { rank($0) < rank($1) }
    }
    private func rank(_ key: String) -> Int { key.hasPrefix("q") ? Int(key.dropFirst()) ?? 0 : 4 + (Int(key.dropFirst(2)) ?? 1) }
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow { Text("Team"); ForEach(quarters, id: \.self) { Text($0.uppercased()) }; Text("T").bold() }
                ForEach([game.away, game.home]) { team in
                    GridRow { Text(team.abbreviation).bold(); ForEach(quarters, id: \.self) { Text(team.quarters[$0].map(String.init) ?? "–") }; Text(team.score.map(String.init) ?? "–").bold() }
                }
            }.font(.subheadline).monospacedDigit().padding(.vertical, 8)
        }
    }
}
