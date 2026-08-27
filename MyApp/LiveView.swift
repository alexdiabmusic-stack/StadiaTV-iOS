import SwiftUI
import Combine

// MARK: - Live Tab

struct LiveView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var viewModel: LiveViewModel
    @EnvironmentObject private var fantasyStore: FantasyStore
    @AppStorage("live.filter.v1") private var savedFilterRaw: String = LiveFilter.forYou.rawValue
    @State private var filter: LiveFilter = .forYou
    @State private var selectedSport: SportGroup?
    @State private var hiddenMatchIDs: Set<String> = []
    @State private var showingActionAlert = false
    @State private var actionAlertMessage = ""
    @State private var showingChannels = false

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("Live")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showingChannels = true } label: {
                            Image(systemName: "tv")
                                .foregroundStyle(Theme.textPrimary)
                        }
                        NavigationLink(destination: SearchView()) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .sheet(isPresented: $showingChannels) {
                    LiveTVView()
                }
                .navigationDestination(for: Match.self) { MatchDetailView(match: $0) }
        }
        .tint(Theme.accent)
        .task {
            filter = LiveFilter(rawValue: savedFilterRaw) ?? .forYou
            await viewModel.load(favoriteTeams: prefs.favoriteTeams)
            viewModel.startAutoRefresh(favoriteTeams: prefs.favoriteTeams)
        }
        .onChange(of: filter) { _, new in savedFilterRaw = new.rawValue }
        .onDisappear { viewModel.stopAutoRefresh() }
        .alert("Live", isPresented: $showingActionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionAlertMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        if filter == .guide {
            VStack(spacing: 0) {
                filterStrip
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Theme.background)
                Divider().overlay(Theme.hairline)
                TVGuideView()
            }
        } else if viewModel.isLoading && viewModel.allLive.isEmpty {
            loadingView
        } else {
            VStack(spacing: 0) {
                filterStrip
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Theme.background)
                Divider().overlay(Theme.hairline)
                liveList
            }
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
                if !viewModel.allLive.isEmpty {
                    Text(viewModel.allLive.count == 1 ? "1 game currently live" : "\(viewModel.allLive.count) games currently live")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                sportNavigator

                if visibleMatches.isEmpty {
                    emptyState
                } else if selectedSport != nil {
                    ForEach(visibleMatches) { match in
                        NavigationLink(value: match) {
                            LiveMatchCard(
                                match: match,
                                onSetAlert: { Task { await setAlert(for: match) } },
                                onAddToCalendar: { Task { await addToCalendar(match) } },
                                onHide: { hide(match) },
                                showScoreBar: prefs.showLiveScoreBar,
                                fantasyContext: liveFantasyContext(for: match)
                            )
                        }
                            .buttonStyle(.plain)
                    }
                } else {
                    ForEach(groupedSports, id: \.self) { group in
                        let groupMatches = visibleMatches.filter { $0.league.group == group }
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

    private var visibleMatches: [Match] {
        guard let sport = selectedSport else { return displayedMatches }
        return displayedMatches.filter { $0.league.group == sport }
    }

    @ViewBuilder
    private var sportNavigator: some View {
        let sports = groupedSports
        if sports.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    sportNavChip(nil, label: "All")
                    ForEach(sports, id: \.self) { sport in
                        sportNavChip(sport, label: sport.rawValue)
                    }
                }
            }
        }
    }

    private func sportNavChip(_ sport: SportGroup?, label: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy) { selectedSport = sport }
        } label: {
            HStack(spacing: 4) {
                if let sport {
                    Image(systemName: sport.systemImage)
                        .font(.caption2.weight(.bold))
                }
                Text(label)
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(selectedSport == sport ? .white : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selectedSport == sport ? Theme.accent.opacity(0.9) : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(selectedSport == sport ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
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
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy) { filter = f }
        } label: {
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
            let favoriteMatches = viewModel.allLive.filter { involvesFavorite($0, favIDs: favIDs, favNames: favNames) }
            let fantasyMatches = viewModel.allLive.filter { !liveFantasyContext(for: $0).isEmpty }
            let personalized = mergedMatches(favoriteMatches + fantasyMatches)
            base = personalized.isEmpty ? viewModel.allLive : personalized.sorted { relevanceScore($0, favIDs: favIDs, favNames: favNames) > relevanceScore($1, favIDs: favIDs, favNames: favNames) }
        case .all:
            base = viewModel.allLive
        case .guide:
            return []
        }
        return base.filter { !hiddenMatchIDs.contains($0.id) }
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
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text("\(matches.count) LIVE")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.live)

            ForEach(matches) { match in
                NavigationLink(value: match) {
                    LiveMatchCard(
                        match: match,
                        onSetAlert: { Task { await setAlert(for: match) } },
                        onAddToCalendar: { Task { await addToCalendar(match) } },
                        onHide: { hide(match) },
                        showScoreBar: prefs.showLiveScoreBar
                    )
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
                    .font(.footnote.weight(.semibold))
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

            if filter == .forYou {
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

    private func liveFantasyContext(for match: Match) -> [FantasyPlayerGame] {
        guard fantasyStore.settings.showFantasyIndicatorsInLive else { return [] }
        return fantasyStore.fantasyEventContext(for: match)?.playerGames ?? []
    }

    private func mergedMatches(_ matches: [Match]) -> [Match] {
        var seen: Set<String> = []
        var merged: [Match] = []
        for match in matches where seen.insert(match.id).inserted {
            merged.append(match)
        }
        return merged
    }

    private func relevanceScore(_ match: Match, favIDs: Set<String>, favNames: Set<String>) -> Int {
        var score = 0
        if involvesFavorite(match, favIDs: favIDs, favNames: favNames) { score += 100 }
        let fantasyContext = liveFantasyContext(for: match)
        score += min(fantasyContext.filter(\.isFantasyStarter).count, 3) * 35
        score += min(fantasyContext.filter(\.isFantasyBench).count, 3) * 15
        score += min(fantasyContext.filter { !$0.isFantasyStarter && !$0.isFantasyBench }.count, 2) * 10
        if isClose(match) { score += 10 }
        return score
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
        case .golf, .racing, .tennis, .cycling, .wrestling, .esports: return false
        }
    }

    private func countdown(to date: Date) -> String {
        let secs = max(0, Int(date.timeIntervalSinceNow))
        let h = secs / 3600; let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }

    private func setAlert(for match: Match) async {
        let scheduled = await MatchNotificationService.shared.scheduleReminder(for: match, leadTime: prefs.matchReminderLeadTime)
        prefs.setMatchNotificationsEnabled(scheduled)
        actionAlertMessage = scheduled
            ? (match.state == .live ? "Live alert sent for \(match.shortName)." : "Alert set for \(match.shortName).")
            : (match.state == .final ? "\(match.shortName) is already final." : "Notifications are disabled. Enable them in Settings to receive game alerts.")
        showingActionAlert = true
    }

    private func addToCalendar(_ match: Match) async {
        #if canImport(EventKit)
        do {
            let saved = try await MatchCalendarService.shared.add(matches: [match])
            actionAlertMessage = saved == 1 ? "Added \(match.shortName) to Calendar." : "No calendar event was added."
        } catch {
            actionAlertMessage = error.localizedDescription
        }
        #else
        actionAlertMessage = "Calendar export is not available on this device."
        #endif
        showingActionAlert = true
    }

    private func hide(_ match: Match) {
        hiddenMatchIDs.insert(match.id)
    }
}

// MARK: - Live Match Card

struct LiveMatchCard: View {
    let match: Match
    let onSetAlert: () -> Void
    let onAddToCalendar: () -> Void
    let onHide: () -> Void
    var showScoreBar: Bool = false
    var fantasyContext: [FantasyPlayerGame] = []

    private var fantasyLabel: String? {
        guard !fantasyContext.isEmpty else { return nil }
        if fantasyContext.count == 1, let player = fantasyContext.first {
            return "★ \(player.fantasyPlayer.fullName)"
        }
        return "★ \(fantasyContext.count) Fantasy players"
    }

    private var intelligenceLabel: String? {
        guard match.state == .live,
              let h = match.home.score.flatMap(Int.init),
              let a = match.away.score.flatMap(Int.init) else { return nil }
        let diff = abs(h - a)
        let status = match.statusDetail.lowercased()
        switch match.league.group {
        case .baseball:
            if ["10th","11th","12th","13th","14th","15th","extra"].contains(where: { status.contains($0) }) { return "EXTRA INNINGS" }
            if diff == 0 { return "TIED" }
            if diff == 1 { return "ONE-RUN GAME" }
        case .basketball:
            if status.contains("ot") { return "OVERTIME" }
            if diff <= 5 { return "CLOSE GAME" }
        case .hockey:
            if status.contains("ot") { return "OVERTIME" }
            if diff == 0 { return "TIED" }
            if diff <= 1 { return "ONE-GOAL GAME" }
        case .soccer:
            if diff == 0 { return "LEVEL" }
            if diff <= 1 { return "CLOSE MATCH" }
        case .football:
            if status.contains("ot") { return "OVERTIME" }
            if diff <= 3 { return "FIELD GOAL GAME" }
            if diff <= 8 { return "ONE-SCORE GAME" }
        default: break
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PulsingLiveBadge()
                Text(match.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                if let label = intelligenceLabel {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Text(label)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.starting)
                }
                if let fantasyLabel {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Text(fantasyLabel)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                Spacer()
                Text(match.statusDetail)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.live)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    TeamLogo(url: match.away.logoURL, size: 36)
                    Text(match.away.shortName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(match.away.score ?? "-")
                    Text("–").foregroundStyle(Theme.textSecondary)
                    Text(match.home.score ?? "-")
                }
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 8) {
                    Text(match.home.shortName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    TeamLogo(url: match.home.logoURL, size: 36)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .overlay(alignment: .top) {
            if showScoreBar {
                Rectangle()
                    .fill(Theme.live)
                    .frame(height: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .contextMenu {
            Button("Add to Calendar", systemImage: "calendar.badge.plus") { onAddToCalendar() }
            Divider()
            Button("Hide", systemImage: "eye.slash", role: .destructive) { onHide() }
        }
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
    case all    = "all"
    case guide  = "guide"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forYou: return "For You"
        case .all:    return "All Live"
        case .guide:  return "Guide"
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
    private var refreshClientCount = 0

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
        refreshClientCount += 1
        guard refreshClientCount == 1 else { return }
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
        refreshClientCount = max(0, refreshClientCount - 1)
        guard refreshClientCount == 0 else { return }
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
