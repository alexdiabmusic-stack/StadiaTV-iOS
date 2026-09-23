import SwiftUI

struct F1TrackMapView: View {
    let session: F1SessionState
    let model: F1HighFrequencyViewModel
    @Binding var selected: String?
    var showSelectedCard = true
    var body: some View {
        let points = model.state.positions.filter { $0.value.x != 0 || $0.value.y != 0 }
        VStack(alignment: .leading, spacing: 12) {
            if points.isEmpty {
                ContentUnavailableView("Live track positions unavailable", systemImage: "location.slash", description: Text("Timing remains available in the Timing tab."))
            } else {
                Text(session.trackStatus).font(.headline)
                GeometryReader { geometry in
                    let trails = model.state.trails.values.flatMap { $0 }.filter { $0.x != 0 || $0.y != 0 }
                    let all = trails + Array(points.values)
                    let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 1
                    let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 1
                    let scale = min(max(1, geometry.size.width - 60) / max(1, maxX - minX), max(1, geometry.size.height - 60) / max(1, maxY - minY))
                    let offsetX = (geometry.size.width - (maxX - minX) * scale) / 2
                    let offsetY = (geometry.size.height - (maxY - minY) * scale) / 2
                    ZStack {
                        Canvas { context, _ in
                            for trail in model.state.trails.values {
                                var path = Path()
                                for (index, point) in trail.filter({ $0.x != 0 || $0.y != 0 }).enumerated() {
                                    let mapped = CGPoint(x: offsetX + (point.x - minX) * scale, y: offsetY + (maxY - point.y) * scale)
                                    if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                                }
                                context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 3)
                            }
                        }.accessibilityHidden(true)
                        ForEach(session.drivers.filter { points[$0.id] != nil }) { driver in
                            if let point = points[driver.id] {
                                Button { selected = driver.id } label: {
                                    Text(driver.driver.tla).font(.caption.bold()).padding(6)
                                        .background(selected == driver.id ? Theme.accessibleAccent : Theme.surfaceElevated, in: Capsule())
                                        .overlay(Capsule().stroke(driver.position == 1 ? Color.primary : Color.clear, lineWidth: 2))
                                }.buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                                    .position(x: offsetX + (point.x - minX) * scale, y: offsetY + (maxY - point.y) * scale)
                                    .accessibilityLabel("\(driver.driver.name), position \(driver.position.map(String.init) ?? "unknown")")
                            }
                        }
                    }.animation(.linear(duration: 0.2), value: model.state.positions)
                }.frame(minHeight: 320)
                if showSelectedCard, let driver = session.drivers.first(where: { $0.id == selected }) {
                    F1DriverTimingRow(timing: driver, type: session.type)
                    if let speed = model.state.telemetry[driver.id]?.speed { Text("Speed \(Int(speed)) km/h").font(.subheadline.monospacedDigit()) }
                }
                Text("Observed position trails").font(.caption).foregroundStyle(.secondary)
            }
        }.padding()
    }
}
