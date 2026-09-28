import SwiftUI

struct GolfHoleRow: View {
    let hole: GolfHole
    var onSelect: () -> Void = {}

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text("\(hole.number)").font(.subheadline.bold().monospacedDigit()).frame(width: 28, alignment: .leading)
                Text(hole.par.map { "Par \($0)" } ?? "-").font(.subheadline).frame(width: 64, alignment: .leading)
                Text(hole.yardage.map { "\($0) yds" } ?? "-").font(.subheadline).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
                Spacer()
                if let avg = hole.scoringAverage {
                    Text(String(format: "%.2f", avg)).font(.subheadline.monospacedDigit())
                }
                if let rank = hole.rank {
                    Text("#\(rank)").font(.caption.bold()).foregroundStyle(Theme.textTertiary).frame(width: 36, alignment: .trailing)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hole \(hole.number). Par \(hole.par.map(String.init) ?? "unknown"). \(hole.yardage.map { "\($0) yards." } ?? "")\(hole.scoringAverage.map { String(format: " Scoring average %.2f.", $0) } ?? "")\(hole.rank.map { " Difficulty rank \($0)." } ?? "")")
    }
}

struct GolfCourseView: View {
    let course: GolfCourse?
    var onSelectHole: (GolfHole) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let course {
                VStack(alignment: .leading, spacing: 4) {
                    Text(course.name).font(.title3.bold())
                    HStack(spacing: 12) {
                        if let par = course.par { Text("Par \(par)").font(.subheadline).foregroundStyle(Theme.textSecondary) }
                        if let yardage = course.yardage { Text("\(yardage) yards").font(.subheadline).foregroundStyle(Theme.textSecondary) }
                    }
                }
                .padding(.horizontal, 4)

                if course.holes.isEmpty {
                    ContentUnavailableView("Hole Stats Unavailable", systemImage: "flag.slash")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(course.holes) { hole in
                            GolfHoleRow(hole: hole) { onSelectHole(hole) }
                            if hole.id != course.holes.last?.id { Divider().overlay(Theme.hairline) }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
    }
}
