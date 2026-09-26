import SwiftUI

/// Shown only when the provider actually reports a shootout in progress or
/// complete (`SoccerGameCentreSnapshot.penaltyShootout` is nil otherwise) —
/// never inferred from match status alone. Reusable across any competition that
/// can go to penalties (MLS playoffs, cups), not MLS-specific UI.
struct SoccerPenaltyShootoutView: View {
    let shootout: SoccerPenaltyShootout
    let match: SoccerMatch?

    private var homeAbbr: String { match?.side(for: shootout.homeTeamID)?.team.abbreviation ?? "HOME" }
    private var awayAbbr: String { match?.side(for: shootout.awayTeamID)?.team.abbreviation ?? "AWAY" }
    private var homeKicks: [SoccerPenaltyKick] { shootout.kicks.filter { $0.teamID == shootout.homeTeamID } }
    private var awayKicks: [SoccerPenaltyKick] { shootout.kicks.filter { $0.teamID == shootout.awayTeamID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PENALTIES").font(.caption.bold()).foregroundStyle(Theme.textSecondary)
            HStack(alignment: .top, spacing: 24) {
                column(title: homeAbbr, kicks: homeKicks, alignment: .leading)
                column(title: awayAbbr, kicks: awayKicks, alignment: .trailing)
            }
            if shootout.isComplete {
                Text(resultText).font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding()
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var resultText: String {
        if shootout.homeScore == shootout.awayScore { return "Shootout tied \(shootout.homeScore)–\(shootout.awayScore)" }
        let winner = shootout.homeScore > shootout.awayScore ? homeAbbr : awayAbbr
        return "\(winner) wins \(max(shootout.homeScore, shootout.awayScore))–\(min(shootout.homeScore, shootout.awayScore)) on penalties"
    }

    private func column(title: String, kicks: [SoccerPenaltyKick], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title).font(.subheadline.bold())
            ForEach(kicks) { kick in
                HStack(spacing: 6) {
                    if alignment == .trailing { Spacer() }
                    Image(systemName: kick.scored ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(kick.scored ? .green : .red)
                    Text(kick.playerReference.fullName).font(.caption)
                    if alignment == .leading { Spacer() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kick.playerReference.fullName), \(kick.scored ? "scored" : "missed")")
            }
        }.frame(maxWidth: .infinity)
    }
}
