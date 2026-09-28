import SwiftUI

/// One stroke's row. Never fabricates club choice — only shows what the
/// provider actually returned (STEP 31).
struct GolfShotRow: View {
    let shot: GolfShot
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(shot.strokeNumber)")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(isSelected ? Theme.accessibleAccent.opacity(0.25) : Theme.surfaceElevated))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(shot.fromLie.displayName).font(.subheadline.bold())
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.textTertiary)
                    Text(shot.toLie.displayName).font(.subheadline.bold())
                }
                if let type = shot.strokeTypeRaw, !type.isEmpty {
                    Text(type).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 12) {
                    if let distance = shot.distance?.displayValue ?? shot.distance?.value.map({ String(format: "%.0f", $0) }) {
                        Label(distance, systemImage: "arrow.up.right").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if let remaining = shot.distanceRemaining?.displayValue ?? shot.distanceRemaining?.value.map({ String(format: "%.0f", $0) }) {
                        Label("\(remaining) remaining", systemImage: "scope").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let description = shot.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shot \(shot.strokeNumber). \(shot.fromLie.displayName) to \(shot.toLie.displayName).\(shot.distanceRemaining?.displayValue.map { " \($0) remaining." } ?? "")")
    }
}

struct GolfShotTimelineView: View {
    let shotRound: GolfShotRound?
    let isLoading: Bool
    let onLoadRound: (Int) -> Void
    @State private var selectedHoleNumber: Int?
    @State private var selectedShotID: String?
    let currentRound: Int

    private var selectedHole: GolfShotHole? {
        guard let shotRound else { return nil }
        return shotRound.holes.first { $0.holeNumber == selectedHoleNumber } ?? shotRound.holes.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let shotRound, !shotRound.holes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shotRound.holes) { hole in
                            Button {
                                selectedHoleNumber = hole.holeNumber
                                selectedShotID = nil
                            } label: {
                                Text("\(hole.holeNumber)")
                                    .font(.subheadline.bold())
                                    .frame(width: 36, height: 36)
                                    .background((selectedHole?.holeNumber == hole.holeNumber) ? Theme.accessibleAccent.opacity(0.2) : Theme.surfaceElevated, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let hole = selectedHole {
                    HStack {
                        Text("HOLE \(hole.holeNumber)").font(.headline)
                        if let par = hole.par { Text("PAR \(par)").font(.subheadline).foregroundStyle(Theme.textSecondary) }
                        if let yardage = hole.yardage { Text("\(yardage) YDS").font(.subheadline).foregroundStyle(Theme.textSecondary) }
                        Spacer()
                        if let score = hole.scoreDisplay { Text(score.uppercased()).font(.subheadline.bold()) }
                    }

                    GolfShotTraceView(shots: hole.shots, selectedShotID: selectedShotID)

                    LazyVStack(spacing: 0) {
                        ForEach(hole.shots) { shot in
                            Button { selectedShotID = (selectedShotID == shot.id) ? nil : shot.id } label: {
                                GolfShotRow(shot: shot, isSelected: selectedShotID == shot.id)
                            }
                            .buttonStyle(.plain)
                            if shot.id != hole.shots.last?.id { Divider().overlay(Theme.hairline) }
                        }
                    }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ContentUnavailableView("No Shot Data", systemImage: "location.viewfinder", description: Text("Shot tracking may not be available for this round."))
            }
        }
        .task(id: currentRound) { onLoadRound(currentRound) }
    }
}
