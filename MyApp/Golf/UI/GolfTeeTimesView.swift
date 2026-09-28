import SwiftUI

/// Grouped by round/tee time. A player starting on hole 10 is shown under
/// "TEE 10", never assumed to start on hole 1 (STEP 36/71).
struct GolfTeeTimesView: View {
    let teeTimes: GolfTeeTimes?
    let isLoading: Bool

    @State private var selectedRoundNumber: Int?

    private var selectedRound: GolfTeeTimesRound? {
        guard let teeTimes else { return nil }
        return teeTimes.rounds.first { $0.roundNumber == selectedRoundNumber } ?? teeTimes.rounds.last
    }

    private var groupedByTee: [(tee: Int, groups: [GolfTeeGroup])] {
        guard let round = selectedRound else { return [] }
        let byTee = Dictionary(grouping: round.groups) { $0.startingTee ?? 1 }
        return byTee.keys.sorted().map { tee in (tee, byTee[tee]!.sorted { ($0.teeTime ?? .distantFuture) < ($1.teeTime ?? .distantFuture) }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let teeTimes, !teeTimes.rounds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(teeTimes.rounds) { round in
                            Button {
                                selectedRoundNumber = round.roundNumber
                            } label: {
                                Text(round.roundDisplay ?? "R\(round.roundNumber)")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background((selectedRound?.roundNumber == round.roundNumber) ? Theme.accessibleAccent.opacity(0.2) : Theme.surfaceElevated, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                        }
                    }
                }

                ForEach(groupedByTee, id: \.tee) { teeSection in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TEE \(teeSection.tee)").font(.caption.bold()).foregroundStyle(Theme.textTertiary)
                        ForEach(teeSection.groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                if let teeTime = group.teeTime {
                                    Text(teeTime, style: .time).font(.subheadline.bold())
                                }
                                ForEach(group.players) { player in
                                    HStack(spacing: 8) {
                                        GolfHeadshotView(playerID: player.id, size: 24)
                                        Text(player.displayName ?? [player.firstName, player.lastName].compactMap { $0 }.joined(separator: " "))
                                            .font(.subheadline)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ContentUnavailableView("Tee Times Unavailable", systemImage: "clock")
            }
        }
    }
}
