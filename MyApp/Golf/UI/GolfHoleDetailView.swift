import SwiftUI

/// Difficulty is only ever shown as actual scoring average (STEP 42) — never
/// inferred from yardage alone.
struct GolfHoleDetailView: View {
    let hole: GolfHole

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("HOLE \(hole.number)").font(.title2.bold())
                Spacer()
                if let rank = hole.rank { Text(Self.ordinal(rank) + " hardest").font(.subheadline.bold()).foregroundStyle(Theme.live) }
            }
            HStack(spacing: 16) {
                if let par = hole.par { Label("Par \(par)", systemImage: "flag.fill") }
                if let yardage = hole.yardage { Label("\(yardage) yds", systemImage: "ruler") }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)

            if let avg = hole.scoringAverage {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SCORING AVERAGE").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
                    HStack {
                        Text(String(format: "%.2f", avg)).font(.title.bold())
                        GolfScoreText(score: hole.scoringAverageToPar, font: .headline)
                    }
                    if let par = hole.par {
                        GeometryReader { geometry in
                            let ratio = min(1, max(0, (avg - Double(par) + 1) / 2))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.surfaceElevated)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(avg > Double(par) ? Theme.live : Theme.upcoming)
                                        .frame(width: geometry.size.width * ratio)
                                }
                        }
                        .frame(height: 8)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("TODAY").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 16) {
                    statColumn("Eagles", hole.eagles)
                    statColumn("Birdies", hole.birdies)
                    statColumn("Pars", hole.pars)
                    statColumn("Bogeys", hole.bogeys)
                    statColumn("Double+", hole.doubleBogeyOrWorse)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private func statColumn(_ label: String, _ value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "-").font(.headline)
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 100, value % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }
}
