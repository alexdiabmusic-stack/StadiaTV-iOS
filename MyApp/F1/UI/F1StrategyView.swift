import SwiftUI

struct F1StrategyView: View {
    let state: F1SessionState
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(state.drivers) { driver in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(driver.driver.tla) · \(driver.driver.team)").font(.headline)
                    if driver.stints.isEmpty { Text("Tyre data unavailable").foregroundStyle(.secondary) }
                    ForEach(driver.stints) { stint in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stint.compound + (stint.new.map { $0 ? " · New" : " · Used" } ?? "")).font(.caption.bold())
                            if let laps = stint.completedLaps ?? stint.laps {
                                ProgressView(value: Double(laps), total: Double(max(laps, state.totalLaps ?? 60))).tint(compoundColour(stint.compound))
                                Text((laps == 1 ? "1 lap in stint" : "\(laps) laps in stint") + (stint.startLap.map { " · From lap \($0)" } ?? "")).font(.caption)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                    if let stops = driver.stops { Text("\(stops) pit stops").font(.caption) }
                }
                Divider()
            }
            if !state.pitStops.isEmpty {
                Text("Pit stops").font(.title3.bold())
                ForEach(state.pitStops.sorted { ($0.lap ?? 0) > ($1.lap ?? 0) }) { stop in
                    HStack {
                        Text(state.drivers.first { $0.id == stop.driverNumber }?.driver.tla ?? stop.driverNumber)
                        if let lap = stop.lap { Text("Lap \(lap)") }
                        Spacer()
                        Text(stop.duration.map { "\($0) s" } ?? "Pit stop")
                        if let lane = stop.laneTime { Text("Lane \(lane) s").foregroundStyle(.secondary) }
                    }.font(.subheadline).accessibilityElement(children: .combine)
                }
            }
        }.padding()
    }
    private func compoundColour(_ name: String) -> Color {
        switch name { case "SOFT": .red; case "MEDIUM": .yellow; case "HARD": .gray; case "INTERMEDIATE": .green; case "WET": .blue; default: .secondary }
    }
}
