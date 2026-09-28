import SwiftUI

/// Player Tournament Detail (STEP 22): header + Scorecard/Shots. Deep
/// player-profile enrichment (career/bio) is intentionally not fetched here
/// (STEP 84/50) — only tournament-scoped data loads when a golfer is tapped.
struct GolfPlayerTournamentView: View {
    let entry: GolfLeaderboardEntry
    let leaguePath: String
    var service: PGATournamentCentreService

    @EnvironmentObject private var prefs: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .scorecard

    private enum Tab: String, CaseIterable, Identifiable {
        case scorecard = "Scorecard"
        case shots = "Shots"
        var id: String { rawValue }
    }

    private var isFavorite: Bool { prefs.isFavorite(playerID: entry.player.id, leaguePath: leaguePath) }

    private var currentRoundNumber: Int {
        entry.currentRound ?? service.selectedPlayerScorecard?.rounds.last?.roundNumber ?? 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
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
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(entry.player.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        prefs.toggleFavorite(playerID: entry.player.id, leaguePath: leaguePath, displayName: entry.player.displayName, country: entry.player.country)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                    }
                    .accessibilityLabel(isFavorite ? "Unfollow \(entry.player.displayName)" : "Follow \(entry.player.displayName)")
                }
            }
        }
        .task { service.selectPlayer(entry.player.id) }
        .onDisappear { service.deselectPlayer() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                GolfHeadshotView(playerID: entry.player.id, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.player.displayName).font(.title2.bold())
                    if let country = entry.player.country { Text(country).font(.caption).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
            }
            HStack(spacing: 24) {
                statColumn("Position", entry.positionDisplay ?? "-")
                statColumn("Total", entry.total.display)
                if entry.playerState.isScoring {
                    statColumn("Round", entry.currentRoundScore.display)
                    statColumn("Thru", entry.thruDisplay ?? "-")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.textTertiary)
            Text(value).font(.headline)
        }
    }
}
