import SwiftUI

/// Traditional scorecard shapes distinguish score types, not color alone
/// (STEP 25/90): circle = birdie, double circle = eagle or better, square =
/// bogey, double square = double bogey or worse, plain number = par.
struct GolfHoleScoreCell: View {
    let hole: GolfHoleScore

    var body: some View {
        VStack(spacing: 2) {
            Text("\(hole.holeNumber)").font(.caption2).foregroundStyle(Theme.textTertiary)
            ZStack {
                shape
                Text(hole.strokes.map(String.init) ?? "-")
                    .font(.caption.bold())
                    .foregroundStyle(color)
            }
            .frame(width: 28, height: 28)
        }
        .frame(width: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hole \(hole.holeNumber). Par \(hole.par.map(String.init) ?? "unknown"). \(hole.symbol.accessibilityLabel), \(hole.strokes.map(String.init) ?? "no score") strokes.")
    }

    @ViewBuilder private var shape: some View {
        switch hole.symbol {
        case .eagleOrBetter:
            ZStack { Circle().stroke(Theme.upcoming, lineWidth: 1.5).padding(2); Circle().stroke(Theme.upcoming, lineWidth: 1.5) }
        case .birdie:
            Circle().stroke(Theme.upcoming, lineWidth: 1.5)
        case .par:
            Color.clear
        case .bogey:
            RoundedRectangle(cornerRadius: 2).stroke(Theme.live, lineWidth: 1.5)
        case .doubleBogeyOrWorse:
            ZStack { RoundedRectangle(cornerRadius: 2).stroke(Theme.live, lineWidth: 1.5).padding(2); RoundedRectangle(cornerRadius: 2).stroke(Theme.live, lineWidth: 1.5) }
        case .unknown:
            Color.clear
        }
    }

    private var color: Color {
        switch hole.symbol {
        case .eagleOrBetter, .birdie: return Theme.upcoming
        case .bogey, .doubleBogeyOrWorse: return Theme.live
        case .par, .unknown: return Theme.textPrimary
        }
    }
}

struct GolfScorecardNineView: View {
    let title: String
    let holes: [GolfHoleScore]

    private var total: Int? {
        let strokes = holes.compactMap(\.strokes)
        return strokes.count == holes.count && !strokes.isEmpty ? strokes.reduce(0, +) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 4) {
                ForEach(holes) { hole in GolfHoleScoreCell(hole: hole) }
                VStack(spacing: 2) {
                    Text(title == "OUT" ? "OUT" : "IN").font(.caption2).foregroundStyle(Theme.textTertiary)
                    Text(total.map(String.init) ?? "-").font(.caption.bold())
                }
                .frame(width: 32)
            }
        }
    }
}

struct GolfScorecardView: View {
    let scorecard: GolfScorecard?
    let isLoading: Bool

    @State private var selectedRoundNumber: Int?

    private var selectedRound: GolfRoundScorecard? {
        guard let scorecard else { return nil }
        return scorecard.rounds.first { $0.roundNumber == selectedRoundNumber } ?? scorecard.rounds.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let scorecard, !scorecard.rounds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(scorecard.rounds) { round in
                            Button {
                                selectedRoundNumber = round.roundNumber
                            } label: {
                                Text("R\(round.roundNumber)")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background((selectedRound?.roundNumber == round.roundNumber) ? Theme.accessibleAccent.opacity(0.2) : Theme.surfaceElevated, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                        }
                    }
                }

                if let round = selectedRound {
                    if let courseName = round.courseName {
                        Text(courseName).font(.subheadline.bold())
                    }
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            if !round.frontNine.isEmpty { GolfScorecardNineView(title: "OUT", holes: round.frontNine) }
                            if !round.backNine.isEmpty { GolfScorecardNineView(title: "IN", holes: round.backNine) }
                        }
                        .padding(.vertical, 4)
                    }
                    HStack {
                        Text("TOTAL").font(.caption.bold()).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        GolfScoreText(score: round.scoreToPar, font: .title3.bold())
                        if let strokes = round.totalStrokes { Text("(\(strokes))").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ContentUnavailableView("No Scorecard", systemImage: "list.number")
            }
        }
    }
}
