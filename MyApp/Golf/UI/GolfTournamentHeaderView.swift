import SwiftUI

/// The Tournament Centre header. Deliberately not a two-team scoreboard
/// (STEP 60) — tournament identity is primary, round/status is secondary,
/// the current leader is contextual.
struct GolfTournamentHeaderView: View {
    let tournament: GolfTournament?
    let leader: GolfLeaderboardEntry?
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tournament?.name ?? "Loading…")
                    .font(.title2.bold())
                    .lineLimit(2)
                Spacer()
                if let tournament {
                    statusBadge(for: tournament.status)
                }
            }

            if let course = tournament?.hostCourse {
                Label(course.name, systemImage: "flag.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let location = [tournament?.city, tournament?.state, tournament?.country].compactMap({ $0 }).joined(separator: ", ").nilIfEmpty {
                Text(location).font(.caption).foregroundStyle(Theme.textTertiary)
            }

            if let weather = tournament?.weather?.current {
                HStack(spacing: 12) {
                    if let temp = weather.tempF { Label("\(Int(temp))°F", systemImage: "thermometer.medium").font(.caption) }
                    if let wind = weather.windSpeedMPH { Label("Wind \(Int(wind)) mph", systemImage: "wind").font(.caption) }
                    if let condition = weather.condition { Text(condition).font(.caption) }
                }
                .foregroundStyle(Theme.textSecondary)
            }

            if let leader {
                Divider().overlay(Theme.hairline).padding(.vertical, 4)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LEADER").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
                        Text(leader.player.displayName).font(.headline)
                        if let thru = leader.thruDisplay {
                            Text("Thru \(thru) • Today \(leader.currentRoundScore.display)")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    GolfScoreText(score: leader.total, font: .title3.bold())
                }
            }

            if isStale {
                Label("Live data delayed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.starting)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func statusBadge(for status: GolfTournamentStatus) -> some View {
        Text(status.displayLabel.uppercased())
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status.isLive ? Theme.live.opacity(0.2) : Theme.surfaceElevated, in: Capsule())
            .foregroundStyle(status.isLive ? Theme.live : Theme.textSecondary)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
