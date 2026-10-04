import SwiftUI

struct NHLBoxScoreView: View {
    let players: [HockeyPlayerGameStats]
    let teamStats: [HockeyTeamComparison]
    let game: HockeyGame?
    let league: League
    @State private var homeSelected = false
    private var rows: [HockeyPlayerGameStats] {
        players.filter { $0.teamID == (homeSelected ? game?.home.id : game?.away.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NHLTeamStatsView(stats: teamStats, game: game)
            Picker("Team", selection: $homeSelected) {
                Text(game?.away.abbreviation ?? "Away").tag(false)
                Text(game?.home.abbreviation ?? "Home").tag(true)
            }.pickerStyle(.segmented)
            ForEach(["Forwards", "Defensemen", "Goalies"], id: \.self) { group in
                Section {
                    ForEach(rows.filter { $0.group == group }) { row in
                        NHLPlayerDisclosure {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: 14) {
                                ForEach(row.stats) { stat in
                                    VStack(alignment: .leading) {
                                        Text(stat.label).font(.caption).foregroundStyle(Theme.textSecondary)
                                        Text(stat.value).font(.body.monospacedDigit())
                                    }.accessibilityElement(children: .combine)
                                }
                            }.padding(.vertical, 12)
                            NavigationLink("Player details") {
                                PlayerDetailView(league: league, athlete: NHLProvider.athlete(row.player))
                            }.frame(minHeight: 44)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.player.name).font(.headline)
                                Text(summary(row)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            }.padding(.vertical, 8)
                        }
                    }
                } header: { Text(group).font(.title3.bold()).padding(.top, 8) }
            }
            if rows.isEmpty { Text("Player statistics will appear when available.").foregroundStyle(Theme.textSecondary) }
        }.padding()
    }
    private func summary(_ row: HockeyPlayerGameStats) -> String {
        let keys = row.group == "Goalies" ? ["saves", "shotsAgainst", "goalsAgainst", "toi"] : ["goals", "assists", "points", "sog", "toi"]
        return row.stats.filter { keys.contains($0.id) }.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
    }
}

private struct NHLPlayerDisclosure<Content: View, Label: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var expanded = false
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 16) {
            Button { expanded.toggle() } label: {
                HStack {
                    label()
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.padding()
            }.buttonStyle(.card)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content() }
        }
        #else
        DisclosureGroup(content: content, label: label)
        #endif
    }
}
