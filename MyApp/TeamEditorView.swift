import SwiftUI

/// Full editor for the user's followed leagues and favorite teams: remove
/// existing favorites, follow/unfollow leagues, and open any league to star
/// new teams.
struct TeamEditorView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    favoritesSection
                    ForEach(SportGroup.allCases) { sport in
                        leagueSection(for: sport)
                    }
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
            }
            .navigationTitle("My Teams")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: Current favorites

    private var favoritesSection: some View {
        Section {
            if prefs.favoriteTeams.isEmpty {
                Text("No favorite teams yet. Open a league below to star some.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            } else {
                ForEach(prefs.favoriteTeams) { favorite in
                    HStack(spacing: 12) {
                        TeamLogo(url: favorite.logoURL, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(favorite.displayName)
                                .foregroundStyle(Theme.textPrimary)
                            if let league = League.all.first(where: { $0.path == favorite.leaguePath }) {
                                Text(league.name)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer()
                        Button {
                            remove(favorite)
                        } label: {
                            Image(systemName: "star.slash")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(favorite.displayName) from favorites")
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        } header: {
            Label("Favorite Teams", systemImage: "star.fill")
        }
    }

    // MARK: Leagues per sport

    private func leagueSection(for sport: SportGroup) -> some View {
        Section {
            ForEach(League.leagues(in: sport)) { league in
                HStack(spacing: 12) {
                    Button {
                        prefs.toggleLeague(league)
                    } label: {
                        Image(systemName: prefs.isLeagueSelected(league) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(prefs.isLeagueSelected(league) ? Theme.accent : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(prefs.isLeagueSelected(league) ? "Unfollow \(league.name)" : "Follow \(league.name)")

                    NavigationLink {
                        LeagueTeamPickerView(league: league)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(league.name)
                                .foregroundStyle(Theme.textPrimary)
                            if favoriteCount(in: league) > 0 {
                                Text("\(favoriteCount(in: league)) favorite\(favoriteCount(in: league) == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
        } header: {
            Label(sport.rawValue, systemImage: sport.systemImage)
        }
    }

    private func favoriteCount(in league: League) -> Int {
        prefs.favoriteTeams.filter { $0.leaguePath == league.path }.count
    }

    private func remove(_ favorite: FavoriteTeam) {
        guard let league = League.all.first(where: { $0.path == favorite.leaguePath }) else { return }
        let team = Team(
            id: favorite.teamID,
            displayName: favorite.displayName,
            shortDisplayName: favorite.displayName,
            abbreviation: favorite.abbreviation,
            logoURL: favorite.logoURL
        )
        prefs.toggleFavorite(team, in: league)
    }
}

// MARK: - Team picker for one league

/// Browses every team in a league (from ESPN) and stars/unstars favorites.
struct LeagueTeamPickerView: View {
    let league: League
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var teams: [Team] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private var filteredTeams: [Team] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return teams }
        return teams.filter {
            [$0.displayName, $0.shortDisplayName, $0.abbreviation]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading && teams.isEmpty {
                ProgressView().tint(Theme.accent)
            } else if teams.isEmpty {
                Text("Team list isn't available for this league.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            } else {
                List {
                    ForEach(filteredTeams) { team in
                        HStack(spacing: 12) {
                            TeamLogo(url: team.logoURL, size: 30)
                            Text(team.displayName)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button {
                                prefs.toggleFavorite(team, in: league)
                            } label: {
                                Image(systemName: prefs.isFavorite(team, in: league) ? "star.fill" : "star")
                                    .foregroundStyle(prefs.isFavorite(team, in: league) ? Theme.accent : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(prefs.isFavorite(team, in: league)
                                                ? "Remove \(team.displayName) from favorites"
                                                : "Add \(team.displayName) to favorites")
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
                .searchable(text: $searchText, prompt: "Search teams")
            }
        }
        .navigationTitle(league.name)
        .inlineNavigationTitle()
        .task {
            teams = (try? await ESPNService().teams(for: league)) ?? []
            isLoading = false
        }
    }
}
