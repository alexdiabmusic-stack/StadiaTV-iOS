#if os(tvOS)
import SwiftUI

// Local stats section enum (mirrors the private one in StatsView.swift)
private enum TVStatsSection: String, CaseIterable, Identifiable {
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

    var isPremium: Bool { self == .standings || self == .leaders || self == .injuries }

    static func available(for league: League) -> [TVStatsSection] {
        switch league.group {
        case .racing: return [.overview, .field, .leaders]
        case .golf: return [.overview, .field, .leaders]
        default: return allCases.filter { $0 != .field }
        }
    }
}

struct TVStatsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var selectedLeague: League = League.all[0]
    @State private var selectedSection: TVStatsSection = .overview
    @State private var showPaywall = false

    private var leagues: [League] {
        prefs.followedLeagues.isEmpty ? League.all : prefs.followedLeagues
    }

    private var availableSections: [TVStatsSection] { TVStatsSection.available(for: selectedLeague) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                HStack(spacing: 0) {
                    leagueSidebar
                    Divider().background(Theme.hairline)
                    contentArea
                }
            }
            .navigationTitle("Stats")
        }
        .tint(Theme.accent)
        .task { syncLeague() }
        .onChange(of: prefs.followedLeagues) { syncLeague() }
        .fullScreenCover(isPresented: $showPaywall) {
            TVPaywallView()
        }
    }

    private func syncLeague() {
        if let first = leagues.first, !leagues.contains(selectedLeague) {
            selectedLeague = first
            selectedSection = TVStatsSection.available(for: first).first ?? .overview
        }
    }

    // MARK: - League Sidebar

    private var leagueSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text("LEAGUES")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                ForEach(leagues) { league in
                    Button {
                        selectedLeague = league
                        selectedSection = TVStatsSection.available(for: league).first ?? .overview
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: league.group.systemImage)
                                .font(.body.weight(.semibold))
                                .frame(width: 24)
                                .foregroundStyle(selectedLeague == league ? .white : Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(league.name)
                                    .font(.body.weight(selectedLeague == league ? .bold : .regular))
                                    .foregroundStyle(selectedLeague == league ? .white : Theme.textPrimary)
                                    .lineLimit(1)
                                Text(league.shortName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(selectedLeague == league ? .white.opacity(0.7) : Theme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            selectedLeague == league ? Theme.accent.opacity(0.9) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.surface)
        .frame(width: 280)
    }

    // MARK: - Section Grid + Content

    private var contentArea: some View {
        VStack(spacing: 0) {
            sectionPicker
            Divider().background(Theme.hairline)
            sectionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableSections) { section in
                    Button {
                        if section.isPremium && !entitlements.isPremium {
                            showPaywall = true
                        } else {
                            selectedSection = section
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.systemImage)
                                .font(.caption.weight(.bold))
                            Text(section.rawValue)
                                .font(.subheadline.weight(.bold))
                            if section.isPremium && !entitlements.isPremium {
                                Image(systemName: "lock.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .foregroundStyle(selectedSection == section ? .white : Theme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            selectedSection == section ? Theme.accent : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case .overview:
            overviewGrid
        case .standings:
            StandingsView(league: selectedLeague)
        case .leaders:
            LeadersView(league: selectedLeague)
        case .teams:
            TVTeamsSection(league: selectedLeague)
        case .injuries:
            InjuriesView(league: selectedLeague)
        case .field:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    RacersSection(league: selectedLeague)
                }
                .padding(32)
            }
        }
    }

    private var overviewGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 20)],
                spacing: 20
            ) {
                ForEach(availableSections.filter { $0 != .overview }) { section in
                    Button {
                        if section.isPremium && !entitlements.isPremium {
                            showPaywall = true
                        } else {
                            selectedSection = section
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: section.systemImage)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 48, height: 48)
                                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(section.rawValue)
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(Theme.textPrimary)
                                    if section.isPremium && !entitlements.isPremium {
                                        Image(systemName: "lock.fill")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                Text(section == .standings ? "Tables & standings" : section == .leaders ? "Top performers" : section == .teams ? "Rosters & profiles" : section == .injuries ? "Injury report" : "Race field")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.hairline)
                        )
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(32)
        }
    }
}

// MARK: - Teams section (inline for TV)

private struct TVTeamsSection: View {
    let league: League
    @State private var teams: [Team] = []
    @State private var isLoading = true
    private let service = ESPNService()

    var body: some View {
        Group {
            if isLoading && teams.isEmpty {
                ProgressView().tint(Theme.accent).scaleEffect(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if teams.isEmpty {
                TVEmptyState(systemImage: "person.3", title: "Teams not available for \(league.name)")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)], spacing: 16) {
                        ForEach(teams) { team in
                            NavigationLink {
                                TeamRosterView(league: league, teamID: team.id, teamName: team.displayName)
                            } label: {
                                VStack(spacing: 10) {
                                    AsyncImage(url: team.logoURL) { phase in
                                        switch phase {
                                        case .success(let img): img.resizable().scaledToFit()
                                        default: Image(systemName: "shield.fill").font(.title).foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .frame(width: 64, height: 64)
                                    Text(team.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, minHeight: 140)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(32)
                }
            }
        }
        .task(id: league.id) { await loadTeams() }
    }

    private func loadTeams() async {
        guard league.group != .golf && league.group != .racing else { isLoading = false; return }
        isLoading = true
        teams = (try? await service.teams(for: league)) ?? []
        isLoading = false
    }
}
#endif
