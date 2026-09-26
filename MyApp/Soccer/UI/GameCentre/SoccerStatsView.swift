import SwiftUI

/// Match Stats tab (Steps 29–34): paired comparison rows with bars only where
/// visually meaningful. A metric the provider didn't supply hides its row entirely —
/// never renders as a fake `0.00` (Step 34).
struct SoccerStatsView: View {
    let home: SoccerTeamMatchStats?
    let away: SoccerTeamMatchStats?
    let homeAbbr: String
    let awayAbbr: String
    @State private var showAdvanced = false

    private struct Row { let title: String; let home: Double?; let away: Double?; let isPercent: Bool }

    private var primaryRows: [Row] {
        [Row(title: "Expected Goals (xG)", home: home?.expectedGoals, away: away?.expectedGoals, isPercent: false),
         Row(title: "Possession", home: home?.possession, away: away?.possession, isPercent: true),
         Row(title: "Shots", home: home?.shots, away: away?.shots, isPercent: false),
         Row(title: "Shots on Target", home: home?.shotsOnTarget, away: away?.shotsOnTarget, isPercent: false),
         Row(title: "Big Chances", home: home?.bigChancesCreated, away: away?.bigChancesCreated, isPercent: false),
         Row(title: "Corners", home: home?.corners, away: away?.corners, isPercent: false)].filter { $0.home != nil || $0.away != nil }
    }
    private var advancedRows: [Row] {
        [Row(title: "Passes", home: home?.passes, away: away?.passes, isPercent: false),
         Row(title: "Pass Accuracy", home: passAccuracy(home), away: passAccuracy(away), isPercent: true),
         Row(title: "Crosses", home: home?.crosses, away: away?.crosses, isPercent: false),
         Row(title: "Tackles", home: home?.tackles, away: away?.tackles, isPercent: false),
         Row(title: "Interceptions", home: home?.interceptions, away: away?.interceptions, isPercent: false),
         Row(title: "Clearances", home: home?.clearances, away: away?.clearances, isPercent: false),
         Row(title: "Duels Won", home: home?.duelsWon, away: away?.duelsWon, isPercent: false),
         Row(title: "Aerial Duels Won", home: home?.aerialDuelsWon, away: away?.aerialDuelsWon, isPercent: false),
         Row(title: "Touches in Box", home: home?.touchesInOppositionBox, away: away?.touchesInOppositionBox, isPercent: false),
         Row(title: "Final Third Entries", home: home?.finalThirdEntries, away: away?.finalThirdEntries, isPercent: false),
         Row(title: "Fouls", home: home?.fouls, away: away?.fouls, isPercent: false),
         Row(title: "Offsides", home: home?.offsides, away: away?.offsides, isPercent: false),
         Row(title: "Saves", home: home?.saves, away: away?.saves, isPercent: false)].filter { $0.home != nil || $0.away != nil }
    }
    private func passAccuracy(_ stats: SoccerTeamMatchStats?) -> Double? {
        guard let passes = stats?.passes, passes > 0, let completed = stats?.passesCompleted else { return nil }
        return completed / passes * 100
    }

    /// Pitch-zone entry counts (e.g. MLS's 4 attacking zones) — only shown when a
    /// provider actually supplies them (EPL never does). Entry counts, not a
    /// possession time-series: this app has no per-interval possession data to plot.
    private var zoneRows: [Row] {
        guard let home, let away, !home.attackingZones.isEmpty || !away.attackingZones.isEmpty else { return [] }
        let zoneIDs = Set(home.attackingZones.map(\.zoneID) + away.attackingZones.map(\.zoneID)).sorted()
        return zoneIDs.map { id in
            Row(title: "Attacking Zone \(id) Entries", home: home.attackingZones.first { $0.zoneID == id }.map { Double($0.entries) },
                away: away.attackingZones.first { $0.zoneID == id }.map { Double($0.entries) }, isPercent: false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if home == nil && away == nil {
                    ContentUnavailableView("No statistics yet", systemImage: "chart.bar", description: Text("Match statistics will appear after kickoff."))
                } else {
                    header
                    ForEach(primaryRows, id: \.title) { statRow($0) }
                    if !advancedRows.isEmpty {
                        Button(showAdvanced ? "Show less" : "Show more") { withAnimation { showAdvanced.toggle() } }.font(.subheadline.bold())
                        if showAdvanced { ForEach(advancedRows, id: \.title) { statRow($0) } }
                    }
                    if !zoneRows.isEmpty {
                        Text("ATTACKING ZONES").font(.caption.bold()).foregroundStyle(Theme.textSecondary).padding(.top, 8)
                        ForEach(zoneRows, id: \.title) { statRow($0) }
                    }
                }
            }.padding()
        }
    }

    private var header: some View {
        HStack {
            Text(homeAbbr).font(.subheadline.bold())
            Spacer()
            Text(awayAbbr).font(.subheadline.bold())
        }
    }

    private func statRow(_ row: Row) -> some View {
        let home = row.home ?? 0, away = row.away ?? 0
        let total = max(home + away, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            Text(row.title.uppercased()).font(.caption2.bold()).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Text(display(row.home, percent: row.isPercent)).frame(width: 46, alignment: .leading).monospacedDigit()
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        Rectangle().fill(Theme.accessibleAccent).frame(width: geometry.size.width * (home / total))
                        Rectangle().fill(Theme.textTertiary.opacity(0.4)).frame(width: geometry.size.width * (away / total))
                    }.clipShape(RoundedRectangle(cornerRadius: 3))
                }.frame(height: 8)
                Text(display(row.away, percent: row.isPercent)).frame(width: 46, alignment: .trailing).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title): \(homeAbbr) \(display(row.home, percent: row.isPercent)), \(awayAbbr) \(display(row.away, percent: row.isPercent))")
    }

    private func display(_ value: Double?, percent: Bool) -> String {
        guard let value else { return "–" }
        if percent { return "\(Int(value.rounded()))%" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
