import SwiftUI

struct F1SessionHeaderView: View {
    let state: F1SessionState
    let live: Bool
    let connection: F1ConnectionState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.meeting.uppercased()).font(.headline)
            HStack {
                Text(state.name.uppercased()).font(.subheadline.bold())
                if state.type.isQualifying, let phase = state.phase { Text("Q\(phase)").bold() }
                Spacer()
                Text(state.finalised ? "FINAL" : live ? "LIVE" : connection == .reconnecting ? "RECONNECTING" : state.active ? "LIVE DATA DELAYED" : state.status == "Ends" ? "SESSION ENDED" : state.status.uppercased()).font(.caption.bold())
            }
            HStack {
                if state.type.isRace, let lap = state.currentLap {
                    Text("LAP \(lap)" + (state.totalLaps.map { " / \($0)" } ?? "")).font(.title2.bold()).monospacedDigit()
                } else if let clock = state.clock {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let seconds = clock.seconds(at: context.date) {
                            Text(String(format: "%02d:%02d REMAINING", seconds / 60, seconds % 60)).font(.title2.bold()).monospacedDigit()
                        }
                    }
                }
                Spacer()
                Label(state.trackStatus, systemImage: "flag.fill").font(.subheadline.bold())
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface)
        .accessibilityElement(children: .combine)
    }
}

struct F1DriverTimingRow: View {
    let timing: F1DriverTimingState
    let type: F1SessionType
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let colour = timing.driver.colour.flatMap({ UInt($0, radix: 16) }) { Capsule().fill(Color(hex: colour)).frame(width: 3, height: 20).accessibilityHidden(true) }
                Text(timing.position.map { "P\($0)" } ?? "–").font(.title3.bold()).frame(minWidth: 38, alignment: .leading)
                Text(timing.driver.tla).font(.headline)
                Text(timing.driver.team).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(type.isRace ? (timing.position == 1 ? "LEADER" : timing.gap ?? "–") : timing.bestLap ?? "–").font(.headline).monospacedDigit()
            }
            HStack {
                if let tyre = timing.stints.last { Text(tyre.compound + (tyre.laps.map { " · \($0)L" } ?? "")) }
                if timing.inPit { Label("PIT", systemImage: "wrench.fill") }
                if timing.retired { Text("RETIRED") }
                else if timing.stopped { Text("STOPPED") }
                if timing.knockedOut { Text("ELIMINATED") }
                if let status = timing.classificationStatus, status != "Finished" { Text(status) }
                Spacer()
                if let interval = timing.interval { Text("\(interval) ahead") }
            }.font(.caption)
            HStack {
                if let last = timing.lastLap { Text("LAST \(last)") }
                if let best = timing.bestLap { Text("BEST \(best)") }
                if let laps = timing.laps, !type.isRace { Text("\(laps) laps") }
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if timing.overallFastest { Label("Session best lap", systemImage: "stopwatch.fill").font(.caption.bold()).foregroundStyle(.purple) }
            else if timing.personalFastest { Label("Personal best lap", systemImage: "checkmark.circle").font(.caption) }
            if type.isQualifying, !timing.qualifyingTimes.isEmpty {
                Text(timing.qualifyingTimes.enumerated().map { "Q\($0.offset + 1) \($0.element)" }.joined(separator: "   ")).font(.caption).monospacedDigit()
            }
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position \(timing.position.map(String.init) ?? "unknown"), \(timing.driver.name), \(timing.driver.team). \(type.isRace ? timing.gap ?? "" : timing.bestLap ?? ""). \(timing.stints.last?.compound ?? "") tyre. \(timing.stints.last?.laps.map { "\($0) laps on tyre" } ?? "")")
    }
}

struct F1WeatherView: View {
    let weather: F1WeatherState
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { measurements }
            VStack(alignment: .leading, spacing: 8) { measurements }
        }.font(.subheadline).accessibilityElement(children: .combine)
    }
    @ViewBuilder private var measurements: some View {
        if let track = weather.track { Text("Track \(track, specifier: "%.0f")°C") }
        if let air = weather.air { Text("Air \(air, specifier: "%.0f")°C") }
        if let wind = weather.windKPH { Text("Wind \(wind, specifier: "%.0f") km/h") }
        if let rain = weather.raining { Label(rain ? "Rain" : "Dry", systemImage: rain ? "cloud.rain" : "sun.max") }
    }
}
