import SwiftUI

struct NHLGameHeaderView: View {
    let game: HockeyGame
    let league: League
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                if game.status == .live { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.live) }
                Text(game.statusLabel).font(.subheadline.weight(.semibold))
                if game.status == .live, let clock = game.clock {
                    Text(clock).font(.headline.monospacedDigit())
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 12) {
                team(game.away)
                if game.status == .scheduled || game.status == .pregame {
                    Text(game.start, style: .time).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                } else {
                    Text("\(game.away.score.map(String.init) ?? "–")  –  \(game.home.score.map(String.init) ?? "–")")
                        .font(.largeTitle.bold().monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1)
                        .accessibilityLabel("\(game.away.name) \(game.away.score ?? 0), \(game.home.name) \(game.home.score ?? 0)")
                }
                team(game.home)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }
    private func team(_ team: HockeyTeam) -> some View {
        NavigationLink {
            TeamRosterView(league: league, teamID: String(team.id), teamName: team.name)
        } label: {
            VStack(spacing: 6) {
                TeamLogo(url: team.logo, size: 48).accessibilityHidden(true)
                Text(team.abbreviation).font(.headline)
                if let shots = team.shots { Text("SOG \(shots)").font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(team.name), \(team.shots.map { "\($0) shots on goal" } ?? ""). Team roster")
    }
}
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
struct NHLBoxScoreView: View {
    let players: [HockeyPlayerGameStats]
    let game: HockeyGame?
    let league: League
    @State private var homeSelected = false
    private var rows: [HockeyPlayerGameStats] {
        players.filter { $0.teamID == (homeSelected ? game?.home.id : game?.away.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
