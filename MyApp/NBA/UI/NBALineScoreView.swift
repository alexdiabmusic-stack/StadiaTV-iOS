import SwiftUI

struct NBALineScoreView: View {
    let game: BasketballGame
    private var periods: [Int] {
        Array(Set(game.away.periods.map(\.period) + game.home.periods.map(\.period))).sorted()
    }
    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Team")
                    ForEach(periods, id: \.self) { period in Text(NBADuration.periodLabel(period, regulation: game.regulationPeriods)) }
                    Text("T").bold()
                }.foregroundStyle(.secondary)
                row(game.away)
                row(game.home)
            }.font(.subheadline.monospacedDigit()).padding()
        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func row(_ team: BasketballTeam) -> some View {
        GridRow {
            Text(team.tricode).bold()
            ForEach(periods, id: \.self) { period in
                let score = team.periods.first { $0.period == period }?.score
                Text(score.map(String.init) ?? "–")
                    .accessibilityLabel("\(team.displayName), \(NBADuration.periodLabel(period, regulation: game.regulationPeriods)), \(score.map(String.init) ?? "not played")")
            }
            Text(team.score.map(String.init) ?? "–").bold()
        }
    }
}
