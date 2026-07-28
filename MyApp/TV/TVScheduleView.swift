#if os(tvOS)
import SwiftUI

struct TVScheduleView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @StateObject private var viewModel = MatchesViewModel()
    @State private var favoritesOnly = false

    private var leagues: [League] {
        prefs.followedLeagues.isEmpty ? Array(League.all.prefix(12)) : prefs.followedLeagues
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    leaguePicker
                    Divider().background(Theme.hairline)
                    matchContent
                }
            }
            .navigationTitle("Schedule")
            .navigationDestination(for: Match.self) { TVMatchDetailView(match: $0) }
        }
        .tint(Theme.accent)
        .task {
            syncSelectedLeague()
            await viewModel.load()
        }
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
        .onChange(of: prefs.followedLeagues) { syncSelectedLeague() }
    }

    private func syncSelectedLeague() {
        if let first = leagues.first, !leagues.contains(viewModel.selectedLeague) {
            viewModel.selectLeague(first)
        }
    }

    // MARK: - League Picker

    private var leaguePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(leagues) { league in
                    Button {
                        viewModel.selectLeague(league)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: league.group.systemImage)
                                .font(.caption.weight(.bold))
                            Text(league.shortName)
                                .font(.subheadline.weight(.bold))
                        }
                        .foregroundStyle(viewModel.selectedLeague == league ? .white : Theme.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            viewModel.selectedLeague == league ? Theme.accent : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(viewModel.selectedLeague == league ? Theme.accent : Theme.hairline)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
        .background(Theme.background)
    }

    // MARK: - Match Content

    @ViewBuilder private var matchContent: some View {
        if viewModel.isLoading && viewModel.matches.isEmpty {
            ProgressView().tint(Theme.accent).scaleEffect(2).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.matches.isEmpty {
            TVEmptyState(systemImage: "calendar", title: "No Games Today", subtitle: "Check back later or follow different leagues.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 44) {
                    // Live matches as a shelf
                    if !viewModel.liveMatches.isEmpty {
                        TVShelfRow(title: "Live Now", systemImage: "dot.radiowaves.left.and.right", tint: Theme.live) {
                            ForEach(viewModel.liveMatches) { match in
                                NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                            }
                        }
                    }

                    // Upcoming shelf
                    if !viewModel.upcomingMatches.isEmpty {
                        TVShelfRow(title: "Upcoming", systemImage: "clock", tint: Color(hex: 0x3DBE6B)) {
                            ForEach(viewModel.upcomingMatches) { match in
                                NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                            }
                        }
                    }

                    // Final results shelf
                    if !viewModel.finishedMatches.isEmpty {
                        TVShelfRow(title: "Results", systemImage: "flag.checkered", tint: Theme.textSecondary) {
                            ForEach(viewModel.finishedMatches) { match in
                                NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                            }
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
            }
        }
    }
}
#endif
