import SwiftUI

/// Inline (non-sheet) player detail used by the iPad split leaderboard and
/// the tvOS leaderboard-left/detail-right layout (STEP 87-88) — the same
/// Scorecard/Shots content as `GolfPlayerTournamentView`, without navigation
/// chrome, since it lives permanently in a side panel instead of being
/// presented modally.
struct GolfPlayerDetailPanel: View {
    let entry: GolfLeaderboardEntry
    let leaguePath: String
    var service: PGATournamentCentreService

    @EnvironmentObject private var prefs: PreferencesStore
    @State private var tab: Tab = .scorecard

    private enum Tab: String, CaseIterable, Identifiable {
        case scorecard = "Scorecard"
        case shots = "Shots"
        var id: String { rawValue }
    }

    private var isFavorite: Bool { prefs.isFavorite(playerID: entry.player.id, leaguePath: leaguePath) }
    private var currentRoundNumber: Int { entry.currentRound ?? service.selectedPlayerScorecard?.rounds.last?.roundNumber ?? 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    GolfHeadshotView(playerID: entry.player.id, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.player.displayName).font(.title2.bold())
                        Text("\(entry.positionDisplay ?? "-") • \(entry.total.display) • Thru \(entry.thruDisplay ?? "-")")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        prefs.toggleFavorite(playerID: entry.player.id, leaguePath: leaguePath, displayName: entry.player.displayName, country: entry.player.country)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                    }
                    .accessibilityLabel(isFavorite ? "Unfollow \(entry.player.displayName)" : "Follow \(entry.player.displayName)")
                }

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .scorecard:
                    GolfScorecardView(scorecard: service.selectedPlayerScorecard, isLoading: service.isLoadingSelectedPlayer)
                case .shots:
                    GolfShotTimelineView(
                        shotRound: service.selectedPlayerShotsByRound[currentRoundNumber],
                        isLoading: service.isLoadingSelectedPlayer,
                        onLoadRound: { service.loadShots(round: $0) },
                        currentRound: currentRoundNumber
                    )
                }
            }
            .padding(20)
        }
        .task(id: entry.player.id) { service.selectPlayer(entry.player.id) }
    }
}
