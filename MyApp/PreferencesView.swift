import SwiftUI

/// Lets the user adjust the leagues they follow and manage favorite teams after onboarding.
struct PreferencesView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    leaguesSection
                    favoritesSection
                    onboardingSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private var leaguesSection: some View {
        ForEach(SportGroup.allCases) { sport in
            Section {
                ForEach(League.leagues(in: sport)) { league in
                    Button {
                        prefs.toggleLeague(league)
                    } label: {
                        HStack {
                            Text(league.name).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if prefs.isLeagueSelected(league) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            } header: {
                Label(sport.rawValue, systemImage: sport.systemImage)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        if !prefs.favoriteTeams.isEmpty {
            Section("Favorite Teams") {
                ForEach(prefs.favoriteTeams) { fav in
                    HStack(spacing: 12) {
                        AsyncImage(url: fav.logoURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Image(systemName: "shield.fill").foregroundStyle(Theme.textSecondary.opacity(0.5))
                            }
                        }
                        .frame(width: 28, height: 28)
                        Text(fav.displayName).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button {
                            removeFavorite(fav)
                        } label: {
                            Image(systemName: "star.slash").foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
    }

    private var onboardingSection: some View {
        Section {
            Button {
                prefs.resetOnboarding()
            } label: {
                Label("Redo Setup", systemImage: "arrow.clockwise")
                    .foregroundStyle(Theme.accent)
            }
            .listRowBackground(Theme.surface)
        } footer: {
            Text("Re-run the sport, league, and team picker.")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func removeFavorite(_ fav: FavoriteTeam) {
        // Rebuild the minimal Team/League to toggle it off.
        guard let league = League.all.first(where: { $0.path == fav.leaguePath }) else { return }
        let team = Team(id: fav.teamID, displayName: fav.displayName,
                        shortDisplayName: fav.displayName, abbreviation: fav.abbreviation,
                        logoURL: fav.logoURL)
        prefs.toggleFavorite(team, in: league)
    }
}
