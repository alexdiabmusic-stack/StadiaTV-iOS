import SwiftUI

/// Full team-stats list (every category the feed provides), used as the wide-iPad
/// Play-by-Play sidebar and at the top of Box Score. Overview shows only the
/// curated subset via `TeamStatsComparison`/`NHLGamePresentation.keyStats`.
struct NHLTeamStatsView: View {
    let stats: [HockeyTeamComparison]
    let game: HockeyGame?
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(game?.away.abbreviation ?? "Away")
                Spacer()
                Text("Team stats").foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(game?.home.abbreviation ?? "Home")
            }.font(.headline)
            ForEach(stats) { stat in
                HStack {
                    Text(stat.away).monospacedDigit().frame(minWidth: 35, alignment: .leading)
                    Spacer()
                    Text(stat.label).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    Spacer()
                    Text(stat.home).monospacedDigit().frame(minWidth: 35, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(stat.label). \(game?.away.name ?? "Away") \(stat.away). \(game?.home.name ?? "Home") \(stat.home)")
            }
            if stats.isEmpty { Text("Team statistics will appear when available.").foregroundStyle(Theme.textSecondary) }
        }.padding()
    }
}
