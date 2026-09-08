import SwiftUI

/// Screen 2 of 3 — Pick favorite teams from selected leagues.
struct FavoriteEntitiesView: View {
    @Bindable var store: OnboardingStore

    @State private var searchText = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let catalog = SportsCatalogRepository.shared
    private var isIPad: Bool { sizeClass == .regular }

    private var sections: [(league: CatalogLeague, sport: CatalogSport, teams: [CatalogTeam])] {
        store.leaguesWithSelectableTeams
    }

    private var filteredSections: [(league: CatalogLeague, sport: CatalogSport, teams: [CatalogTeam])] {
        guard !searchText.isEmpty else { return sections }
        let q = searchText.lowercased()
        return sections.compactMap { section in
            let teams = section.teams.filter { team in
                team.name.lowercased().contains(q)
                    || (team.abbreviation?.lowercased().contains(q) ?? false)
                    || team.aliases.contains { $0.lowercased().contains(q) }
                    || section.league.name.lowercased().contains(q)
                    || section.sport.name.lowercased().contains(q)
            }
            return teams.isEmpty ? nil : (section.league, section.sport, teams)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepHeader(
                step: .favorites,
                title: "Favorite teams",
                subtitle: "Choose who you follow. We'll put their games first."
            )

            searchBar
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            teamList
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search teams", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .foregroundStyle(Theme.textPrimary)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: - Team list

    private var teamList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if filteredSections.isEmpty {
                    noResultsView
                        .padding(.top, 60)
                } else {
                    if isIPad {
                        iPadContent
                    } else {
                        phoneContent
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    private var phoneContent: some View {
        ForEach(filteredSections, id: \.league.id) { section in
            Section {
                ForEach(section.teams) { team in
                    TeamFavoriteRow(
                        team: team,
                        leagueID: section.league.id,
                        isFavorite: store.isFavorite(teamID: team.id)
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            store.toggleFavorite(teamID: team.id)
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    Divider().background(Theme.hairline).padding(.leading, 56)
                }
            } header: {
                LeagueSectionHeader(
                    league: section.league,
                    sport: section.sport,
                    selectedCount: section.teams.filter { store.isFavorite(teamID: $0.id) }.count
                )
            }
        }
    }

    @ViewBuilder
    private var iPadContent: some View {
        ForEach(filteredSections, id: \.league.id) { section in
            Section {
                let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(section.teams) { team in
                        TeamFavoriteRow(
                            team: team,
                            leagueID: section.league.id,
                            isFavorite: store.isFavorite(teamID: team.id)
                        ) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                store.toggleFavorite(teamID: team.id)
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                }
            } header: {
                LeagueSectionHeader(
                    league: section.league,
                    sport: section.sport,
                    selectedCount: section.teams.filter { store.isFavorite(teamID: $0.id) }.count
                )
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("No results for \"\(searchText)\"")
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - League section header

private struct LeagueSectionHeader: View {
    let league: CatalogLeague
    let sport: CatalogSport
    let selectedCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(league.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(sport.name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 10)
        .background(Theme.background)
    }
}

// MARK: - Team favorite row

private struct TeamFavoriteRow: View {
    let team: CatalogTeam
    let leagueID: String
    let isFavorite: Bool
    let onToggle: () -> Void

    private let catalog = SportsCatalogRepository.shared

    private var logoURL: URL? {
        catalog.logoURL(for: team, leagueID: leagueID)
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Team logo
                TeamLogo(url: logoURL, size: 36)
                    .accessibilityHidden(true)

                // Name + abbreviation
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let abbr = team.abbreviation {
                        Text(abbr)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()

                // Favorite indicator
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundStyle(isFavorite ? Theme.accent : Theme.textSecondary.opacity(0.5))
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isFavorite)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite
            ? "Remove \(team.name) from favorites"
            : "Add \(team.name) to favorites")
        .accessibilityAddTraits(isFavorite ? [.isSelected] : [])
    }
}
