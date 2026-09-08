import SwiftUI

/// Screen 1 of 3 — Sports + inline league expansion on one screen.
struct SportsSelectionView: View {
    @Bindable var store: OnboardingStore
    let onSportDeselect: (CatalogSport) -> Void

    @State private var expandedSportIDs: Set<String> = []
    @State private var showingAllLeagues: Set<String> = []
    @State private var leagueSearch: [String: String] = [:]  // sportID → search text

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isIPad: Bool { sizeClass == .regular }

    private let catalog = SportsCatalogRepository.shared

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepHeader(
                step: .sports,
                title: "Your sports",
                subtitle: "Choose the sports and competitions you follow."
            )

            ScrollView {
                VStack(spacing: 12) {
                    sportGrid
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Sport grid

    private var sportGrid: some View {
        let columns: [GridItem] = isIPad
            ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(catalog.sports) { sport in
                VStack(spacing: 0) {
                    SportCard(
                        sport: sport,
                        isSelected: store.isSportSelected(sport),
                        onTap: { handleSportTap(sport) }
                    )

                    if store.isSportSelected(sport) && expandedSportIDs.contains(sport.id) {
                        LeagueExpansion(
                            sport: sport,
                            store: store,
                            showingAll: showingAllLeagues.contains(sport.id),
                            searchText: leagueSearch[sport.id] ?? "",
                            onToggleAll: { toggleShowAll(sport) },
                            onSearchChange: { text in leagueSearch[sport.id] = text }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handleSportTap(_ sport: CatalogSport) {
        if store.isSportSelected(sport) {
            if catalog.leagues(for: sport).isEmpty {
                store.deselectSport(sport)
            } else {
                onSportDeselect(sport)
            }
        } else {
            store.selectSport(sport)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                _ = expandedSportIDs.insert(sport.id)
            }
        }
        let impactGenerator = UIImpactFeedbackGenerator(style: .light)
        impactGenerator.impactOccurred()
    }

    private func toggleShowAll(_ sport: CatalogSport) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showingAllLeagues.contains(sport.id) {
                showingAllLeagues.remove(sport.id)
            } else {
                showingAllLeagues.insert(sport.id)
            }
        }
    }
}

// MARK: - Sport card

private struct SportCard: View {
    let sport: CatalogSport
    let isSelected: Bool
    let onTap: () -> Void

    private var group: SportGroup? { SportsCatalogRepository.shared.sportGroup(for: sport.id) }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.accent.opacity(0.18) : Theme.surfaceElevated)
                        .frame(width: 52, height: 52)
                    Image(systemName: group?.systemImage ?? "sportscourt.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                }
                Text(sport.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.08) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.accent.opacity(0.6) : Theme.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sport.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - League expansion panel

private struct LeagueExpansion: View {
    let sport: CatalogSport
    @Bindable var store: OnboardingStore
    let showingAll: Bool
    let searchText: String
    let onToggleAll: () -> Void
    let onSearchChange: (String) -> Void

    private let maxInitial = 7
    private let catalog = SportsCatalogRepository.shared

    private var allLeagues: [CatalogLeague] { catalog.leagues(for: sport) }

    private var displayedLeagues: [CatalogLeague] {
        let filtered = searchText.isEmpty ? allLeagues : allLeagues.filter { league in
            let q = searchText.lowercased()
            return league.name.lowercased().contains(q)
                || (league.abbreviation?.lowercased().contains(q) ?? false)
                || league.aliases.contains { $0.lowercased().contains(q) }
                || (league.country?.lowercased().contains(q) ?? false)
                || (league.region?.lowercased().contains(q) ?? false)
        }
        return showingAll || !searchText.isEmpty ? filtered : Array(filtered.prefix(maxInitial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search field for large league lists
            if allLeagues.count > maxInitial {
                LeagueSearchField(text: Binding(
                    get: { searchText },
                    set: { onSearchChange($0) }
                ))
                .padding(.top, 8)
            }

            // League chips
            FlowLayout(spacing: 8) {
                ForEach(displayedLeagues) { league in
                    LeagueChip(league: league,
                               isSelected: store.isLeagueSelected(league)) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            store.toggleLeague(league, inSport: sport)
                        }
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                    }
                }
            }

            // Show more / show less
            if allLeagues.count > maxInitial && searchText.isEmpty {
                Button {
                    onToggleAll()
                } label: {
                    Text(showingAll ? "Show fewer" : "Show all \(allLeagues.count) competitions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 6)
    }
}

// MARK: - League chip

private struct LeagueChip: View {
    let league: CatalogLeague
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(league.abbreviation ?? league.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Theme.accent : Theme.surface,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(league.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - League search field

private struct LeagueSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .font(.caption)
            TextField("Search competitions", text: $text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
