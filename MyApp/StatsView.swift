import SwiftUI
#if os(iOS)
import UIKit
#endif

struct StatsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var selectedLeague: League = League.all[0]
    @State private var selectedSection: StatsSection = .overview
    @State private var teams: [Team] = []
    @State private var isLoadingTeams = false
    @State private var showPaywall = false


    private var leagues: [League] {
        prefs.followedLeagues.isEmpty ? League.all : prefs.followedLeagues
    }

    private var favoriteTeams: [FavoriteTeam] {
        prefs.favoriteTeams.filter { $0.leaguePath == selectedLeague.path || $0.leagueStadiaKey == selectedLeague.stadiaKey }
    }

    private var availableSections: [StatsSection] {
        StatsSection.available(for: selectedLeague)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    StatsLeaguePicker(leagues: leagues, selected: selectedLeague) { league in
                        selectedLeague = league
                        selectedSection = StatsSection.available(for: league).first ?? .overview
                    }
                    StatsSectionPicker(sections: availableSections, selected: $selectedSection)
                    content
                }
            }
            .navigationTitle("Stats")
            .toolbar { ToolbarItem(placement: .principal) { BrandMark() } }
        }
        .tint(Theme.accent)
        .task { syncLeagueSelection() }
        .task(id: selectedLeague.id) { await loadTeams() }
        .onChange(of: prefs.followedLeagues) { syncLeagueSelection() }
    }

    private static let premiumSections: Set<StatsSection> = [.standings, .leaders, .injuries]

    @ViewBuilder private var content: some View {
        switch selectedSection {
        case .overview:
            overview
        case .standings:
            if entitlements.isPremium {
                StandingsView(league: selectedLeague)
            } else {
                PremiumSectionGate(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Full Standings",
                    description: "Conference & division tables with every column, sorted by the sport's official tiebreakers.",
                    showPaywall: $showPaywall
                )
            }
        case .leaders:
            if entitlements.isPremium {
                LeadersView(league: selectedLeague)
            } else {
                PremiumSectionGate(
                    icon: "chart.bar.fill",
                    title: "Stat Leaders",
                    description: "Top performers for every key statistical category across the league.",
                    showPaywall: $showPaywall
                )
            }
        case .teams:
            teamsView
        case .injuries:
            if entitlements.isPremium {
                InjuriesView(league: selectedLeague)
            } else {
                PremiumSectionGate(
                    icon: "cross.case.fill",
                    title: "Injury Report",
                    description: "League-wide injury and availability status for every team.",
                    showPaywall: $showPaywall
                )
            }
        case .field:
            fieldView
        }
    }

    private var overview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                StatsLeagueHeader(league: selectedLeague, teamCount: teams.count, favoriteCount: favoriteTeams.count)

                if !favoriteTeams.isEmpty {
                    StatsFavoriteTeamsCard(league: selectedLeague, teams: favoriteTeams)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(availableSections.filter { $0 != .overview }) { section in
                        let isPremiumSection = Self.premiumSections.contains(section)
                        let isLocked = isPremiumSection && !entitlements.isPremium
                        Button {
                            if isLocked {
                                showPaywall = true
                                #if os(iOS)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                #endif
                            } else {
                                selectedSection = section
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                StatsActionTile(section: section, league: selectedLeague)
                                if isLocked {
                                    PremiumLockBadge()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sheet(isPresented: $showPaywall) {
                    PaywallView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }

            }
            .padding(16)
        }
        .refreshable { await loadTeams() }
    }

    @ViewBuilder private var teamsView: some View {
        if selectedLeague.group == .golf || selectedLeague.group == .racing || selectedLeague.group == .tennis {
            fieldView
        } else if isLoadingTeams && teams.isEmpty {
            Spacer()
            ProgressView().tint(Theme.accent)
            Spacer()
        } else if teams.isEmpty {
            StatsEmptyState(systemImage: "person.3.sequence", text: "Teams are not available for \(selectedLeague.name).") {
                Task { await loadTeams() }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if !favoriteTeams.isEmpty {
                        StatsTeamSection(title: "Favourites", league: selectedLeague, teams: teamsMatchingFavorites)
                    }
                    StatsTeamSection(title: "All Teams", league: selectedLeague, teams: teams)
                }
                .padding(16)
            }
            .refreshable { await loadTeams() }
        }
    }

    private var fieldView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                StatsFormatCard(league: selectedLeague)
                if selectedLeague.group == .racing {
                    RacersSection(league: selectedLeague)
                } else {
                    StatsGolfCard(league: selectedLeague)
                }
                NavigationLink {
                    LeadersView(league: selectedLeague)
                } label: {
                    StatsActionTile(section: .leaders, league: selectedLeague)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
    }

    private var teamsMatchingFavorites: [Team] {
        let favoriteIDs = Set(favoriteTeams.flatMap { favorite in
            [favorite.teamID, favorite.canonicalTeamID] + favorite.providerAliases.map(\.id)
        })
        return teams.filter { team in
            favoriteIDs.contains(team.id) || team.canonicalIDString.map { favoriteIDs.contains($0) } == true
        }
    }

    private func syncLeagueSelection() {
        let available = leagues
        if let first = available.first, !available.contains(selectedLeague) {
            selectedLeague = first
            selectedSection = StatsSection.available(for: first).first ?? .overview
        }
    }

    private func loadTeams() async {
        guard selectedLeague.group != .golf, selectedLeague.group != .racing, selectedLeague.group != .tennis else {
            teams = []
            isLoadingTeams = false
            return
        }
        isLoadingTeams = true
        teams = (try? await SportsRepository.shared.legacyTeams(for: selectedLeague)) ?? []
        isLoadingTeams = false
    }
}

private enum StatsSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case standings = "Standings"
    case leaders = "Leaders"
    case teams = "Teams"
    case injuries = "Injuries"
    case field = "Field"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .standings: return "list.number"
        case .leaders: return "chart.bar.fill"
        case .teams: return "person.3.fill"
        case .injuries: return "cross.case.fill"
        case .field: return "flag.checkered"
        }
    }

    static func available(for league: League) -> [StatsSection] {
        switch league.group {
        case .racing:
            return [.overview, .field, .leaders]
        case .golf:
            return [.overview, .field, .leaders]
        case .tennis:
            return [.overview, .standings, .leaders]
        case .soccer:
            return [.overview, .standings, .leaders, .teams]
        default:
            return [.overview, .standings, .leaders, .teams, .injuries]
        }
    }
}

private struct StatsLeaguePicker: View {
    let leagues: [League]
    let selected: League
    let onSelect: (League) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(leagues) { league in
                        Button {
                            onSelect(league)
                        } label: {
                            Label(league.shortName, systemImage: league.group.systemImage)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(league == selected ? .white : Theme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(league == selected ? Theme.accent : Theme.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(league == selected ? Color.clear : Theme.hairline))
                        }
                        .id(league.id)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: selected) { _, newValue in
                withAnimation { proxy.scrollTo(newValue.id, anchor: .center) }
            }
        }
        .background(Theme.background)
    }
}

private struct StatsSectionPicker: View {
    let sections: [StatsSection]
    @Binding var selected: StatsSection

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sections) { section in
                    Button {
                        selected = section
                    } label: {
                        Label(section.rawValue, systemImage: section.systemImage)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(section == selected ? .white : Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(section == selected ? Theme.surfaceElevated : Theme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(section == selected ? Theme.accent : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(Theme.background)
    }
}

private struct StatsLeagueHeader: View {
    let league: League
    let teamCount: Int
    let favoriteCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: league.group.systemImage)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(league.name)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var subtitle: String {
        if league.group == .golf { return "Tournament field, leaders, event context" }
        if league.group == .racing { return "Race field, standings-style results, leaderboards" }
        let teamText = teamCount == 1 ? "1 team" : "\(teamCount) teams"
        let favoriteText = favoriteCount == 1 ? "1 favourite" : "\(favoriteCount) favourites"
        return "\(teamText) · \(favoriteText)"
    }
}

private struct StatsActionTile: View {
    let section: StatsSection
    let league: League

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var detail: String {
        switch section {
        case .overview: return league.shortName
        case .standings: return league.group == .soccer ? "Table and form" : "Division tables"
        case .leaders: return league.group == .racing ? "Drivers and results" : "Top performers"
        case .teams: return "Rosters and profiles"
        case .injuries: return "Availability report"
        case .field: return league.group == .golf ? "Tournament field" : "Race entrants"
        }
    }
}

private struct StatsFavoriteTeamsCard: View {
    let league: League
    let teams: [FavoriteTeam]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FAVOURITES")
                .font(.footnote.weight(.heavy))
                .foregroundStyle(Theme.accent)
            ForEach(teams) { team in
                NavigationLink {
                    TeamRosterView(league: league, teamID: team.teamID, teamName: team.displayName)
                } label: {
                    HStack(spacing: 10) {
                        TeamLogo(url: team.logoURL, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(team.abbreviation)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct StatsTeamSection: View {
    let title: String
    let league: League
    let teams: [Team]

    var body: some View {
        if !teams.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(teams) { team in
                    NavigationLink {
                        TeamRosterView(league: league, teamID: team.id, teamName: team.displayName)
                    } label: {
                        HStack(spacing: 10) {
                            TeamLogo(url: team.logoURL, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(team.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(team.abbreviation.isEmpty ? team.shortDisplayName : team.abbreviation)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct StatsFormatCard: View {
    let league: League

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: league.group.systemImage)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var title: String {
        switch league.group {
        case .football: return "Football Format"
        case .basketball: return "Basketball Format"
        case .baseball: return "Baseball Format"
        case .hockey: return "Hockey Format"
        case .soccer: return "Soccer Format"
        case .tennis: return "Tennis Format"
        case .golf: return "Golf Format"
        case .racing: return "Racing Format"
        case .cycling, .wrestling, .esports: return "Sport Format"
        }
    }

    private var items: [String] {
        switch league.group {
        case .football:
            return ["Standings split by conference/division where ESPN provides it.", "Rosters are grouped by offense, defense, and special teams when available.", "Injuries and leaders are league-wide reference views."]
        case .basketball:
            return ["Conference standings and season leaders are primary.", "Team rosters open into player bio, news, and stat detail.", "Injuries are available for pro leagues when ESPN publishes them."]
        case .baseball:
            return ["Division standings emphasize record, games back, and streak.", "Rosters separate positional groups when ESPN returns them.", "Leaders prioritize batting, pitching, and run-production categories."]
        case .hockey:
            return ["Standings emphasize points, record, and streak.", "Rosters open player profiles and season stats.", "Injury reports appear when published by ESPN."]
        case .soccer:
            return ["League table is the main standings format.", "Team rosters are available for supported clubs and competitions.", "Leaders appear when ESPN publishes competition stat boards."]
        case .tennis:
            return ["Tennis uses draw brackets and match results instead of team rosters.", "Rankings and player match stats appear when ESPN publishes them.", "Team standings and injuries are not applicable for this format."]
        case .golf:
            return ["Golf uses tournament fields and scoreboards instead of team rosters.", "Leader boards are shown when ESPN exposes player statistics.", "Team standings and injuries are hidden for this format."]
        case .racing:
            return ["Racing uses entrants, race position, and constructor/team context.", "Race field replaces team rosters.", "Leader boards appear when supported for the series."]
        case .cycling, .wrestling, .esports:
            return []
        }
    }
}

private struct StatsGolfCard: View {
    let league: League

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tournament Field", systemImage: "figure.golf")
                .font(.headline.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
            Text("Golf events are loaded from ESPN scoreboards as tournaments, with player standings surfaced through the match detail and leaders views when ESPN publishes them.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                LeadersView(league: league)
            } label: {
                Label("Open Golf Leaders", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}


private struct StatsEmptyState: View {
    let systemImage: String
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: Theme.scaled(42)))
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Spacer()
        }
    }
}

#Preview {
    StatsView()
        .environmentObject(PreferencesStore())
        .preferredColorScheme(.dark)
}
