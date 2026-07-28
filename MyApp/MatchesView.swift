import SwiftUI

struct MatchesView: View {
    @StateObject private var viewModel = MatchesViewModel()
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var predictions: PredictionsStore
    @State private var favoritesOnly = false
    @State private var showingSearch = false
    @State private var showingPicksDashboard = false
    @State private var selectedPickPrediction: Prediction?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationDestination(for: Match.self) { match in
                MatchDetailView(match: match)
            }
            .toolbar {
                ToolbarItem(placement: .principal) { BrandMark() }
                ToolbarItem(placement: .navigation) {
                    if !prefs.favoriteTeams.isEmpty {
                        Button {
                            favoritesOnly.toggle()
                            if favoritesOnly {
                                Task { await viewModel.loadFavoriteSchedule(favorites: prefs.favoriteTeams) }
                            }
                        } label: {
                            Image(systemName: favoritesOnly ? "star.fill" : "star")
                                .foregroundStyle(favoritesOnly ? Theme.accent : Theme.textSecondary)
                        }
                        .accessibilityLabel(favoritesOnly ? "Show all games" : "Show favorite team games")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                }
            }
            .sheet(isPresented: $showingSearch) {
                SearchView()
            }
            .sheet(isPresented: $showingPicksDashboard) {
                PicksDashboardView()
            }
            .sheet(item: $selectedPickPrediction) { prediction in
                PickMatchDetailSheet(prediction: prediction)
            }
        }
        .tint(Theme.accent)
        .task {
            syncSelectedLeague()
            await loadAndSyncNotifications()
            await predictions.resolveStaleIfNeeded()
        }
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    /// Ensures the active league is one the user actually follows.
    private func syncSelectedLeague() {
        let followed = prefs.followedLeagues
        if let first = followed.first, !followed.contains(viewModel.selectedLeague) {
            viewModel.selectLeague(first)
        }
    }

    private func loadAndSyncNotifications() async {
        await viewModel.load()
        predictions.resolveAll(from: viewModel.matches)
        if prefs.matchNotificationsEnabled {
            await MatchNotificationService.shared.syncNotifications(matches: viewModel.matches, favorites: prefs.favoriteTeams, leadTime: prefs.matchReminderLeadTime)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            LeaguePicker(leagues: prefs.followedLeagues,
                         selected: viewModel.selectedLeague) { viewModel.selectLeague($0) }

            if favoritesOnly {
                favoritesContent
            } else {
                if viewModel.isLoading {
                    Spacer()
                    ProgressView().tint(Theme.accent)
                    Spacer()
                } else if let error = viewModel.errorMessage, viewModel.matches.isEmpty {
                    errorState(error)
                } else if viewModel.matches.isEmpty {
                    emptyState
                } else {
                    matchList
                }
            }
        }
    }

    private var matchList: some View {
        ScrollView {
            LazyVStack(spacing: 20, pinnedViews: [.sectionHeaders]) {
                myPicksSection
                section("Live", systemImage: "dot.radiowaves.left.and.right",
                        tint: Theme.live, matches: viewModel.liveMatches)
                section("Upcoming", systemImage: "clock",
                        tint: Theme.accent, matches: viewModel.upcomingMatches)
                section("Final", systemImage: "checkmark.circle",
                        tint: Theme.textSecondary, matches: viewModel.finishedMatches)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .refreshable { await loadAndSyncNotifications() }
    }

    @ViewBuilder private var myPicksSection: some View {
        let leaguePredictions = predictions.predictions
            .filter { $0.leagueName == viewModel.selectedLeague.name }
            .sorted { $0.placedAt > $1.placedAt }
        if !leaguePredictions.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(leaguePredictions) { prediction in
                            PickResultCard(prediction: prediction)
                                .onTapGesture { selectedPickPrediction = prediction }
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                    Text("My Picks").textCase(.uppercase)
                    if predictions.currentStreak >= 2 {
                        Text("🔥 \(predictions.currentStreak)")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color(hex: 0xFF6B35))
                    }
                    Spacer()
                    if predictions.totalPoints > 0 {
                        Text("\(predictions.totalPoints) pts")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.trailing, 4)
                    }
                    Button {
                        showingPicksDashboard = true
                    } label: {
                        Text("See All")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 6)
                .background(Theme.background)
            }
        }
    }

    // MARK: Favorite teams schedule

    /// Every announced game for the user's favorite teams, fetched across leagues
    /// when the star button is pressed.
    @ViewBuilder private var favoritesContent: some View {
        if viewModel.isLoadingFavorites && viewModel.favoriteMatches.isEmpty {
            Spacer()
            ProgressView().tint(Theme.accent)
            Text("Fetching announced games for your teams…")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
            Spacer()
        } else if viewModel.favoriteMatchesForSelectedLeague.isEmpty {
            VStack {
                Spacer()
                Image(systemName: "star")
                    .font(.system(size: Theme.scaled(44)))
                    .foregroundStyle(Theme.textSecondary)
                Text("No announced games for your favorite teams in \(viewModel.selectedLeague.name).")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 20, pinnedViews: [.sectionHeaders]) {
                    section("Live", systemImage: "dot.radiowaves.left.and.right",
                            tint: Theme.live,
                            matches: viewModel.favoriteMatchesForSelectedLeague.filter { $0.state == .live })
                    section("Announced", systemImage: "calendar",
                            tint: Theme.accent,
                            matches: viewModel.favoriteMatchesForSelectedLeague.filter { $0.state == .pre })
                    section("Final", systemImage: "checkmark.circle",
                            tint: Theme.textSecondary,
                            matches: viewModel.favoriteMatchesForSelectedLeague.filter { $0.state == .final }.sorted { $0.date > $1.date })
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .refreshable { await viewModel.loadFavoriteSchedule(favorites: prefs.favoriteTeams) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, systemImage: String, tint: Color, matches: [Match]) -> some View {
        if !matches.isEmpty {
            Section {
                ForEach(matches) { match in
                    NavigationLink(value: match) {
                        MatchRow(match: match)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                    Text(title).textCase(.uppercase)
                    Spacer()
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)
                .padding(.vertical, 6)
                .background(Theme.background)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: "sportscourt")
                .font(.system(size: Theme.scaled(44)))
                .foregroundStyle(Theme.textSecondary)
            Text("No games scheduled for \(viewModel.selectedLeague.name) today.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 8)
            Spacer()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: Theme.scaled(40)))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try Again") { Task { await viewModel.load() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Spacer()
        }
    }
}

// MARK: - League picker

private struct LeaguePicker: View {
    let leagues: [League]
    let selected: League
    let onSelect: (League) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(leagues) { league in
                        let isSelected = league == selected
                        Button {
                            onSelect(league)
                        } label: {
                            Text(league.shortName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(isSelected ? Theme.accent : Theme.surface)
                                )
                        }
                        .id(league.id)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: selected) { _, new in
                withAnimation { proxy.scrollTo(new.id, anchor: .center) }
            }
        }
        .background(Theme.background)
    }
}

// MARK: - Match row

struct MatchRow: View {
    let match: Match
    @EnvironmentObject private var prefs: PreferencesStore

    private var spoilersHidden: Bool {
        prefs.spoilerFreeMode && match.state == .final
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(match.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusBadge
            }

            VStack(spacing: 12) {
                teamRow(match.away)
                teamRow(match.home)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func teamRow(_ team: TeamSide) -> some View {
        HStack(spacing: 12) {
            TeamLogo(url: team.logoURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(team.shortName)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if let record = team.record, !record.isEmpty {
                    Text(record)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if match.state != .pre {
                if spoilersHidden {
                    Text("?")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 42, alignment: .trailing)
                } else if let score = team.score {
                    Text(score)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(team.isWinner ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }

    private var statusBadge: some View {
        Group {
            switch match.state {
            case .live:
                Label(match.statusDetail, systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.live, in: Capsule())
            case .pre:
                Text(match.statusDetail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.surfaceElevated, in: Capsule())
            case .final:
                Text("FINAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
        }
    }
}

// MARK: - Pick result card

struct PickResultCard: View {
    let prediction: Prediction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor)
                Text(prediction.leagueName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.4))
            }
            Text(prediction.awayTeamName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text("vs \(prediction.homeTeamName)")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: prediction.pick.systemImage)
                    .font(.caption2.weight(.bold))
                Text(prediction.pick.label(away: prediction.awayTeamName, home: prediction.homeTeamName))
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(pickColor)
        }
        .padding(12)
        .frame(width: 160, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(borderColor))
    }

    private var pickColor: Color {
        switch prediction.isCorrect {
        case true: return Color(hex: 0x3DBE6B)
        case false: return Theme.live
        case nil: return Theme.accent
        }
    }

    private var statusIcon: String {
        switch prediction.isCorrect {
        case true: return "checkmark.circle.fill"
        case false: return "xmark.circle.fill"
        case nil: return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch prediction.isCorrect {
        case true: return Color(hex: 0x3DBE6B)
        case false: return Theme.live
        case nil: return Theme.textSecondary
        }
    }

    private var borderColor: Color {
        switch prediction.isCorrect {
        case true: return Color(hex: 0x3DBE6B).opacity(0.4)
        case false: return Theme.live.opacity(0.4)
        case nil: return Theme.hairline
        }
    }
}

/// Loads a team logo, falling back to a neutral placeholder.
struct TeamLogo: View {
    let url: URL?
    var size: CGFloat = 34

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Image(systemName: "shield.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
    }
}
