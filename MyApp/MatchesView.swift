import SwiftUI

// MARK: - Entity filter

private enum FollowingMode: String, CaseIterable, Identifiable {
    case following = "Following"
    case fantasy = "Fantasy"
    var id: String { rawValue }
}

private enum FollowingSelection: Hashable {
    case all
    case team(FavoriteTeam)
    case league(League)

    var id: String {
        switch self {
        case .all: return "all"
        case .team(let t): return "team-\(t.id)"
        case .league(let l): return "league-\(l.id)"
        }
    }
}

// MARK: - Main view

struct MatchesView: View {
    @StateObject private var viewModel = MatchesViewModel()
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var predictions: PredictionsStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var playlists: PlaylistStore

    @State private var mode: FollowingMode = .following
    @State private var selectedSelection: FollowingSelection = .all
    @State private var comingUpSportFilter: SportGroup? = nil
    @State private var showingTeamEditor = false
    @State private var hiddenMatchIDs: Set<String> = []
    @State private var remindedMatchIDs: Set<String> = []
    @State private var news: [ESPNArticle] = []
    @State private var newsLoading = false
    @State private var notificationAlertMessage = ""
    @State private var showingNotificationAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: Match.self) { MatchDetailView(match: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if mode == .following {
                        Button("Edit") { showingTeamEditor = true }
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .sheet(isPresented: $showingTeamEditor) { TeamEditorView() }
            .alert("Notifications", isPresented: $showingNotificationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notificationAlertMessage)
            }
        }
        .tint(Theme.accent)
        .task(id: loadKey) { await loadAll() }
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
        .onChange(of: prefs.favoriteTeams) { _, _ in
            withAnimation(.snappy) { selectedSelection = .all }
        }
    }

    private var loadKey: String {
        [
            prefs.explicitlyFollowedLeagues.map(\.id).sorted().joined(separator: ","),
            prefs.favoriteTeams.map(\.id).sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    private func loadAll() async {
        async let newsTask: Void = loadNews()
        await viewModel.loadFollowing(leagues: prefs.explicitlyFollowedLeagues, favorites: prefs.favoriteTeams)
        predictions.resolveAll(from: viewModel.allFollowedMatches)
        await newsTask
        if prefs.matchNotificationsEnabled {
            await MatchNotificationService.shared.syncNotifications(
                matches: viewModel.allFollowedMatches,
                favorites: prefs.favoriteTeams,
                leadTime: prefs.matchReminderLeadTime
            )
        }
    }

    private func loadNews() async {
        newsLoading = true
        var articles: [ESPNArticle] = []
        await withTaskGroup(of: [ESPNArticle].self) { group in
            for league in newsLeagues.prefix(5) {
                group.addTask { (try? await SportsRepository.shared.legacyNews(for: league, limit: 5)) ?? [] }
            }
            for await batch in group { articles.append(contentsOf: batch) }
        }
        news = Array(
            articles
                .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
                .prefix(8)
        )
        newsLoading = false
    }

    // MARK: Content routing

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            modeSwitch
            if mode == .fantasy {
                FantasyDashboardView()
            } else if prefs.favoriteTeams.isEmpty && prefs.explicitlyFollowedLeagues.isEmpty {
                FollowingEmptyStateView { showingTeamEditor = true }
            } else if viewModel.isLoadingFollowing && viewModel.allFollowedMatches.isEmpty {
                FollowingSkeletonView()
            } else {
                mainScroll
            }
        }
        .animation(.snappy, value: mode)
    }

    private var modeSwitch: some View {
        Picker("Following mode", selection: $mode) {
            ForEach(FollowingMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.background)
        .onChange(of: mode) { _, newMode in
            guard newMode == .fantasy else { return }
            Task { await fantasyStore.refresh(channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages) }
        }
    }

    private var mainScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                entitySelector
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                FollowingSportsSummary(
                    liveCount: liveMatches.count,
                    todayCount: todayMatches.count,
                    thisWeekCount: thisWeekMatches.count,
                    nextUpcoming: nextUpcoming
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                heroSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)

                FollowingComingUpSection(
                    matches: comingUpPreviewMatches,
                    fullScheduleMatches: comingUpMatches,
                    sportFilter: $comingUpSportFilter,
                    availableSports: comingUpAvailableSports
                )
                .padding(.bottom, 28)

                if !news.isEmpty || newsLoading {
                    FollowingNewsSection(articles: news, isLoading: newsLoading)
                        .padding(.bottom, 28)
                }

                FollowingStandingsSnapshot(
                    selection: selectedSelection,
                    favoriteTeams: prefs.favoriteTeams
                )
                .padding(.horizontal, 20)

                Spacer(minLength: 120)
            }
        }
        .refreshable { await loadAll() }
    }

    // MARK: Entity selector

    private var entitySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                entityChip(title: "All", logoURL: nil, isSelected: selectedSelection == .all) {
                    withAnimation(.snappy) { selectedSelection = .all }
                }
                ForEach(prefs.favoriteTeams) { team in
                    let abbr = team.abbreviation.isEmpty
                        ? String(team.displayName.prefix(3)).uppercased()
                        : team.abbreviation
                    entityChip(
                        title: abbr, logoURL: team.logoURL,
                        isSelected: selectedSelection == .team(team)
                    ) {
                        withAnimation(.snappy) { selectedSelection = .team(team) }
                    }
                }
                ForEach(leagueChips) { league in
                    entityChip(
                        title: league.shortName, logoURL: nil,
                        isSelected: selectedSelection == .league(league)
                    ) {
                        withAnimation(.snappy) { selectedSelection = .league(league) }
                    }
                }
                Button { showingTeamEditor = true } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage following")
            }
            .padding(.horizontal, 20)
        }
    }

    private var leagueChips: [League] {
        let favLeagueIDs = Set(prefs.favoriteTeams.map(\.leaguePath))
        return League.all.filter {
            prefs.isLeagueSelected($0) && !favLeagueIDs.contains($0.id)
        }.prefix(6).map { $0 }
    }

    private func entityChip(
        title: String, logoURL: URL?, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 5) {
                if let logoURL { TeamLogo(url: logoURL, size: 18) }
                Text(title)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, logoURL == nil ? 12 : 8)
            .frame(height: 32)
            .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Theme.accent.opacity(0.4) : Theme.hairline))
            .shadow(color: isSelected ? Theme.accent.opacity(0.28) : .clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: Hero

    @ViewBuilder
    private var heroSection: some View {
        if let live = liveMatches.first {
            FollowingLiveHero(match: live)
        } else if let next = nextUpcoming {
            FollowingUpNextHero(
                match: next,
                isReminderSet: remindedMatchIDs.contains(next.id),
                onRemind: { Task { await toggleReminder(for: next) } }
            )
        } else if !viewModel.isLoadingFollowing {
            FollowingNoEventsCard()
        }
    }

    // MARK: Derived data

    private var selectedMatches: [Match] {
        switch selectedSelection {
        case .all: return viewModel.allFollowedMatches
        case .team(let t): return viewModel.allFollowedMatches.filter { matchIncludes($0, team: t) }
        case .league(let l): return viewModel.allFollowedMatches.filter { $0.league.id == l.id }
        }
    }

    private var visibleMatches: [Match] {
        selectedMatches.filter { !hiddenMatchIDs.contains($0.id) }
    }

    private var liveMatches: [Match] { visibleMatches.filter { $0.state == .live } }

    private var todayMatches: [Match] {
        visibleMatches.filter { Calendar.current.isDateInToday($0.date) && $0.state != .final }
    }

    private var thisWeekMatches: [Match] {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return visibleMatches.filter { $0.state == .pre && $0.date >= Date() && $0.date <= end }
    }

    private var nextUpcoming: Match? {
        visibleMatches
            .filter { $0.state == .pre && $0.date >= Date() && !isTBDMatch($0) }
            .min(by: { $0.date < $1.date })
    }

    private var comingUpMatches: [Match] {
        var result = visibleMatches.filter { $0.state == .pre && $0.date >= Date() && !isTBDMatch($0) }
        if let filter = comingUpSportFilter {
            result = result.filter { $0.league.group == filter }
        }
        return result.sorted { $0.date < $1.date }
    }

    private var comingUpPreviewMatches: [Match] {
        Array(comingUpMatches.prefix(6))
    }

    private var comingUpAvailableSports: [SportGroup] {
        var seen = Set<SportGroup>()
        return visibleMatches
            .filter { $0.state == .pre && $0.date >= Date() && !isTBDMatch($0) }
            .compactMap { seen.insert($0.league.group).inserted ? $0.league.group : nil }
    }

    private var newsLeagues: [League] {
        let favPaths = Set(prefs.favoriteTeams.map(\.leaguePath))
        let explicitIDs = Set(prefs.explicitlyFollowedLeagues.map(\.id))
        return League.all.filter { favPaths.contains($0.id) || explicitIDs.contains($0.id) }
    }

    private func isTBDMatch(_ match: Match) -> Bool {
        let a = match.away.displayName.lowercased().trimmingCharacters(in: .whitespaces)
        let h = match.home.displayName.lowercased().trimmingCharacters(in: .whitespaces)
        return (a == "tbd" || a.isEmpty) && (h == "tbd" || h.isEmpty)
    }

    private func matchIncludes(_ match: Match, team: FavoriteTeam) -> Bool {
        guard match.league.path == team.leaguePath else { return false }
        return [match.home, match.away].contains { side in
            if let tid = side.teamID, !tid.isEmpty, !team.teamID.isEmpty, tid == team.teamID {
                return true
            }
            if let canonicalID = side.canonicalIDString, canonicalID == team.canonicalTeamID {
                return true
            }
            let sideNames = [side.displayName, side.shortName, side.abbreviation]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            let favNames = [team.displayName, team.abbreviation]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return sideNames.contains { s in favNames.contains { f in s == f } }
        }
    }

    private func toggleReminder(for match: Match) async {
        if remindedMatchIDs.contains(match.id) {
            remindedMatchIDs.remove(match.id)
            return
        }
        let scheduled = await MatchNotificationService.shared.scheduleReminder(
            for: match, leadTime: prefs.matchReminderLeadTime
        )
        if scheduled {
            remindedMatchIDs.insert(match.id)
        } else {
            notificationAlertMessage = "Notifications are disabled. Enable them in Settings to receive game alerts."
            showingNotificationAlert = true
        }
        prefs.setMatchNotificationsEnabled(scheduled)
    }
}

// MARK: - YOUR SPORTS summary

private struct FollowingSportsSummary: View {
    let liveCount: Int
    let todayCount: Int
    let thisWeekCount: Int
    let nextUpcoming: Match?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR SPORTS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.5)

            HStack(spacing: 0) {
                statItem(
                    icon: liveCount > 0 ? "circle.fill" : "circle",
                    value: "\(liveCount)", label: "Live",
                    tint: liveCount > 0 ? Theme.live : Theme.textTertiary,
                    prominent: liveCount > 0
                )
                divider
                statItem(icon: "calendar", value: "\(todayCount)", label: "Today",
                         tint: Theme.upcoming, prominent: false)
                divider
                statItem(icon: "bell", value: "\(thisWeekCount)", label: "This Week",
                         tint: Theme.starting, prominent: false)
                Spacer()
            }

            if liveCount == 0, todayCount == 0, let next = nextUpcoming {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing today")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(nextLine(next))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 16)
    }

    private func statItem(icon: String, value: String, label: String,
                          tint: Color, prominent: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(prominent ? tint : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(prominent ? tint : Theme.textPrimary)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func nextLine(_ match: Match) -> String {
        let name = match.league.group == .racing
            ? match.name
            : "\(match.away.shortName) vs \(match.home.shortName)"
        return "\(name) · \(match.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Live hero

private struct FollowingLiveHero: View {
    let match: Match

    private var isRacing: Bool { match.league.group == .racing }

    var body: some View {
        NavigationLink(value: match) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    HStack(spacing: 6) {
                        PulsingLiveBadge()
                        Text("LIVE")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.live)
                            .tracking(1.5)
                    }
                    Spacer()
                    Text(match.league.shortName.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(0.5)
                }

                if isRacing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(match.name)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(match.statusDetail)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.live)
                        if let venue = match.venue, !venue.isEmpty {
                            Text(venue)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        VStack(spacing: 8) {
                            TeamLogo(url: match.away.logoURL, size: 54)
                            Text(match.away.shortName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(spacing: 4) {
                            HStack(spacing: 10) {
                                Text(match.away.score ?? "-")
                                Text("–").foregroundStyle(Theme.textTertiary)
                                Text(match.home.score ?? "-")
                            }
                            .font(.system(size: 36, weight: .black, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)

                            Text(match.statusDetail)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.live)
                                .lineLimit(1)
                        }

                        VStack(spacing: 8) {
                            TeamLogo(url: match.home.logoURL, size: 54)
                            Text(match.home.shortName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                Text("Open \(isRacing ? "Event" : "Game") Centre →")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.live.opacity(0.75))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LinearGradient(
                                stops: [.init(color: Theme.live.opacity(0.14), location: 0),
                                        .init(color: .clear, location: 0.65)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.live.opacity(0.22))
            )
            .shadow(color: Theme.live.opacity(0.18), radius: 28, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if isRacing {
            return "\(match.name), live. \(match.statusDetail). Opens Event Centre."
        }
        return "\(match.away.displayName) \(match.away.score ?? "") versus \(match.home.displayName) \(match.home.score ?? ""), \(match.statusDetail). Opens Game Centre."
    }
}

// MARK: - Up Next hero

private struct FollowingUpNextHero: View {
    let match: Match
    let isReminderSet: Bool
    let onRemind: () -> Void

    private var isRacing: Bool { match.league.group == .racing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("UP NEXT")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                    .tracking(1.5)
                Spacer()
                Text(match.league.shortName.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
            }

            if isRacing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(match.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                    if !match.statusDetail.isEmpty, !match.statusDetail.lowercased().contains("tbd") {
                        Text(match.statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 0) {
                    VStack(spacing: 10) {
                        TeamLogo(url: match.away.logoURL, size: 60)
                        Text(match.away.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)

                    Text("VS")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(1)
                        .padding(.horizontal, 4)

                    VStack(spacing: 10) {
                        TeamLogo(url: match.home.logoURL, size: 60)
                        Text(match.home.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(friendlyDate)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let venue = match.venue, !venue.isEmpty {
                    Text(venue)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text(countdown)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 10) {
                NavigationLink(value: match) {
                    Text(isRacing ? "Event Centre" : "Game Centre")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onRemind) {
                    HStack(spacing: 6) {
                        Image(systemName: isReminderSet ? "bell.fill" : "bell")
                            .font(.caption.weight(.bold))
                        Text(isReminderSet ? "Reminder Set" : "Remind Me")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(isReminderSet ? Theme.starting : Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        isReminderSet ? Theme.starting.opacity(0.12) : Theme.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isReminderSet ? Theme.starting.opacity(0.3) : Theme.hairline)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(
                            stops: [.init(color: Theme.accent.opacity(0.07), location: 0),
                                    .init(color: .clear, location: 0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: Color.black.opacity(0.14), radius: 22, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var friendlyDate: String {
        let cal = Calendar.current
        let time = match.date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(match.date) { return "Today · \(time)" }
        if cal.isDateInTomorrow(match.date) { return "Tomorrow · \(time)" }
        let weekday = match.date.formatted(.dateTime.weekday(.wide)).uppercased()
        return "\(weekday) · \(time)"
    }

    private var countdown: String {
        let s = max(0, match.date.timeIntervalSinceNow)
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 1 { return "Starts in \(d) days" }
        if d == 1 { return "Starts tomorrow" }
        if h > 0 { return "Starts in \(h)h \(m)m" }
        if m > 0 { return "Starts in \(m) min" }
        return "Starting soon"
    }

    private var accessibilityLabel: String {
        if isRacing {
            return "\(match.name), \(friendlyDate). \(countdown)."
        }
        return "\(match.away.displayName) versus \(match.home.displayName), \(friendlyDate). \(countdown). Opens Game Centre."
    }
}

// MARK: - No events card

private struct FollowingNoEventsCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
            Text("Nothing scheduled yet")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Upcoming events will appear here as soon as schedules are available.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Coming Up section

private struct FollowingComingUpSection: View {
    let matches: [Match]
    let fullScheduleMatches: [Match]
    @Binding var sportFilter: SportGroup?
    let availableSports: [SportGroup]

    private struct DateGroup: Identifiable {
        let title: String
        let sortDate: Date
        let matches: [Match]
        var id: String { title }
    }

    private func dateGroupKey(for match: Match) -> (title: String, sortDate: Date) {
        let cal = Calendar.current
        if cal.isDateInToday(match.date) {
            return ("TODAY", cal.startOfDay(for: Date()))
        }
        if cal.isDateInTomorrow(match.date) {
            return ("TOMORROW", cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? match.date)
        }
        let weekday = match.date.formatted(.dateTime.weekday(.wide)).uppercased()
        let month = match.date.formatted(.dateTime.month(.abbreviated)).uppercased()
        let day = cal.component(.day, from: match.date)
        return ("\(weekday) · \(month) \(day)", cal.startOfDay(for: match.date))
    }

    private var dateGroups: [DateGroup] {
        var keyOrder: [String] = []
        var byKey: [String: (sortDate: Date, matches: [Match])] = [:]
        for match in matches {
            let (title, sortDate) = dateGroupKey(for: match)
            if byKey[title] == nil {
                byKey[title] = (sortDate, [])
                keyOrder.append(title)
            }
            byKey[title]!.matches.append(match)
        }
        return keyOrder.compactMap { key -> DateGroup? in
            guard let v = byKey[key] else { return nil }
            return DateGroup(title: key, sortDate: v.sortDate, matches: v.matches.sorted { $0.date < $1.date })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("COMING UP")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                Spacer()
                if availableSports.count > 1 { sportFilterMenu }
            }
            .padding(.horizontal, 20)

            if matches.isEmpty {
                Text("No upcoming events scheduled.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
            } else {
                ForEach(dateGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.textSecondary)
                            .tracking(0.5)
                            .padding(.horizontal, 20)
                        ForEach(group.matches) { match in
                            NavigationLink(value: match) {
                                FollowingEventRow(match: match)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 10)
                }

                NavigationLink {
                    FollowingFullScheduleView(
                        matches: fullScheduleMatches,
                        availableSports: availableSports,
                        initialSportFilter: sportFilter
                    )
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("View Full Schedule")
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sportFilterMenu: some View {
        Menu {
            Button {
                withAnimation(.snappy) { sportFilter = nil }
            } label: {
                if sportFilter == nil { Label("All Sports", systemImage: "checkmark") }
                else { Text("All Sports") }
            }
            ForEach(availableSports, id: \.self) { sport in
                Button {
                    withAnimation(.snappy) { sportFilter = sport }
                } label: {
                    if sportFilter == sport { Label(sport.rawValue, systemImage: "checkmark") }
                    else { Text(sport.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sportFilter?.rawValue ?? "All Sports")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surfaceElevated, in: Capsule())
        }
    }
}

// MARK: - Full schedule

private struct FollowingFullScheduleView: View {
    let matches: [Match]
    let availableSports: [SportGroup]
    @State private var sportFilter: SportGroup?

    init(matches: [Match], availableSports: [SportGroup], initialSportFilter: SportGroup?) {
        self.matches = matches
        self.availableSports = availableSports
        _sportFilter = State(initialValue: initialSportFilter)
    }

    private struct DateGroup: Identifiable {
        let title: String
        let matches: [Match]
        var id: String { title }
    }

    private var filteredMatches: [Match] {
        guard let sportFilter else { return matches }
        return matches.filter { $0.league.group == sportFilter }
    }

    private var dateGroups: [DateGroup] {
        var order: [String] = []
        var byTitle: [String: [Match]] = [:]
        for match in filteredMatches.sorted(by: { $0.date < $1.date }) {
            let title = dateGroupTitle(for: match)
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(match)
        }
        return order.compactMap { title in
            guard let matches = byTitle[title] else { return nil }
            return DateGroup(title: title, matches: matches)
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("COMING UP")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.textSecondary)
                            .tracking(0.5)
                        Spacer()
                        if availableSports.count > 1 { sportFilterMenu }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    if filteredMatches.isEmpty {
                        Text("No upcoming events scheduled.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 20)
                    } else {
                        ForEach(dateGroups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title)
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(Theme.textSecondary)
                                    .tracking(0.5)
                                    .padding(.horizontal, 20)
                                ForEach(group.matches) { match in
                                    NavigationLink(value: match) {
                                        FollowingEventRow(match: match)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 20)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 120)
            }
        }
        .navigationTitle("Full Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var sportFilterMenu: some View {
        Menu {
            Button { sportFilter = nil } label: {
                if sportFilter == nil { Label("All Sports", systemImage: "checkmark") }
                else { Text("All Sports") }
            }
            ForEach(availableSports, id: \.self) { sport in
                Button { sportFilter = sport } label: {
                    if sportFilter == sport { Label(sport.rawValue, systemImage: "checkmark") }
                    else { Text(sport.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sportFilter?.rawValue ?? "All Sports")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surfaceElevated, in: Capsule())
        }
    }

    private func dateGroupTitle(for match: Match) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(match.date) { return "TODAY" }
        if calendar.isDateInTomorrow(match.date) { return "TOMORROW" }
        let weekday = match.date.formatted(.dateTime.weekday(.wide)).uppercased()
        let month = match.date.formatted(.dateTime.month(.abbreviated)).uppercased()
        return "\(weekday) · \(month) \(calendar.component(.day, from: match.date))"
    }
}

// MARK: - Event row

private struct FollowingEventRow: View {
    let match: Match

    private var isRacing: Bool { match.league.group == .racing }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: match.league.group.systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textTertiary)
                .frame(width: 18, alignment: .center)

            if isRacing {
                Text(cleanTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 7) {
                    TeamLogo(url: match.away.logoURL, size: 20)
                    Text(cleanTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if match.state == .live {
                    HStack(spacing: 4) {
                        PulsingLiveBadge()
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.live)
                    }
                } else {
                    Text(match.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens \(isRacing ? "Event" : "Game") Centre")
    }

    private var cleanTitle: String {
        if isRacing { return match.name }
        let a = match.away.shortName, h = match.home.shortName
        guard !a.lowercased().contains("tbd"), !h.lowercased().contains("tbd"),
              !a.isEmpty, !h.isEmpty else { return match.name }
        return "\(a) vs \(h)"
    }

    private var accessibilityText: String {
        if isRacing {
            return "\(match.name), \(match.date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(match.away.displayName) versus \(match.home.displayName), \(match.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - News section

private struct FollowingNewsSection: View {
    let articles: [ESPNArticle]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FROM YOUR TEAMS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.5)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if isLoading && articles.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in newsPlaceholder }
                    } else {
                        ForEach(articles.prefix(6)) { FollowingNewsCard(article: $0) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var newsPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.surface)
            .frame(width: 200, height: 170)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct FollowingNewsCard: View {
    let article: ESPNArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: article.imageURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(Theme.surfaceElevated)
                        .overlay(
                            Image(systemName: "newspaper")
                                .font(.title3)
                                .foregroundStyle(Theme.textTertiary.opacity(0.4))
                        )
                }
            }
            .frame(height: 90)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(article.league.shortName.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    if let pub = article.published {
                        Text("·").font(.caption2).foregroundStyle(Theme.textTertiary)
                        Text(relTime(pub)).font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(article.headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
        .frame(width: Theme.isPad ? 260 : 200)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func relTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

// MARK: - Standings snapshot

private struct FollowingStandingsSnapshot: View {
    let selection: FollowingSelection
    let favoriteTeams: [FavoriteTeam]

    var body: some View {
        Group {
            switch selection {
            case .all:
                if let team = favoriteTeams.first,
                   let league = League.all.first(where: { $0.path == team.leaguePath }),
                   supported(league) {
                    standingsBlock(league: league, highlightTeamID: team.teamID)
                }
            case .team(let team):
                if let league = League.all.first(where: { $0.path == team.leaguePath }),
                   supported(league) {
                    standingsBlock(league: league, highlightTeamID: team.teamID)
                }
            case .league(let league):
                if supported(league) {
                    standingsBlock(league: league, highlightTeamID: nil)
                }
            }
        }
    }

    private func supported(_ league: League) -> Bool {
        league.group != .tennis && league.group != .golf
    }

    private func standingsBlock(league: League, highlightTeamID: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR STANDINGS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.5)
            FollowingStandingsPanelView(league: league, highlightTeamID: highlightTeamID)
        }
    }
}

private struct FollowingStandingsPanelView: View {
    let league: League
    var highlightTeamID: String?

    @State private var groups: [StandingsGroup] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading && groups.isEmpty {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if groups.isEmpty {
                Text("Standings not available right now.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).padding(.vertical, 8)
            } else {
                ForEach(relevantGroups.prefix(1)) { group in
                    standingsCard(for: group)
                }
            }
        }
        .task(id: league.id) {
            isLoading = true
            groups = (try? await SportsRepository.shared.legacyStandings(for: league)) ?? []
            isLoading = false
        }
    }

    private var relevantGroups: [StandingsGroup] {
        guard let tid = highlightTeamID else { return groups }
        let containing = groups.filter { $0.rows.contains { $0.teamID == tid } }
        return containing.isEmpty ? groups : containing
    }

    private func standingsCard(for group: StandingsGroup) -> some View {
        let rows = contextRows(group: group)
        return VStack(alignment: .leading, spacing: 8) {
            Text(group.name.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.5)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    let rank = rankOf(row, in: group)
                    let hi = row.teamID == highlightTeamID
                    HStack(spacing: 10) {
                        Text("\(rank)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(hi ? Theme.accent : Theme.textSecondary)
                            .frame(width: 22, alignment: .trailing)
                        TeamLogo(url: row.logoURL, size: 20)
                        Text(row.abbreviation.isEmpty ? row.displayName : row.abbreviation)
                            .font(.caption.weight(hi ? .heavy : .semibold))
                            .foregroundStyle(hi ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(primaryStat(row))
                            .font(.caption.weight(hi ? .heavy : .regular).monospacedDigit())
                            .foregroundStyle(hi ? Theme.textPrimary : Theme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(hi ? Theme.accent.opacity(0.09) : Color.clear)
                    if idx < rows.count - 1 {
                        Divider().overlay(Theme.hairline).padding(.leading, 44)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
        .padding(.bottom, 24)
    }

    private func contextRows(group: StandingsGroup) -> [StandingRow] {
        guard let tid = highlightTeamID,
              let idx = group.rows.firstIndex(where: { $0.teamID == tid }) else {
            return Array(group.rows.prefix(5))
        }
        let start = max(0, idx - 2)
        let end = min(group.rows.count, max(start + 5, idx + 3))
        return Array(group.rows[start..<end])
    }

    private func rankOf(_ row: StandingRow, in group: StandingsGroup) -> Int {
        (group.rows.firstIndex(where: { $0.teamID == row.teamID }) ?? 0) + 1
    }

    private func primaryStat(_ row: StandingRow) -> String {
        if let pts = row.leaguePoints, !pts.isEmpty { return pts }
        return row.record
    }
}

// MARK: - Empty state

private struct FollowingEmptyStateView: View {
    let onChooseTeams: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "star.circle")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(Theme.accent.opacity(0.65))
                Text("Build your sports feed")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Follow your favourite teams and leagues to see upcoming games, live events, scores and news here.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 36)

            Button(action: onChooseTeams) {
                Text("Choose Teams & Leagues")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Skeleton

private struct FollowingSkeletonView: View {
    @State private var phase: Double = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule().fill(Theme.surface).frame(width: 56, height: 32)
                            .opacity(0.4 + 0.6 * phase)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12)

                HStack(spacing: 20) {
                    ForEach(0..<3, id: \.self) { _ in
                        skeletonRect(h: 42).frame(maxWidth: .infinity)
                            .opacity(0.4 + 0.6 * phase)
                    }
                }
                .padding(.horizontal, 20)

                skeletonRect(h: 200)
                    .opacity(0.4 + 0.6 * phase)
                    .padding(.horizontal, 20)

                ForEach(0..<4, id: \.self) { _ in
                    skeletonRect(h: 50)
                        .opacity(0.4 + 0.6 * phase)
                        .padding(.horizontal, 20)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1 }
        }
    }

    private func skeletonRect(h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.surface)
            .frame(maxWidth: .infinity).frame(height: h)
    }
}

// MARK: - Shared components (referenced from other files)

/// A named row in a match list with home and away teams and optional score.
struct MatchRow: View {
    let match: Match
    @EnvironmentObject private var prefs: PreferencesStore

    private var spoilersHidden: Bool { prefs.spoilerFreeMode && match.state == .final }

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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    Text(record).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
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
                    .lineLimit(1).minimumScaleFactor(0.75)
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

/// A pick prediction result card.
struct PickResultCard: View {
    let prediction: Prediction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon).font(.caption.weight(.bold)).foregroundStyle(statusColor)
                Text(prediction.leagueName)
                    .font(.caption2.weight(.heavy)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.4))
            }
            Text(prediction.awayTeamName)
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text("vs \(prediction.homeTeamName)")
                .font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: prediction.pick.systemImage).font(.caption2.weight(.bold))
                Text(prediction.pick.label(away: prediction.awayTeamName, home: prediction.homeTeamName))
                    .font(.caption2.weight(.bold)).lineLimit(1)
            }
            .foregroundStyle(pickColor)
        }
        .padding(12)
        .frame(width: 160, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(borderColor))
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

/// Loads a team logo with a fallback shield placeholder.
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
                    .foregroundStyle(Theme.textSecondary.opacity(0.4))
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
    }
}
