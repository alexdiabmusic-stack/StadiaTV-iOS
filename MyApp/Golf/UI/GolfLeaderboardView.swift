import SwiftUI

enum GolfLeaderboardFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case following = "Following"
    case onCourse = "On Course"
    case finished = "Finished"
    case notStarted = "Not Started"
    var id: String { rawValue }
}

/// The Tournament Centre's primary live view. Filters are purely local —
/// switching a filter never re-fetches (STEP 21); only the shared leaderboard
/// array (kept live by `PGATournamentCentreService`) changes.
struct GolfLeaderboardView: View {
    let entries: [GolfLeaderboardEntry]
    let leaguePath: String
    var onSelect: (GolfLeaderboardEntry) -> Void = { _ in }

    @EnvironmentObject private var prefs: PreferencesStore
    @State private var filter: GolfLeaderboardFilter = .all

    private var favoriteIDs: Set<String> { prefs.favoritePlayerIDs(leaguePath: leaguePath) }

    private var filtered: [GolfLeaderboardEntry] {
        switch filter {
        case .all: return entries
        case .following: return entries.filter { favoriteIDs.contains($0.player.id) }
        case .onCourse: return entries.filter { $0.playerState == .active }
        case .finished: return entries.filter { $0.playerState == .finished }
        case .notStarted: return entries.filter { $0.playerState == .notStarted }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GolfLeaderboardFilter.allCases) { option in
                        let count = option == .following ? favoriteIDs.count : nil
                        Button {
                            filter = option
                        } label: {
                            HStack(spacing: 4) {
                                Text(option.rawValue)
                                if let count, count > 0 { Text("\(count)").font(.caption2.bold()) }
                            }
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(filter == option ? Theme.accessibleAccent.opacity(0.2) : Theme.surfaceElevated, in: Capsule())
                            .foregroundStyle(filter == option ? Theme.accessibleAccent : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            if filter == .following && filtered.isEmpty {
                ContentUnavailableView("No Followed Golfers", systemImage: "star", description: Text("Follow a golfer from the leaderboard to see them here."))
                    .padding(.top, 32)
            } else if filtered.isEmpty {
                ContentUnavailableView("No Players", systemImage: "figure.golf")
                    .padding(.top, 32)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        GolfLeaderboardRow(entry: entry, isFavorite: favoriteIDs.contains(entry.player.id)) {
                            onSelect(entry)
                        }
                        Divider().overlay(Theme.hairline)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }
}
