import SwiftUI

/// Leaderboard-left / selected-golfer-right split (STEP 87 iPad, STEP 88
/// tvOS). Selecting a row updates the right panel in place — no full-screen
/// navigation push, so browsing the board and the selected golfer's detail
/// can happen side by side.
struct GolfLeaderboardSplitView: View {
    let entries: [GolfLeaderboardEntry]
    let leaguePath: String
    var service: PGATournamentCentreService

    @State private var selectedID: String?
    @EnvironmentObject private var prefs: PreferencesStore

    private var selectedEntry: GolfLeaderboardEntry? {
        entries.first { $0.id == selectedID } ?? entries.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        GolfLeaderboardRow(
                            entry: entry,
                            isFavorite: prefs.favoritePlayerIDs(leaguePath: leaguePath).contains(entry.player.id)
                        ) {
                            selectedID = entry.id
                        }
                        .background(selectedID == entry.id ? Theme.surfaceElevated : .clear)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 420, maxWidth: 460)

            Divider().overlay(Theme.hairline)

            if let selectedEntry {
                GolfPlayerDetailPanel(entry: selectedEntry, leaguePath: leaguePath, service: service)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a Golfer", systemImage: "figure.golf")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selectedID == nil { selectedID = entries.first?.id } }
    }
}
