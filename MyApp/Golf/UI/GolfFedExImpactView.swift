import SwiftUI

/// FedExCup projection for a followed golfer. Kept visually and semantically
/// separate from tournament leaderboard position (STEP 57-58) — this is a
/// *season points race* standing, not this week's score.
struct GolfFedExImpactView: View {
    let standing: GolfCupStanding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FEDEXCUP")
                .font(.caption2.bold())
                .foregroundStyle(Theme.textTertiary)
            Text(standing.displayName).font(.headline)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current").font(.caption2).foregroundStyle(Theme.textSecondary)
                    Text(standing.officialRankDisplay ?? "-").font(.title3.bold())
                }
                if standing.hasProjection {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Projected").font(.caption2).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 4) {
                            Text(standing.projectedRankDisplay ?? "-").font(.title3.bold())
                            movementBadge
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    @ViewBuilder
    private var movementBadge: some View {
        switch standing.movementRaw?.uppercased() {
        case "UP":
            Label(standing.movementAmountDisplay ?? "", systemImage: "arrow.up").font(.caption.bold()).foregroundStyle(Theme.upcoming)
        case "DOWN":
            Label(standing.movementAmountDisplay ?? "", systemImage: "arrow.down").font(.caption.bold()).foregroundStyle(Theme.live)
        default:
            EmptyView()
        }
    }
}
