import SwiftUI

/// Live/official table preview (Steps 40–42). Clearly labelled `LIVE TABLE` when
/// `isLive` — this is a projection, never persisted or shown as the confirmed table.
struct SoccerLiveTableView: View {
    let table: SoccerStandingsTable

    private var sortedEntries: [SoccerStandingsEntry] {
        table.entries.sorted { ($0.overall.position ?? Int.max) < ($1.overall.position ?? Int.max) }
    }

    /// Conference/group leagues (MLS) show their own label ("EASTERN CONFERENCE")
    /// instead of the plain single-table "TABLE"/"LIVE TABLE" EPL uses.
    private var headerText: String {
        let base = table.groupLabel ?? (table.isLive ? "LIVE TABLE" : "TABLE")
        return table.isLive && table.groupLabel != nil ? "\(base) (LIVE)" : base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerText).font(.caption.bold()).foregroundStyle(table.isLive ? Theme.live : Theme.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("POS").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
                    Text("CLUB").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
                    Text("GD").font(.caption2.bold()).foregroundStyle(Theme.textTertiary).gridColumnAlignment(.trailing)
                    Text("PTS").font(.caption2.bold()).foregroundStyle(Theme.textTertiary).gridColumnAlignment(.trailing)
                }
                ForEach(sortedEntries.prefix(6)) { entry in
                    GridRow {
                        Text("\(entry.overall.position ?? 0)").font(.caption)
                        Text(entry.team.shortName).font(.caption)
                        Text(entry.overall.goalDifference.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "–").font(.caption).monospacedDigit()
                        Text("\(entry.overall.points ?? 0)").font(.caption.bold()).monospacedDigit()
                    }
                }
            }
        }
        .padding()
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}
