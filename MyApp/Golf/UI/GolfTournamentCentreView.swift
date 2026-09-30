import SwiftUI

/// The PGA Golf Tournament Centre — purpose-built around
/// TOURNAMENT → LEADERBOARD → PLAYER → ROUND → HOLE → SHOT, not the app's
/// generic home/away scoreboard (STEP 59-60). iPhone top-level tabs are
/// Overview / Leaderboard / Course / Tee Times; Following is a Leaderboard
/// filter rather than its own tab (STEP 59).
struct GolfTournamentCentreView<WatchContent: View, RelatedContent: View>: View {
    let match: Match
    @ViewBuilder var watchContent: () -> WatchContent
    @ViewBuilder var relatedContent: () -> RelatedContent

    @State private var service = PGATournamentCentreService()
    @State private var tab: Tab = .overview
    @State private var selectedEntry: GolfLeaderboardEntry?

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case leaderboard = "Leaderboard"
        case course = "Course"
        case teeTimes = "Tee Times"
        var id: String { rawValue }
    }

    private var tournamentID: GolfTournamentID { GolfTournamentID(rawValue: match.id) }

    private var usesSplitLeaderboardLayout: Bool {
        #if os(tvOS)
        true
        #else
        Theme.isPad
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GolfTournamentHeaderView(tournament: service.tournament, leader: service.leaderboard.first, isStale: service.isLeaderboardStale)

                if let error = service.tournamentError, service.tournament == nil {
                    Text(error).font(.caption).foregroundStyle(Theme.textSecondary)
                }

                watchContent()

                tabPicker

                Group {
                    switch tab {
                    case .overview:
                        GolfOverviewView(
                            tournament: service.tournament,
                            leaderboard: service.leaderboard,
                            fedExStandings: service.fedExStandings,
                            leaguePath: match.league.path,
                            onSelect: { selectedEntry = $0 },
                            onShowFullLeaderboard: { tab = .leaderboard }
                        )
                    case .leaderboard:
                        if let error = service.leaderboardError, service.leaderboard.isEmpty {
                            ContentUnavailableView("Leaderboard Unavailable", systemImage: "list.bullet", description: Text(error))
                        } else if usesSplitLeaderboardLayout {
                            // iPad/tvOS: leaderboard left, selected golfer right (STEP 87-88) —
                            // no sheet, the panel updates in place.
                            GolfLeaderboardSplitView(entries: service.leaderboard, leaguePath: match.league.path, service: service)
                                .frame(minHeight: 520)
                        } else {
                            GolfLeaderboardView(entries: service.leaderboard, leaguePath: match.league.path) { selectedEntry = $0 }
                        }
                    case .course:
                        GolfCourseView(course: service.tournament?.hostCourse)
                    case .teeTimes:
                        GolfTeeTimesView(teeTimes: service.teeTimes, isLoading: service.teeTimes == nil && service.teeTimesError == nil)
                    }
                }

                relatedContent()
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: match.id) {
            service.open(tournamentID: tournamentID)
        }
        .onDisappear { service.close() }
        .sheet(item: $selectedEntry) { entry in
            GolfPlayerTournamentView(entry: entry, leaguePath: match.league.path, service: service)
        }
    }

    private var tabPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(tab == item ? Theme.surfaceElevated : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .overlay(alignment: .bottom) { if tab == item { Capsule().fill(Theme.accessibleAccent).frame(height: 3) } }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
        }
    }
}
