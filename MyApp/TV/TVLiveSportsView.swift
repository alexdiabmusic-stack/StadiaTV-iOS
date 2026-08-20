#if os(tvOS)
import SwiftUI

struct TVLiveSportsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var liveViewModel: LiveViewModel

    @State private var selectedSport: SportGroup? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                HStack(spacing: 0) {
                    sportSidebar
                    Divider().background(Theme.hairline)
                    contentArea
                }
            }
            .navigationTitle("Live Sports")
            .navigationDestination(for: Match.self) { TVMatchDetailView(match: $0) }
        }
        .tint(Theme.accent)
        .task {
            await liveViewModel.load(favoriteTeams: prefs.favoriteTeams)
            liveViewModel.startAutoRefresh(favoriteTeams: prefs.favoriteTeams)
        }
        .onDisappear { liveViewModel.stopAutoRefresh() }
    }

    // MARK: - Sport Sidebar

    private var sportSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text("SPORTS")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                sidebarRow(sport: nil, label: "All Sports", icon: "sportscourt.fill",
                           count: liveViewModel.allLive.count)

                let activeSports = activeSportGroups
                if !activeSports.isEmpty {
                    Divider().background(Theme.hairline).padding(.vertical, 4)

                    ForEach(activeSports, id: \.self) { sport in
                        let count = liveViewModel.allLive.filter { $0.league.group == sport }.count
                        sidebarRow(sport: sport, label: sport.rawValue,
                                   icon: sport.systemImage, count: count)
                    }
                }

                if !liveViewModel.startingSoon.isEmpty {
                    Divider().background(Theme.hairline).padding(.vertical, 4)
                    Text("STARTING SOON")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    Text("\(liveViewModel.startingSoon.count) games")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.surface)
        .frame(width: 260)
    }

    private func sidebarRow(sport: SportGroup?, label: String, icon: String, count: Int) -> some View {
        let selected = selectedSport == sport
        return Button {
            withAnimation(.snappy) { selectedSport = sport }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .frame(width: 24)
                    .foregroundStyle(selected ? .white : Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.body.weight(selected ? .bold : .regular))
                        .foregroundStyle(selected ? .white : Theme.textPrimary)
                        .lineLimit(1)
                    if count > 0 {
                        Text("\(count) live")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(selected ? .white.opacity(0.7) : Theme.live)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                selected ? Theme.accent.opacity(0.9) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if liveViewModel.isLoading && liveViewModel.allLive.isEmpty {
            VStack(spacing: 20) {
                ProgressView().tint(Theme.live).scaleEffect(2)
                Text("Scanning all sports…")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedMatches.isEmpty && liveViewModel.startingSoon.isEmpty {
            TVEmptyState(
                systemImage: "sportscourt",
                title: "Nothing live right now",
                subtitle: "Check back soon — new games will appear here automatically."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 48) {
                    if !displayedMatches.isEmpty {
                        liveMatchesSection
                    }
                    if !liveViewModel.startingSoon.isEmpty {
                        startingSoonSection
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 40)
            }
        }
    }

    private var liveMatchesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                TVLiveBadge()
                Text(displayedMatches.count == 1 ? "1 game live" : "\(displayedMatches.count) games live")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 340, maximum: 400), spacing: 20)],
                spacing: 20
            ) {
                ForEach(displayedMatches) { match in
                    NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                }
            }
        }
    }

    private var startingSoonSection: some View {
        TVShelfRow(title: "Starting Soon", systemImage: "clock.badge.fill", tint: Theme.starting) {
            ForEach(liveViewModel.startingSoon.prefix(10)) { match in
                NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
            }
        }
    }

    // MARK: - Derived Data

    private var displayedMatches: [Match] {
        guard let sport = selectedSport else { return liveViewModel.allLive }
        return liveViewModel.allLive.filter { $0.league.group == sport }
    }

    private var activeSportGroups: [SportGroup] {
        var seen: [SportGroup] = []
        for match in liveViewModel.allLive {
            if !seen.contains(match.league.group) { seen.append(match.league.group) }
        }
        return seen
    }
}
#endif
