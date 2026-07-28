#if os(tvOS)
import SwiftUI

struct TVOnboardingView: View {
    @EnvironmentObject private var prefs: PreferencesStore

    enum Step: Int, CaseIterable {
        case welcome, sports, leagues, teams, done
    }

    @State private var step: Step = .welcome
    @State private var selectedSports: Set<SportGroup> = []
    @State private var selectedLeagues: Set<League> = []
    @StateObject private var teamsLoader = TVOnboardingTeamsLoader()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if step != .welcome {
                    progressBar
                        .padding(.top, 40)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Progress

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases.dropFirst(), id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.accent : Theme.surfaceElevated)
                    .frame(height: 6)
            }
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .sports: sportsStep
        case .leagues: leaguesStep
        case .teams: teamsStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            Spacer()
            Image("BrandIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.hairline))
            BrandMark().scaleEffect(2.0)
            Text("Live matches, scores, and your playlists — all in one place.")
                .font(.title2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            Spacer()
        }
    }

    private var sportsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeader(title: "Pick your sports",
                       subtitle: "We'll tailor scores and schedules to what you follow.")
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(SportGroup.allCases) { sport in
                        let selected = selectedSports.contains(sport)
                        Button {
                            if selectedSports.contains(sport) {
                                selectedSports.remove(sport)
                                selectedLeagues = selectedLeagues.filter { $0.group != sport }
                            } else {
                                selectedSports.insert(sport)
                            }
                        } label: {
                            VStack(spacing: 16) {
                                Image(systemName: sport.systemImage)
                                    .font(.system(size: 42, weight: .bold))
                                    .foregroundStyle(selected ? .white : Theme.accent)
                                Text(sport.rawValue)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(selected ? .white : Theme.textPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .background(selected ? Theme.accent : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(selected ? Color.clear : Theme.hairline)
                            )
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 32)
            }
        }
    }

    private var leaguesStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeader(title: "Choose leagues",
                       subtitle: "Only these will appear in your Schedule tab.")
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(SportGroup.allCases.filter { selectedSports.contains($0) }) { sport in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(sport.rawValue, systemImage: sport.systemImage)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 80)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(League.leagues(in: sport)) { league in
                                        let selected = selectedLeagues.contains(league)
                                        Button {
                                            if selected { selectedLeagues.remove(league) }
                                            else { selectedLeagues.insert(league) }
                                        } label: {
                                            HStack(spacing: 8) {
                                                if selected {
                                                    Image(systemName: "checkmark")
                                                        .font(.caption.weight(.bold))
                                                }
                                                Text(league.name)
                                                    .font(.headline.weight(.medium))
                                            }
                                            .foregroundStyle(selected ? .white : Theme.textPrimary)
                                            .padding(.horizontal, 20).padding(.vertical, 14)
                                            .background(selected ? Theme.accent : Theme.surface,
                                                        in: Capsule())
                                            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.hairline))
                                        }
                                        .buttonStyle(.card)
                                    }
                                }
                                .padding(.horizontal, 80)
                            }
                        }
                    }
                }
                .padding(.bottom, 32)
            }
        }
    }

    private var teamsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeader(title: "Favorite teams",
                       subtitle: "Star teams to filter matches and improve source matching.")
            Group {
                if teamsLoader.isLoading && teamsLoader.teamsByLeague.isEmpty {
                    VStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                } else if teamsLoader.teamsByLeague.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("No teams to show. Continue to use all teams.")
                            .foregroundStyle(Theme.textSecondary)
                            .font(.title3)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(League.all.filter { teamsLoader.teamsByLeague[$0] != nil }) { league in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(league.name)
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 80)
                                    LazyVGrid(
                                        columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 12)],
                                        spacing: 12
                                    ) {
                                        ForEach(teamsLoader.teamsByLeague[league] ?? []) { team in
                                            let isFav = prefs.isFavorite(team, in: league)
                                            Button {
                                                prefs.toggleFavorite(team, in: league)
                                            } label: {
                                                HStack(spacing: 14) {
                                                    AsyncImage(url: team.logoURL) { phase in
                                                        if case .success(let img) = phase {
                                                            img.resizable().scaledToFit()
                                                        } else {
                                                            Image(systemName: "shield.fill")
                                                                .foregroundStyle(Theme.textSecondary.opacity(0.5))
                                                        }
                                                    }
                                                    .frame(width: 40, height: 40)
                                                    Text(team.displayName)
                                                        .font(.headline.weight(.medium))
                                                        .foregroundStyle(Theme.textPrimary)
                                                        .lineLimit(1)
                                                    Spacer()
                                                    Image(systemName: isFav ? "star.fill" : "star")
                                                        .foregroundStyle(isFav ? Theme.accent : Theme.textSecondary)
                                                        .font(.title3)
                                                }
                                                .padding(.horizontal, 16).padding(.vertical, 14)
                                                .background(isFav ? Theme.accent.opacity(0.12) : Theme.surface,
                                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .strokeBorder(isFav ? Theme.accent.opacity(0.4) : Theme.hairline)
                                                )
                                            }
                                            .buttonStyle(.card)
                                        }
                                    }
                                    .padding(.horizontal, 80)
                                }
                            }
                        }
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .task(id: leaguesKey) { await teamsLoader.load(leagues: Array(selectedLeagues)) }
    }

    private var doneStep: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Theme.accent)
            Text("You're all set!")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Add a playlist in Settings to start streaming live TV.")
                .font(.title2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            if step != .welcome {
                Button("Back") { back() }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .buttonStyle(.card)
            }
            Button(action: advance) {
                Text(primaryTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(canAdvance ? Theme.accent : Theme.accent.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.card)
            .disabled(!canAdvance)
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 24)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .done: return "Start Watching"
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

    private var leaguesKey: String {
        selectedLeagues.map(\.path).sorted().joined(separator: ",")
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation { step = prev }
    }

    private func advance() {
        if step == .leagues { prefs.setLeagues(selectedLeagues) }
        if step == .done { prefs.completeOnboarding(); return }
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation { step = next }
        }
    }

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
    }
}

// MARK: - Teams loader (TV-local, mirrors OnboardingTeamsLoader)

@MainActor
private final class TVOnboardingTeamsLoader: ObservableObject {
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
#endif
