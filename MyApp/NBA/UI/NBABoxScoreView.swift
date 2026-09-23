import SwiftUI

struct NBAPlayerLink: View {
    let personID: Int
    let name: String
    let league: League
    var body: some View {
        NavigationLink {
            PlayerDetailView(league: league, athlete: NBALegacyMapper.athlete(id: personID, name: name, jersey: nil, position: nil))
        } label: { Text(name).font(.headline).frame(minHeight: 44, alignment: .leading) }
        .buttonStyle(.plain)
    }
}

struct NBABoxScoreView: View {
    let snapshot: BasketballGameSnapshot
    let league: League
    @State private var home = false

    /// Defined once so iOS and tvOS can't diverge on which columns render, and a
    /// missing stat renders "—" rather than a misleading 0.
    private static let columns: [(label: String, value: (NBAPlayerGameLine) -> String)] = [
        ("MIN", { $0.minutesText }),
        ("PTS", { $0.stat("points").map { String(Int($0)) } ?? "—" }),
        ("REB", { $0.stat("reboundsTotal").map { String(Int($0)) } ?? "—" }),
        ("AST", { $0.stat("assists").map { String(Int($0)) } ?? "—" }),
        ("FG", { fraction($0, "fieldGoalsMade", "fieldGoalsAttempted") }),
        ("3PT", { fraction($0, "threePointersMade", "threePointersAttempted") }),
        ("FT", { fraction($0, "freeThrowsMade", "freeThrowsAttempted") }),
        ("STL", { $0.stat("steals").map { String(Int($0)) } ?? "—" }),
        ("BLK", { $0.stat("blocks").map { String(Int($0)) } ?? "—" }),
        ("TO", { $0.stat("turnovers").map { String(Int($0)) } ?? "—" }),
        ("PF", { $0.stat("foulsPersonal").map { String(Int($0)) } ?? "—" }),
        ("+/-", { $0.stat("plusMinusPoints").map { String(Int($0)) } ?? "—" })
    ]
    private static func fraction(_ line: NBAPlayerGameLine, _ made: String, _ attempted: String) -> String {
        guard let made = line.stat(made), let attempted = line.stat(attempted) else { return "—" }
        return "\(Int(made))-\(Int(attempted))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let game = snapshot.game {
                NBALineScoreView(game: game)
                Picker("Team", selection: $home) {
                    Text(game.away.tricode).tag(false); Text(game.home.tricode).tag(true)
                }.pickerStyle(.segmented)
                let lines = (home ? snapshot.homeBox : snapshot.awayBox).sorted {
                    $0.starter != $1.starter ? $0.starter : ($0.order ?? Int.max) < ($1.order ?? Int.max)
                }
                let starters = lines.filter(\.starter)
                let bench = lines.filter { !$0.starter && $0.played }
                let dnp = lines.filter { $0.isDNP }
                if !starters.isEmpty { table("Starters", starters) }
                if !bench.isEmpty { table("Bench", bench) }
                if !dnp.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Did not play").font(.title3.bold())
                        ForEach(dnp) { line in
                            Text([line.name, line.notPlayingReason].compactMap { $0 }.joined(separator: " — ")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if lines.isEmpty { Text("Player statistics will appear when available.").foregroundStyle(.secondary) }
            }
        }.padding()
    }
    private func table(_ title: String, _ lines: [NBAPlayerGameLine]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        NBAPlayerLink(personID: line.personID, name: line.name, league: league)
                        if line.onCourt { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(Theme.accessibleAccent).accessibilityLabel("On court") }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 10) {
                        ForEach(Self.columns, id: \.label) { column in
                            VStack(spacing: 3) {
                                Text(column.label).font(.caption).foregroundStyle(.secondary)
                                Text(column.value(line)).font(.subheadline.monospacedDigit())
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    Divider()
                }
            }
        }
    }
}
