import SwiftUI
import Combine

// MARK: - Live Tab

struct LiveView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @StateObject private var viewModel = LiveViewModel()
    @State private var filter: LiveFilter = .forYou
    @State private var selectedSport: SportGroup?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        PulsingLiveBadge()
                        Text("LIVE").font(.system(size: 16, weight: .black)).foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            .navigationDestination(for: Match.self) { MatchDetailView(match: $0) }
        }
        .tint(Theme.accent)
        .task {
            await viewModel.load(favoriteTeams: prefs.favoriteTeams)
            viewModel.startAutoRefresh(favoriteTeams: prefs.favoriteTeams)
        }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.allLive.isEmpty {
            loadingView
        } else {
            liveList
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().tint(Theme.live)
            Text("Scanning all sports…")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var liveList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Filter + Sport chips
                filterStrip

                if displayedMatches.isEmpty {
                    emptyState
                } else {
                    ForEach(groupedSports, id: \.self) { group in
                        let groupMatches = displayedMatches.filter { $0.league.group == group }
                        if !groupMatches.isEmpty {
                            liveSportSection(sport: group, matches: groupMatches)
                        }
                    }
                }

                if !viewModel.startingSoon.isEmpty {
                    startingSoonSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .refreshable {
            await viewModel.load(favoriteTeams: prefs.favoriteTeams, force: true)
        }
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LiveFilter.allCases) { f in
                    filterChip(f)
                }
            }
        }
    }

    private func filterChip(_ f: LiveFilter) -> some View {
        Button { withAnimation(.snappy) { filter = f } } label: {
            Text(f.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(filter == f ? .white : Theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(filter == f ? Theme.live : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(filter == f ? Theme.live : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private var displayedMatches: [Match] {
        let base: [Match]
        switch filter {
        case .forYou:
            let favIDs = Set(prefs.favoriteTeams.map(\.id))
            let favNames = Set(prefs.favoriteTeams.map { $0.displayName.lowercased() })
            let favMatches = viewModel.allLive.filter { involvesFavorite($0, favIDs: favIDs, favNames: favNames) }
            base = favMatches.isEmpty ? viewModel.allLive : favMatches
        case .closeGames:
            base = viewModel.allLive.filter { isClose($0) }
        case .all:
            base = viewModel.allLive
        }
        return base
    }

    private var groupedSports: [SportGroup] {
        var seen: [SportGroup] = []
        for match in displayedMatches {
            if !seen.contains(match.league.group) { seen.append(match.league.group) }
        }
        return seen
    }

    private func liveSportSection(sport: SportGroup, matches: [Match]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: sport.systemImage)
                    .font(.caption.weight(.bold))
                Text(sport.rawValue.uppercased())
                    .font(.caption.weight(.heavy))
                Spacer()
                Text("\(matches.count) LIVE")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(Theme.live)

            ForEach(matches) { match in
                NavigationLink(value: match) {
                    LiveMatchCard(match: match)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var startingSoonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.fill")
                Text("STARTING SOON")
                    .font(.caption.weight(.heavy))
            }
            .foregroundStyle(Theme.starting)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.startingSoon.prefix(8)) { match in
                        NavigationLink(value: match) {
                            CompactSoonCard(match: match)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sportscourt")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))

            if filter == .closeGames {
                Text("No close games right now.")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("All live games have comfortable leads.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } else if filter == .forYou {
                Text("None of your teams are live.")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if !viewModel.allLive.isEmpty {
                    Text("\(viewModel.allLive.count) other games are live.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Button("See All Live") {
                        withAnimation(.snappy) { filter = .all }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
            } else {
                Text("Nothing is live right now.")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if !viewModel.startingSoon.isEmpty {
                    Text("The next game starts in \(countdown(to: viewModel.startingSoon[0].date)).")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private func involvesFavorite(_ match: Match, favIDs: Set<String>, favNames: Set<String>) -> Bool {
        for side in [match.home, match.away] {
            if let tid = side.teamID, favIDs.contains("\(match.league.path)-\(tid)") { return true }
            if favNames.contains(side.displayName.lowercased()) { return true }
        }
        return false
    }

    private func isClose(_ match: Match) -> Bool {
        guard let h = match.home.score.flatMap(Int.init),
              let a = match.away.score.flatMap(Int.init) else { return false }
        let diff = abs(h - a)
        switch match.league.group {
        case .soccer, .hockey: return diff <= 1
        case .basketball: return diff <= 10
        case .baseball: return diff <= 3
        case .football: return diff <= 8
        case .golf, .racing: return false
        }
    }

    private func countdown(to date: Date) -> String {
        let secs = max(0, Int(date.timeIntervalSinceNow))
        let h = secs / 3600; let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }
}

// MARK: - Live Match Card

struct LiveMatchCard: View {
    let match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PulsingLiveBadge()
                Text(match.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(match.statusDetail)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.live)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                liveTeamColumn(match.away)
                Spacer()
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text(match.away.score ?? "-")
                        Text("–")
                            .foregroundStyle(Theme.textSecondary)
                        Text(match.home.score ?? "-")
                    }
                    .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                liveTeamColumn(match.home)
            }

            if !match.broadcasts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "tv")
                        .font(.caption2)
                    Text(match.broadcasts.prefix(2).joined(separator: " · "))
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.live.opacity(0.3))
        )
    }

    private func liveTeamColumn(_ side: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: side.logoURL, size: 44)
            Text(side.shortName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 80)
    }
}

// MARK: - Compact Soon Card

private struct CompactSoonCard: View {
    let match: Match

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let secs = max(0, Int(match.date.timeIntervalSince(ctx.date)))
            let h = secs / 3600; let m = (secs % 3600) / 60

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    TeamLogo(url: match.away.logoURL, size: 26)
                    Text("vs").font(.caption2.weight(.heavy)).foregroundStyle(Theme.textSecondary)
                    TeamLogo(url: match.home.logoURL, size: 26)
                }
                Text(match.shortName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 110)
                Text(h > 0 ? "\(h)h \(m)m" : "\(m) min")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(m < 10 && h == 0 ? Theme.live : Theme.starting)
                Text(match.league.shortName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(width: 130)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

// MARK: - Pulsing Live Badge

struct PulsingLiveBadge: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.live)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Filter

enum LiveFilter: String, CaseIterable, Identifiable {
    case forYou = "forYou"
    case closeGames = "closeGames"
    case all = "all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forYou: return "For You"
        case .closeGames: return "Close Games"
        case .all: return "All Live"
        }
    }
}

// MARK: - Live View Model

@MainActor
final class LiveViewModel: ObservableObject {
    @Published private(set) var allLive: [Match] = []
    @Published private(set) var startingSoon: [Match] = []
    @Published private(set) var isLoading = false

    private let service = ESPNService()
    private var refreshTask: Task<Void, Never>?
    private var lastLoaded: Date?
    private let cacheLifetime: TimeInterval = 60

    func load(favoriteTeams: [FavoriteTeam], force: Bool = false) async {
        if !force, let last = lastLoaded, Date().timeIntervalSince(last) < cacheLifetime { return }
        guard !isLoading else { return }
        isLoading = true

        var allMatches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in League.all {
                group.addTask {
                    (try? await self.service.scoreboards(for: league, starting: Date(), days: 1)) ?? []
                }
            }
            for await matches in group {
                allMatches.append(contentsOf: matches)
            }
        }

        let now = Date()
        let soonWindow = now.addingTimeInterval(4 * 3600)
        allLive = Array(Set(allMatches.filter { $0.state == .live }))
            .sorted { score($0, favTeams: favoriteTeams) > score($1, favTeams: favoriteTeams) }
        startingSoon = allMatches
            .filter { $0.state == .pre && $0.date > now && $0.date <= soonWindow }
            .sorted { $0.date < $1.date }

        isLoading = false
        lastLoaded = Date()
    }

    func startAutoRefresh(favoriteTeams: [FavoriteTeam]) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { continue }
                await self.load(favoriteTeams: favoriteTeams, force: true)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func score(_ match: Match, favTeams: [FavoriteTeam]) -> Int {
        let favIDs = Set(favTeams.map(\.id))
        let favNames = Set(favTeams.map { $0.displayName.lowercased() })
        var s = 0
        for side in [match.home, match.away] {
            if let tid = side.teamID, favIDs.contains("\(match.league.path)-\(tid)") { s += 50 }
            if favNames.contains(side.displayName.lowercased()) { s += 50 }
        }
        return s
    }
}
