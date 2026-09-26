import SwiftUI

/// The field bar's proportions come from `geometry`, not a fixed 100-yard assumption —
/// CFL's 110-yard field renders at genuinely different tick spacing and ball offset than
/// NFL's, not a relabeled copy (default preserves existing NFL call sites unchanged).
struct FootballFieldView: View {
    let position: FootballFieldPosition
    var geometry: FootballFieldGeometry = .nfl
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(position.text).font(.headline)
            if let yards = position.yardsToGoal {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.18))
                        HStack { ForEach(0..<geometry.tickCount, id: \.self) { _ in Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1); Spacer(minLength: 0) } }.padding(.horizontal, 10)
                        Image(systemName: "american.football.fill").foregroundStyle(Theme.textPrimary)
                            .offset(x: max(0, (proxy.size.width - 24) * geometry.ballOffsetFraction(yardsToGoal: yards)))
                    }
                }.frame(height: 48).accessibilityLabel("Ball at \(position.text), \(yards) yards to goal")
            }
        }
    }
}
/// Takes the two team states directly (rather than a whole league-specific game object) so
/// every football league can reuse the same quarter-score grid.
struct FootballQuarterScoreView: View {
    let home: FootballTeamState
    let away: FootballTeamState
    var overtimeActive: Bool = false
    private var quarters: [String] {
        Set(home.quarters.keys).union(away.quarters.keys).filter { key in
            !key.hasPrefix("ot") || (home.quarters[key] ?? 0) > 0 || (away.quarters[key] ?? 0) > 0 || overtimeActive
        }.sorted { rank($0) < rank($1) }
    }
    private func rank(_ key: String) -> Int { key.hasPrefix("q") ? Int(key.dropFirst()) ?? 0 : 4 + (Int(key.dropFirst(2)) ?? 1) }
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow { Text("Team"); ForEach(quarters, id: \.self) { Text($0.uppercased()) }; Text("T").bold() }
                ForEach([away, home]) { team in
                    GridRow { Text(team.abbreviation).bold(); ForEach(quarters, id: \.self) { Text(team.quarters[$0].map(String.init) ?? "–") }; Text(team.score.map(String.init) ?? "–").bold() }
                }
            }.font(.subheadline).monospacedDigit().padding(.vertical, 8)
        }
    }
}
struct FootballPlayRow: View {
    let play: FootballPlay
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: play.scoring ? "american.football.fill" : play.turnover ? "arrow.uturn.backward" : play.penalty ? "flag.fill" : "circle.fill")
                Text(play.type.label.uppercased()).font(.caption.bold()); Spacer(); Text(play.clock ?? "").monospacedDigit()
            }
            if let down = play.down, (1...play.totalDowns).contains(down) {
                Text("\(footballOrdinal(down)) & \(play.goalToGo ? "Goal" : play.distance.map(String.init) ?? "–") • \(play.field ?? "")").font(.caption).foregroundStyle(.secondary)
            }
            Text(play.text).font(play.scoring ? .headline : .body).fixedSize(horizontal: false, vertical: true)
            if play.participants.contains(where: { [3, 4, 5].contains($0.rawStatType ?? -1) }) { Text("FIRST DOWN").font(.caption.bold()) }
            if play.turnover { Label("Turnover", systemImage: "arrow.uturn.backward").font(.caption.bold()) }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(play.scoring ? Theme.surfaceElevated : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) { if play.scoring { RoundedRectangle(cornerRadius: 2).fill(Theme.accessibleAccent).frame(width: 3) } }
            .accessibilityElement(children: .combine)
            #if os(tvOS)
            .focusable()
            #endif
    }
}
struct FootballDriveView: View {
    let drive: FootballGameDrive
    let plays: [FootballPlay]
    let team: FootballTeamState?
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("\(team?.abbreviation ?? "") DRIVE").font(.headline); Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    Text([drive.startQuarter.map { $0 > 4 ? "OT \($0 - 4)" : "Q\($0)" }, drive.playCount.map { "\($0) plays" }, drive.yards.map { "\($0) yards" }, drive.timeOfPossession].compactMap { $0 }.joined(separator: " • ")).font(.subheadline)
                    if let result = drive.result { Text(result.uppercased()).font(.subheadline.bold()) }
                    if let start = drive.startField, let end = drive.endField { Text("\(start) → \(end)").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityHint("Show or hide drive plays")
            if expanded { ForEach(plays.reversed()) { FootballPlayRow(play: $0) } }
        }
    }
}
