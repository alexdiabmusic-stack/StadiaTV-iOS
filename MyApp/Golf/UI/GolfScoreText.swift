import SwiftUI

/// Renders a `GolfScore` with color as a secondary cue only — the sign/"E"
/// text is always present so color-blind and grayscale users get the same
/// information (STEP 65/90).
struct GolfScoreText: View {
    let score: GolfScore
    var font: Font = .body.bold()

    var body: some View {
        Text(score.display)
            .font(font)
            .foregroundStyle(color)
            .accessibilityLabel(score.accessibilityLabel)
    }

    private var color: Color {
        switch score {
        case .underPar: return Theme.upcoming
        case .overPar: return Theme.live
        case .even: return Theme.textPrimary
        case .unknown: return Theme.textSecondary
        }
    }
}

struct GolfPlayerStateBadge: View {
    let state: GolfPlayerState

    var body: some View {
        if let label = state.shortLabel {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(state.accessibilityLabel)
        }
    }
}

struct GolfMovementIndicator: View {
    let movement: GolfLeaderboardMovement?

    var body: some View {
        switch movement?.direction {
        case .up:
            Label(movement?.amount.map(String.init) ?? "", systemImage: "arrow.up")
                .labelStyle(.titleAndIcon)
                .font(.caption2.bold())
                .foregroundStyle(Theme.upcoming)
                .accessibilityLabel("moved up\(movement?.amount.map { " \($0) spots" } ?? "")")
        case .down:
            Label(movement?.amount.map(String.init) ?? "", systemImage: "arrow.down")
                .labelStyle(.titleAndIcon)
                .font(.caption2.bold())
                .foregroundStyle(Theme.live)
                .accessibilityLabel("moved down\(movement?.amount.map { " \($0) spots" } ?? "")")
        default:
            EmptyView()
        }
    }
}
