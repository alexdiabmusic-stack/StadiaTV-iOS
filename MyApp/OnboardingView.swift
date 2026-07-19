import SwiftUI
import Combine

/// First-launch flow: choose sports → leagues → favorite teams → optional playlist.
struct OnboardingView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore

    enum Step: Int, CaseIterable {
        case welcome, sports, leagues, teams, playlist
    }

    @State private var step: Step = .welcome
    @State private var selectedSports: Set<SportGroup> = []
    @State private var selectedLeagues: Set<League> = []
    @State private var teamSearchText = ""
    @State private var showingAddPlaylist = false
    @StateObject private var teamsLoader = OnboardingTeamsLoader()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if step != .welcome { progressBar }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        .tint(Theme.accent)
    }

    // MARK: Progress

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.dropFirst(), id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.accent : Theme.surfaceElevated)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .sports: sportsStep
        case .leagues: leaguesStep
        case .teams: teamsStep
        case .playlist: playlistStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("BrandIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
            BrandMark().scaleEffect(1.6)
            Text("Live matches, scores, and your playlists — all in one place.")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var sportsStep: some View {
        StepScaffold(title: "Pick your sports",
                     subtitle: "We'll tailor scores and schedules to what you follow.") {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(SportGroup.allCases) { sport in
                        SelectableCard(
                            title: sport.rawValue,
                            systemImage: sport.systemImage,
                            isSelected: selectedSports.contains(sport)
                        ) {
                            toggle(sport)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var leaguesStep: some View {
        StepScaffold(title: "Choose leagues",
                     subtitle: "Only these will appear in your Matches tab.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sportsForLeagueStep) { sport in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(sport.rawValue, systemImage: sport.systemImage)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            FlowChips(leagues: League.leagues(in: sport),
                                      isSelected: { selectedLeagues.contains($0) },
                                      onTap: toggle)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var teamsStep: some View {
        StepScaffold(title: "Favorite teams",
                     subtitle: "Star teams to filter matches and improve source matching.") {
            Group {
                if teamsLoader.isLoading && teamsLoader.teamsByLeague.isEmpty {
                    VStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                } else if teamsLoader.teamsByLeague.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("No teams to show. You can add favorites later.")
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                } else {
                    teamsList
                }
            }
        }
        .task(id: leaguesKey) { await teamsLoader.load(leagues: Array(selectedLeagues)) }
    }

    private var teamsList: some View {
        VStack(spacing: 12) {
            TeamSearchField(text: $teamSearchText)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    if isSearchingTeams {
                        if matchingTeams.isEmpty {
                            Text("No teams match your search.")
                                .font(.callout)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                        } else {
                            Section {
                                ForEach(matchingTeams) { result in
                                    TeamPickRow(team: result.team,
                                                leagueName: result.league.shortName,
                                                isFavorite: prefs.isFavorite(result.team, in: result.league)) {
                                        prefs.toggleFavorite(result.team, in: result.league)
                                    }
                                }
                            } header: {
                                Text("Search Results")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(Theme.background)
                            }
                        }
                    } else {
                        ForEach(orderedLeaguesWithTeams, id: \.id) { league in
                            Section {
                                ForEach(teamsLoader.teamsByLeague[league] ?? []) { team in
                                    TeamPickRow(team: team,
                                                leagueName: nil,
                                                isFavorite: prefs.isFavorite(team, in: league)) {
                                        prefs.toggleFavorite(team, in: league)
                                    }
                                }
                            } header: {
                                Text(league.name)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(Theme.background)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var playlistStep: some View {
        StepScaffold(title: "Add a playlist",
                     subtitle: "Add an M3U link or Xtream account to stream matches. You can also do this later.") {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "list.and.film")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.accent)
                if playlists.playlists.isEmpty {
                    Text("No playlists added yet.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(playlists.playlists.count) playlist(s) added — you're all set!")
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    showingAddPlaylist = true
                } label: {
                    Label("Add Playlist", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingAddPlaylist) {
            AddPlaylistView { playlists.add($0) }
        }
    }

    // MARK: Footer navigation

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back") { back() }
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button(action: next) {
                Text(primaryButtonTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canAdvance ? Theme.accent : Theme.accent.opacity(0.4),
                               in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!canAdvance)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .playlist: return "Finish"
        case .teams: return "Continue"
        default: return "Continue"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .sports: return !selectedSports.isEmpty
        case .leagues: return !selectedLeagues.isEmpty
        default: return true
        }
    }

    // MARK: Logic

    private var sportsForLeagueStep: [SportGroup] {
        SportGroup.allCases.filter { selectedSports.contains($0) }
    }

    private var leaguesKey: String {
        selectedLeagues.map(\.path).sorted().joined(separator: ",")
    }

    private var orderedLeaguesWithTeams: [League] {
        League.all.filter { teamsLoader.teamsByLeague[$0] != nil }
    }

    private var isSearchingTeams: Bool {
        !teamSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matchingTeams: [TeamSearchResult] {
        let query = teamSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return orderedLeaguesWithTeams.flatMap { league in
            (teamsLoader.teamsByLeague[league] ?? [])
                .filter { team in
                    [team.displayName, team.shortDisplayName, team.abbreviation, league.name, league.shortName]
                        .contains { $0.localizedCaseInsensitiveContains(query) }
                }
                .map { TeamSearchResult(league: league, team: $0) }
        }
    }

    private func toggle(_ sport: SportGroup) {
        if selectedSports.contains(sport) {
            selectedSports.remove(sport)
            // Drop leagues that belong only to the removed sport.
            selectedLeagues = selectedLeagues.filter { $0.group != sport }
        } else {
            selectedSports.insert(sport)
        }
    }

    private func toggle(_ league: League) {
        if selectedLeagues.contains(league) {
            selectedLeagues.remove(league)
        } else {
            selectedLeagues.insert(league)
        }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation { step = prev }
    }

    private func next() {
        if step == .leagues {
            prefs.setLeagues(selectedLeagues)
        }
        if step == .playlist {
            prefs.setLeagues(selectedLeagues)
            prefs.completeOnboarding()
            return
        }
        if let nextStep = Step(rawValue: step.rawValue + 1) {
            withAnimation { step = nextStep }
        }
    }
}

// MARK: - Teams loader

private struct TeamSearchResult: Identifiable, Hashable {
    let league: League
    let team: Team
    var id: String { league.id + "-" + team.id }
}

@MainActor
final class OnboardingTeamsLoader: ObservableObject {
    @Published private(set) var teamsByLeague: [League: [Team]] = [:]
    @Published private(set) var isLoading = false

    private let service = ESPNService()
    private var loadedKey: String?

    func load(leagues: [League]) async {
        let key = leagues.map(\.path).sorted().joined(separator: ",")
        guard key != loadedKey else { return }
        loadedKey = key
        isLoading = true
        var result: [League: [Team]] = [:]
        await withTaskGroup(of: (League, [Team]).self) { group in
            for league in leagues {
                group.addTask {
                    let teams = (try? await self.service.teams(for: league)) ?? []
                    return (league, teams)
                }
            }
            for await (league, teams) in group where !teams.isEmpty {
                result[league] = teams
            }
        }
        teamsByLeague = result
        isLoading = false
    }
}

// MARK: - Reusable pieces

private struct StepScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            content
        }
    }
}

private struct SelectableCard: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(isSelected ? .white : Theme.accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(isSelected ? Theme.accent : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Wrapping chips of leagues for a sport.
private struct FlowChips: View {
    let leagues: [League]
    let isSelected: (League) -> Bool
    let onTap: (League) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(leagues) { league in
                let selected = isSelected(league)
                Button {
                    onTap(league)
                } label: {
                    HStack(spacing: 6) {
                        if selected { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        Text(league.name)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selected ? .white : Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(selected ? Theme.accent : Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TeamSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search teams", text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct TeamPickRow: View {
    let team: Team
    let leagueName: String?
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncImage(url: team.logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "shield.fill").foregroundStyle(Theme.textSecondary.opacity(0.5))
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let leagueName {
                        Text(leagueName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Theme.accent : Theme.textSecondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove \(team.displayName) from favorites" : "Add \(team.displayName) to favorites")
    }
}
