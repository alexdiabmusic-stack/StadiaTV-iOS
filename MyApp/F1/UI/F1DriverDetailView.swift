import SwiftUI

struct F1DriverDetailView: View {
    let timing: F1DriverTimingState
    let session: F1SessionState
    let highFrequency: F1HighFrequencyViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                if let url = timing.driver.headshot {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "person.crop.circle") }.frame(width: 64, height: 64).accessibilityHidden(true)
                }
                VStack(alignment: .leading) {
                    Text(timing.driver.name).font(.title2.bold())
                    Text(timing.driver.team).foregroundStyle(.secondary)
                }
            }
            F1DriverTimingRow(timing: timing, type: session.type)
            ForEach(timing.sectors) { sector in
                VStack(alignment: .leading, spacing: 6) {
                    Text("S\((Int(sector.id) ?? 0) + 1) · \(sector.time ?? "–")").font(.subheadline.monospacedDigit())
                    HStack(spacing: 3) {
                        ForEach(Array(sector.segments.enumerated()), id: \.offset) { _, segment in
                            RoundedRectangle(cornerRadius: 2).fill(colour(segment)).frame(height: 8)
                        }
                    }.accessibilityLabel(sector.segments.map { $0 == .overallBest ? "Session best" : $0 == .personalBest ? "Personal best" : $0 == .unknown ? "Segment status unavailable" : "Neutral segment" }.joined(separator: ", "))
                }
            }
            if !timing.speeds.isEmpty {
                Text("Speed traps · km/h").font(.headline)
                ForEach(timing.speeds.keys.sorted(), id: \.self) { key in HStack { Text(key); Spacer(); Text(timing.speeds[key] ?? "–").monospacedDigit() } }
            }
            F1TelemetryView(driver: timing.id, model: highFrequency)
            let radio = session.radio.filter { $0.driverNumber == timing.id }
            if !radio.isEmpty { Text("Recent radio").font(.headline); F1TeamRadioView(state: radioState(radio)) }
        }.padding()
    }
    private func radioState(_ messages: [F1TeamRadioMessage]) -> F1SessionState { var state = session; state.radio = Array(messages.suffix(3)); return state }
    private func colour(_ value: F1Performance) -> Color { value == .overallBest ? .purple : value == .personalBest ? .green : .gray }
}

/// Only this leaf observes telemetry; timing rows do not invalidate at sample frequency.
struct F1TelemetryView: View {
    let driver: String
    let model: F1HighFrequencyViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telemetry").font(.headline)
            if let sample = model.state.telemetry[driver] {
                if let speed = sample.speed { LabeledContent("Speed", value: "\(Int(speed)) km/h") }
                if let gear = sample.gear { LabeledContent("Gear", value: String(gear)) }
                if let rpm = sample.rpm { LabeledContent("RPM", value: String(Int(rpm))) }
                if let throttle = sample.throttle { ProgressView("Throttle \(Int(throttle))%", value: min(100, max(0, throttle)), total: 100) }
                if let brake = sample.brake { LabeledContent("Brake", value: brake > 0 ? "On" : "Off") }
                Text("Sample \(sample.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            } else { Text("Telemetry unavailable").foregroundStyle(.secondary) }
        }.monospacedDigit()
    }
}
