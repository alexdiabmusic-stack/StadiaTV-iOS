import SwiftUI

/// Overview tab: a curated summary, not a duplicate of the full leaderboard
/// (STEP 61-63).
struct GolfOverviewView: View {
    let tournament: GolfTournament?
    let leaderboard: [GolfLeaderboardEntry]
    let fedExStandings: [GolfCupStanding]
    let leaguePath: String
    var onSelect: (GolfLeaderboardEntry) -> Void = { _ in }
    var onShowFullLeaderboard: () -> Void = {}

    @EnvironmentObject private var prefs: PreferencesStore

    private var topLeaders: [GolfLeaderboardEntry] { Array(leaderboard.prefix(5)) }

    private var followedEntry: GolfLeaderboardEntry? {
        let favorites = prefs.favoritePlayerIDs(leaguePath: leaguePath)
        guard !favorites.isEmpty else { return nil }
        return leaderboard.first { favorites.contains($0.player.id) }
    }

    private var followedFedEx: GolfCupStanding? {
        guard let followedEntry else { return nil }
        return fedExStandings.first { $0.playerID == followedEntry.player.id }
    }

    private var hardestHole: GolfHole? {
        tournament?.hostCourse?.holes.compactMap { $0 }.max { ($0.rank ?? .max) > ($1.rank ?? .max) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let followedEntry {
                followingSnapshot(followedEntry)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("LEADERS").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
                VStack(spacing: 0) {
                    ForEach(topLeaders) { entry in
                        GolfLeaderboardRow(entry: entry, isFavorite: prefs.favoritePlayerIDs(leaguePath: leaguePath).contains(entry.player.id)) {
                            onSelect(entry)
                        }
                        if entry.id != topLeaders.last?.id { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))

                Button("View Full Leaderboard", action: onShowFullLeaderboard)
                    .font(.subheadline.bold())
                    .frame(minHeight: 44)
            }

            if let followedFedEx {
                GolfFedExImpactView(standing: followedFedEx)
            }

            if let hardestHole, let course = tournament?.hostCourse {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TOUGHEST HOLE").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hole \(hardestHole.number) • \(course.name)").font(.headline)
                            if let avg = hardestHole.scoringAverage {
                                Text(String(format: "Scoring avg %.2f", avg)).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer()
                        if let rank = hardestHole.rank { Text("#\(rank) hardest").font(.caption.bold()).foregroundStyle(Theme.live) }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                }
            }
        }
    }

    @ViewBuilder
    private func followingSnapshot(_ entry: GolfLeaderboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FOLLOWING").font(.caption2.bold()).foregroundStyle(Theme.textTertiary)
            Button { onSelect(entry) } label: {
                HStack {
                    GolfHeadshotView(playerID: entry.player.id, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.player.displayName).font(.headline)
                        Text("\(entry.positionDisplay ?? "-") • \(entry.total.display)")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        if entry.playerState.isScoring {
                            Text("Today \(entry.currentRoundScore.display) • Thru \(entry.thruDisplay ?? "-")")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
    }
}
