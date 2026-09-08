import SwiftUI

/// Screen 1 of 3 — Sports + inline league expansion on one screen.
/// Sports are laid out in N-column rows; selecting a sport appends its full-width
/// league drawer directly below the row it belongs to.
struct SportsSelectionView: View {
    @Bindable var store: OnboardingStore
    let onSportDeselect: (CatalogSport) -> Void

    @State private var expandedSportIDs: Set<String> = []
    @State private var showingAllLeagues: Set<String> = []
    @State private var leagueSearch: [String: String] = [:]

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var colCount: Int { sizeClass == .regular ? 4 : 2 }

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
                sportGrid
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Sport grid (row-based)

    private var sportGrid: some View {
        let sports = catalog.sports
        let cols = colCount
        let rowStarts = Array(stride(from: 0, to: sports.count, by: cols))

        return VStack(spacing: 12) {
            ForEach(rowStarts, id: \.self) { rowStart in
                let rowEnd = min(rowStart + cols, sports.count)
                let rowSports = Array(sports[rowStart..<rowEnd])
                let padding = cols - rowSports.count

                // Sport card row
                HStack(alignment: .top, spacing: 12) {
                    ForEach(rowSports) { sport in
                        SportCard(
                            sport: sport,
                            isSelected: store.isSportSelected(sport),
                            onTap: { handleSportTap(sport) }
                        )
                    }
                    // Pad incomplete last row so cards stay equal width
                    if padding > 0 {
                        ForEach(0..<padding, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }

                // Full-width expansion drawers below this row
                let expanded = rowSports.filter {
                    store.isSportSelected($0) && expandedSportIDs.contains($0.id)
                }
                ForEach(expanded) { sport in
                    LeagueExpansionDrawer(
                        sport: sport,
                        store: store,
                        showingAll: showingAllLeagues.contains(sport.id),
                        searchText: leagueSearch[sport.id] ?? "",
                        onToggleAll: { toggleShowAll(sport) },
                        onSearchChange: { leagueSearch[sport.id] = $0 }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

// MARK: - League expansion drawer (full-width)

private struct LeagueExpansionDrawer: View {
    let sport: CatalogSport
    @Bindable var store: OnboardingStore
    let showingAll: Bool
    let searchText: String
    let onToggleAll: () -> Void
    let onSearchChange: (String) -> Void

    private let maxInitial = 8
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
            if allLeagues.count >= maxInitial {
                LeagueSearchField(text: Binding(
                    get: { searchText },
                    set: { onSearchChange($0) }
                ))
                .padding(.top, 4)
            }

            FlowLayout(spacing: 8) {
                ForEach(displayedLeagues) { league in
                    LeaguePill(
                        league: league,
                        isSelected: store.isLeagueSelected(league)
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            store.toggleLeague(league, inSport: sport)
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }

            if allLeagues.count > maxInitial && searchText.isEmpty {
                let remaining = allLeagues.count - maxInitial
                Button(action: onToggleAll) {
                    Text(showingAll ? "Show fewer" : "Show \(remaining) more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - League pill (with logo)

private struct LeaguePill: View {
    let league: CatalogLeague
    let isSelected: Bool
    let onTap: () -> Void

    @State private var logoURL: URL?
    private let logoRepo = LeagueLogoRepository.shared

    private var displayLabel: String {
        logoRepo.displayLabel(for: league.id) ?? league.abbreviation ?? league.name
    }

    private var fallbackSFSymbol: String? {
        logoRepo.config(for: league.id)?.logo.fallbackSFSymbol
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                }

                // Logo area: remote image or SF Symbol fallback
                ZStack {
                    if let url = logoURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            default:
                                Color.clear
                            }
                        }
                    } else if let symbol = fallbackSFSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected ? .white.opacity(0.85) : Theme.textSecondary)
                    }
                }
                .frame(width: 20, height: 20)

                Text(displayLabel)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : Theme.textPrimary)
            .padding(.horizontal, isSelected ? 10 : 12)
            .padding(.vertical, 0)
            .frame(height: 36)
            .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(league.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .task(id: league.id) {
            logoURL = await logoRepo.logoURL(for: league.id)
        }
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
