import SwiftUI

/// One dense leaderboard row. Golf fields can run 100+ players, so this is a
/// compact list row, not a card (STEP 19).
struct GolfLeaderboardRow: View {
    let entry: GolfLeaderboardEntry
    let isFavorite: Bool
    var onSelect: () -> Void = {}

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Text(entry.positionDisplay ?? "-")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, alignment: .leading)

                GolfHeadshotView(playerID: entry.player.id, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if isFavorite {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.starting)
                        }
                        Text(entry.player.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    if let country = entry.player.country {
                        Text(country).font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }

                Spacer(minLength: 8)

                if entry.playerState.isScoring {
                    VStack(alignment: .trailing, spacing: 2) {
                        GolfScoreText(score: entry.currentRoundScore, font: .caption.bold())
                        GolfMovementIndicator(movement: entry.movement)
                    }
                    .frame(width: 48, alignment: .trailing)

                    Text(entry.thruDisplay?.isEmpty == false ? entry.thruDisplay! : "-")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, alignment: .trailing)

                    GolfScoreText(score: entry.total)
                        .frame(width: 44, alignment: .trailing)
                } else if entry.playerState == .notStarted, let teeTime = entry.teeTime {
                    Text(teeTime, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    GolfPlayerStateBadge(state: entry.playerState)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let position = entry.positionDisplay {
            parts.append(entry.isTied ? "Tied for \(position.dropFirst())" : "Position \(position)")
        }
        parts.append(entry.player.displayName)
        if entry.playerState.isScoring {
            parts.append("\(entry.total.accessibilityLabel) total")
            parts.append("\(entry.currentRoundScore.accessibilityLabel) today")
            if let thru = entry.thruDisplay { parts.append("through \(thru)") }
        } else {
            parts.append(entry.playerState.accessibilityLabel)
        }
        return parts.joined(separator: ", ")
    }
}
