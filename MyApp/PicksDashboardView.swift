import SwiftUI

// MARK: - Picks Dashboard

struct PicksDashboardView: View {
    @EnvironmentObject private var predictions: PredictionsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPickPrediction: Prediction?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        heroStats
                        secondaryStats
                        picksHistory
                    }
                    .padding(16)
                }
            }
            .navigationTitle("My Picks")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $selectedPickPrediction) { prediction in
                PickMatchDetailSheet(prediction: prediction)
            }
        }
        .tint(Theme.accent)
        .task {
            await predictions.resolveStaleIfNeeded()
        }
    }

    // MARK: Hero stats card

    private var heroStats: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Total Points")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("\(predictions.totalPoints)")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .monospacedDigit()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text("Current Streak")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if predictions.currentStreak >= 2 {
                        Text("🔥")
                            .font(.title2)
                    }
                    Text("\(predictions.currentStreak)")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(predictions.currentStreak >= 3 ? Color(hex: 0xFF6B35) : Theme.textPrimary)
                        .monospacedDigit()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: Secondary stat grid

    private var secondaryStats: some View {
        let weekly = predictions.weeklyRecord
        let accuracy = predictions.resolvedCount > 0
            ? "\(Int((predictions.winRate ?? 0) * 100))%"
            : "—"

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                statCell(label: "Correct", value: "\(predictions.correctCount)")
                statCell(label: "Total Picks", value: "\(predictions.resolvedCount)")
                statCell(label: "Best Streak", value: "\(predictions.bestStreak)")
            }
            HStack(spacing: 10) {
                statCell(label: "This Week", value: "\(weekly.correct)/\(weekly.total)")
                statCell(label: "Accuracy", value: accuracy)
                statCell(label: "Pending", value: "\(predictions.pendingCount)")
            }
        }
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: Full picks list

    @ViewBuilder private var picksHistory: some View {
        let sorted = predictions.predictions.sorted { $0.placedAt > $1.placedAt }
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("All Picks")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 12)

                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, prediction in
                    PickHistoryRow(prediction: prediction)
                        .onTapGesture { selectedPickPrediction = prediction }
                    if index < sorted.count - 1 {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "trophy")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.textSecondary)
                Text("No picks yet. Make your first prediction on any upcoming match.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

// MARK: - Pick history row

private struct PickHistoryRow: View {
    let prediction: Prediction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.body.weight(.bold))
                .foregroundStyle(statusColor)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(prediction.awayTeamName) vs \(prediction.homeTeamName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(prediction.leagueName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Text(prediction.pick.label(away: prediction.awayTeamName, home: prediction.homeTeamName))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let pts = prediction.pointsEarned {
                    if pts > 0 {
                        Text("+\(pts) pts")
                            .font(.footnote.weight(.heavy))
                            .foregroundStyle(Color(hex: 0x3DBE6B))
                    } else {
                        Text("0 pts")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("Pending")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let streak = prediction.streakAtTime, streak >= 2 {
                    Text("🔥 \(streak)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(hex: 0xFF6B35))
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
        }
        .padding(.vertical, 10)
    }

    private var statusIcon: String {
        switch prediction.isCorrect {
        case true: return "checkmark.circle.fill"
        case false: return "xmark.circle.fill"
        case nil: return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch prediction.isCorrect {
        case true: return Color(hex: 0x3DBE6B)
        case false: return Theme.live
        case nil: return Theme.textSecondary
        }
    }
}
