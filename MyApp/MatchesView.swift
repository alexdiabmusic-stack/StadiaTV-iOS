import SwiftUI

private enum FollowingSelection: Hashable {
    case all
    case team(FavoriteTeam)
    case league(League)

    var id: String {
        switch self {
        case .all: return "all"
        case .team(let team): return "team-\(team.id)"
        case .league(let league): return "league-\(league.id)"
        }
    }
}

private enum FollowingContentTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case games = "Games"
    case updates = "Updates"
    case standings = "Standings"

    var id: String { rawValue }
}

private enum DayFilter {
    case live, today, thisWeek
}

struct MatchesView: View {
    @StateObject private var viewModel = MatchesViewModel()
    @StateObject private var newsViewModel = NewsViewModel()
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var predictions: PredictionsStore
    @EnvironmentObject private var articleLibrary: ArticleLibraryStore
    @AppStorage("following.tab.v1") private var savedTabRaw: String = FollowingContentTab.overview.rawValue
    @State private var selectedSelection: FollowingSelection = .all
    @State private var selectedTab: FollowingContentTab = .overview
    @State private var selectedSport: SportGroup?
    @State private var showingTeamEditor = false
    @State private var presentedArticle: ESPNArticle?
    @State private var showingNotificationAlert = false
    @State private var notificationAlertMessage = ""
    @State private var hiddenMatchIDs: Set<String> = []
    @State private var dayFilter: DayFilter? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Following")
            .navigationDestination(for: Match.self) { MatchDetailView(match: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { showingTeamEditor = true }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .sheet(isPresented: $showingTeamEditor) { TeamEditorView() }
            .sheet(item: $presentedArticle) { article in
                ArticleReaderView(article: article)
            }
            .alert("Notifications", isPresented: $showingNotificationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notificationAlertMessage)
            }
        }
        .tint(Theme.accent)
        .task(id: loadKey) { await loadFollowing() }
        .onAppear {
            viewModel.startAutoRefresh()
            selectedTab = FollowingContentTab(rawValue: savedTabRaw) ?? .overview
        }
        .onChange(of: selectedTab) { _, new in savedTabRaw = new.rawValue }
        .onDisappear { viewModel.stopAutoRefresh() }
        .onChange(of: prefs.favoriteTeams) { _, _ in selectedSelection = .all }
    }

    private var loadKey: String {
        [
            prefs.followedLeagues.map(\.id).sorted().joined(separator: ","),
            prefs.favoriteTeams.map(\.id).sorted().joined(separator: ","),
            prefs.matchNotificationsEnabled ? "alerts-on" : "alerts-off",
            "lead-\(prefs.matchReminderLeadTime.rawValue)"
        ].joined(separator: "|")
    }

    private func loadFollowing() async {
        await viewModel.loadFollowing(leagues: prefs.followedLeagues, favorites: prefs.favoriteTeams)
        await newsViewModel.load(leagues: prefs.followedLeagues)
        predictions.resolveAll(from: viewModel.allFollowedMatches)
        if prefs.matchNotificationsEnabled {
            await MatchNotificationService.shared.syncNotifications(
                matches: viewModel.allFollowedMatches,
                favorites: prefs.favoriteTeams,
                leadTime: prefs.matchReminderLeadTime
            )
        }
    }

    @ViewBuilder private var content: some View {
        if viewModel.isLoadingFollowing && viewModel.allFollowedMatches.isEmpty && !prefs.favoriteTeams.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                Text("Building your following feed")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else if prefs.favoriteTeams.isEmpty {
            followingEmptyState
        } else {
            followingScroll
        }
    }

    private var followingScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                yourDaySection

                if let priorityMatch {
                    PriorityGameCard(
                        match: priorityMatch,
                        onSetAlert: { match in Task { await setAlert(for: match) } },
                        onAddToCalendar: { match in Task { await addToCalendar(match) } },
                        onHide: { match in hide(match) }
                    )
                }

                contentTabs
                sportFilters

                switch selectedTab {
                case .overview:
                    gamesSection(limit: 6)
                    latestSection(limit: 5)
                    standingsSection
                case .games:
                    gamesSection(limit: nil)
                case .updates:
                    latestSection(limit: nil)
                case .standings:
                    standingsSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .safeAreaInset(edge: .top) {
            personalizedHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .refreshable { await loadFollowing() }
    }

    private var personalizedHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                followChip(title: "All", logoURL: nil, isSelected: selectedSelection == .all) {
                    selectedSelection = .all
                }
                ForEach(prefs.favoriteTeams) { team in
                    followChip(title: team.abbreviation.isEmpty ? team.displayName : team.abbreviation,
                               logoURL: team.logoURL,
                               isSelected: selectedSelection == .team(team)) {
                        selectedSelection = .team(team)
                    }
                }
                ForEach(followedLeagueChips) { league in
                    followChip(title: league.shortName, logoURL: nil, isSelected: selectedSelection == .league(league)) {
                        selectedSelection = .league(league)
                    }
                }
                Button { showingTeamEditor = true } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add following")
            }
        }
    }

    private var followedLeagueChips: [League] {
        let favoriteLeagueIDs = Set(prefs.favoriteTeams.map(\.leaguePath))
        return prefs.followedLeagues.filter { favoriteLeagueIDs.contains($0.id) }.prefix(4).map { $0 }
    }

    private func followChip(title: String, logoURL: URL?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 7) {
                if let logoURL {
                    TeamLogo(url: logoURL, size: 22)
                }
                Text(title)
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, logoURL == nil ? 14 : 10)
            .frame(height: 38)
            .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Theme.accent.opacity(0.35) : Theme.hairline))
            .shadow(color: isSelected ? Theme.accent.opacity(0.28) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var yourDaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Your Day")
            HStack(spacing: 8) {
                Button { dayFilter = dayFilter == .live ? nil : .live } label: {
                    MetricCard(value: "\(liveMatches.count)", label: "Live", tint: Theme.live, icon: "circle.fill", isSelected: dayFilter == .live)
                }
                .buttonStyle(.plain)
                Button { dayFilter = dayFilter == .today ? nil : .today } label: {
                    MetricCard(value: "\(todayMatches.count)", label: "Today", tint: Theme.upcoming, icon: "calendar", isSelected: dayFilter == .today)
                }
                .buttonStyle(.plain)
                Button { dayFilter = dayFilter == .thisWeek ? nil : .thisWeek } label: {
                    MetricCard(value: "\(thisWeekMatches.count)", label: "This Week", tint: Theme.starting, icon: "bell", isSelected: dayFilter == .thisWeek)
                }
                .buttonStyle(.plain)
            }
            if todayMatches.isEmpty, let next = upcomingMatches.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No followed teams play today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(favoriteName(in: next))'s next game: \(shortDateTime(next.date)) · \(next.away.shortName) at \(next.home.shortName)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var contentTabs: some View {
        Picker("Content", selection: $selectedTab) {
            ForEach(FollowingContentTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    private var sportFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", isSelected: selectedSport == nil) { selectedSport = nil }
                ForEach(availableSports) { sport in
                    filterChip(title: sportLabel(sport), isSelected: selectedSport == sport) { selectedSport = sport }
                }
            }
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func gamesSection(limit: Int?) -> some View {
        let matches = limit.map { Array(filteredMatches.prefix($0)) } ?? filteredMatches
        if matches.isEmpty {
            EmptyInlineCard(title: "No games here yet", message: "Try another team, league or sport filter.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionTitle(selectedTab == .games ? "Schedule" : "Games")
                    Spacer()
                    Button { selectedTab = .games } label: {
                        Image(systemName: "calendar")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Open full schedule")
                }
                ForEach(periodGroups(for: matches)) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(group.matches) { match in
                            NavigationLink(value: match) {
                                CompactFollowingMatchRow(
                                    match: match,
                                    alertsEnabled: prefs.matchNotificationsEnabled,
                                    onSetAlert: { Task { await setAlert(for: match) } },
                                    onAddToCalendar: { Task { await addToCalendar(match) } },
                                    onHide: { hide(match) }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func latestSection(limit: Int?) -> some View {
        let updates = limit.map { Array(teamArticles.prefix($0)) } ?? teamArticles
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Latest From Your Teams")
                Spacer()
                if selectedTab == .overview {
                    Button { selectedTab = .updates } label: {
                        Image(systemName: "newspaper")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Open updates")
                }
            }
            if updates.isEmpty {
                EmptyInlineCard(title: "No updates loaded", message: "Pull to refresh for the latest stories from followed leagues.")
            } else {
                ForEach(updates) { article in
                    FollowingUpdateRow(
                        article: article,
                        isSaved: articleLibrary.isSaved(article),
                        action: { presentedArticle = article },
                        onToggleSaved: { articleLibrary.toggleSaved(article) },
                        onHide: { articleLibrary.hide(article) }
                    )
                }
            }
        }
    }

    private var standingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Standings")
            switch selectedSelection {
            case .team(let team):
                if let league = League.all.first(where: { $0.path == team.leaguePath }) {
                    FollowingStandingsPanel(league: league, highlightTeamID: team.teamID)
                } else {
                    EmptyInlineCard(title: "League not found", message: "Standings aren't available for this team.")
                }
            case .league(let league):
                FollowingStandingsPanel(league: league, highlightTeamID: nil)
            case .all:
                if prefs.favoriteTeams.isEmpty {
                    EmptyInlineCard(title: "No teams selected", message: "Choose teams to see standings context here.")
                } else {
                    ForEach(Array(prefs.favoriteTeams.prefix(4))) { team in
                        FollowingStandingCard(team: team, recentMatch: latestMatch(for: team))
                    }
                }
            }
        }
    }

    private var followingEmptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Build your sports feed")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Follow teams, leagues and players to see games, news, scores and personalized alerts.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 34)

            Button { showingTeamEditor = true } label: {
                Text("Choose Teams")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 10) {
                Text("Popular near you")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    ForEach(["OTT", "MTL", "TOR", "Jays"], id: \.self) { label in
                        Text(label)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline))
                    }
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func setAlert(for match: Match) async {
        let scheduled = await MatchNotificationService.shared.scheduleReminder(for: match, leadTime: prefs.matchReminderLeadTime)
        prefs.setMatchNotificationsEnabled(scheduled)
        notificationAlertMessage = scheduled
            ? (match.state == .live ? "Live alert sent for \(match.shortName)." : "Alert set for \(match.shortName).")
            : (match.state == .final ? "\(match.shortName) is already final." : "Notifications are disabled. Enable them in Settings to receive game alerts.")
        showingNotificationAlert = true
    }

    private func addToCalendar(_ match: Match) async {
        #if canImport(EventKit)
        do {
            let saved = try await MatchCalendarService.shared.add(matches: [match])
            notificationAlertMessage = saved == 1 ? "Added \(match.shortName) to Calendar." : "No calendar event was added."
        } catch {
            notificationAlertMessage = error.localizedDescription
        }
        #else
        notificationAlertMessage = "Calendar export is not available on this device."
        #endif
        showingNotificationAlert = true
    }

    private func hide(_ match: Match) {
        hiddenMatchIDs.insert(match.id)
    }

    private var selectedMatches: [Match] {
        switch selectedSelection {
        case .all:
            return viewModel.allFollowedMatches
        case .team(let team):
            return viewModel.allFollowedMatches.filter { matchIncludes($0, team: team) }
        case .league(let league):
            return viewModel.allFollowedMatches.filter { $0.league.id == league.id }
        }
    }

    // Base: selection + hidden + recency filters only — no sport chip or day filter.
    // Used for priority match and metric counts so those don't react to drill-down filters.
    private var filteredBaseMatches: [Match] {
        selectedMatches
            .filter { !hiddenMatchIDs.contains($0.id) }
            .filter { $0.state != .final || Calendar.current.dateComponents([.day], from: $0.date, to: Date()).day ?? 0 < 3 }
    }

    private var filteredMatches: [Match] {
        var result = filteredBaseMatches
            .filter { match in selectedSport.map { match.league.group == $0 } ?? true }
        switch dayFilter {
        case .live:
            result = result.filter { $0.state == .live }
        case .today:
            result = result.filter { Calendar.current.isDateInToday($0.date) }
        case .thisWeek:
            let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            result = result.filter { $0.state == .pre && $0.date >= Date() && $0.date <= endOfWeek }
        case nil:
            break
        }
        return result.sorted { lhs, rhs in
            if lhs.state == .live && rhs.state != .live { return true }
            if lhs.state != .live && rhs.state == .live { return false }
            return lhs.date < rhs.date
        }
    }

    private var priorityMatch: Match? {
        filteredBaseMatches.first { $0.state == .live }
            ?? filteredBaseMatches.first { $0.state == .pre && $0.date >= Date() }
            ?? filteredBaseMatches.first
    }

    private var liveMatches: [Match] { filteredBaseMatches.filter { $0.state == .live } }

    private var todayMatches: [Match] {
        filteredBaseMatches.filter { Calendar.current.isDateInToday($0.date) && $0.state != .final }
    }

    private var upcomingMatches: [Match] {
        filteredBaseMatches.filter { $0.state == .pre && $0.date >= Date() }
    }

    private var thisWeekMatches: [Match] {
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return filteredBaseMatches.filter { $0.state == .pre && $0.date >= Date() && $0.date <= endOfWeek }
    }

    private var availableSports: [SportGroup] {
        var seen: Set<SportGroup> = []
        return selectedMatches.compactMap { match in
            seen.insert(match.league.group).inserted ? match.league.group : nil
        }
    }

    private var teamArticles: [ESPNArticle] {
        let favoriteNames = prefs.favoriteTeams.map { $0.displayName.lowercased() }
        let articles = newsViewModel.articles(for: nil)
        let teamSpecific = articles.filter { article in
            let text = "\(article.headline) \(article.description)".lowercased()
            return favoriteNames.contains { text.contains($0) }
        }
        let visibleTeamSpecific = teamSpecific.filter { !articleLibrary.isHidden($0) && !articleLibrary.isMuted($0) }
        let visibleArticles = articles.filter { !articleLibrary.isHidden($0) && !articleLibrary.isMuted($0) }
        return visibleTeamSpecific.isEmpty ? Array(visibleArticles.prefix(8)) : Array(visibleTeamSpecific.prefix(12))
    }

    private func latestMatch(for team: FavoriteTeam) -> Match? {
        viewModel.allFollowedMatches
            .filter { matchIncludes($0, team: team) }
            .sorted { abs($0.date.timeIntervalSinceNow) < abs($1.date.timeIntervalSinceNow) }
            .first
    }

    private func matchIncludes(_ match: Match, team: FavoriteTeam) -> Bool {
        [match.home, match.away].contains { side in
            if side.teamID == team.teamID { return true }
            let names = [side.displayName, side.shortName, side.abbreviation]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            let favoriteNames = [team.displayName, team.abbreviation]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return names.contains { sideName in
                favoriteNames.contains { favoriteName in
                    sideName == favoriteName || sideName.contains(favoriteName) || favoriteName.contains(sideName)
                }
            }
        }
    }

    private func favoriteName(in match: Match) -> String {
        prefs.favoriteTeams.first { matchIncludes(match, team: $0) }?.displayName ?? match.away.shortName
    }

    private func periodGroups(for matches: [Match]) -> [FollowingPeriodGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: matches) { match -> String in
            if calendar.isDateInToday(match.date) { return "Today" }
            if calendar.isDateInTomorrow(match.date) { return "Tomorrow" }
            if match.date < calendar.date(byAdding: .day, value: 7, to: Date()) ?? Date() { return "This Week" }
            return "Later"
        }
        return ["Today", "Tomorrow", "This Week", "Later"].compactMap { title in
            guard let matches = grouped[title], !matches.isEmpty else { return nil }
            return FollowingPeriodGroup(title: title, matches: matches.sorted { $0.date < $1.date })
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
    }

    private func sportLabel(_ sport: SportGroup) -> String {
        switch sport {
        case .hockey: return "NHL"
        case .baseball: return "MLB"
        case .basketball: return "NBA"
        case .soccer: return "Soccer"
        default: return sport.rawValue
        }
    }

    private func shortDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct FollowingPeriodGroup: Identifiable {
    let title: String
    let matches: [Match]
    var id: String { title }
}

private struct MetricCard: View {
    let value: String
    let label: String
    let tint: Color
    let icon: String
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(isSelected ? .white : tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.weight(.heavy).monospacedDigit())
                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(isSelected ? tint : Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? tint : Color.clear))
    }
}

private struct PriorityGameCard: View {
    let match: Match
    let onSetAlert: (Match) -> Void
    let onAddToCalendar: (Match) -> Void
    let onHide: (Match) -> Void
    @EnvironmentObject private var prefs: PreferencesStore

    private var spoilersHidden: Bool { prefs.spoilerFreeMode && match.state == .final }

    private var isActuallyForYou: Bool {
        prefs.favoriteTeams.contains { favorite in
            [match.home, match.away].contains { side in
                if let tid = side.teamID, "\(match.league.path)-\(tid)" == favorite.id { return true }
                let sideNames = [side.displayName, side.shortName, side.abbreviation]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                let favoriteNames = [favorite.displayName, favorite.abbreviation]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                return sideNames.contains { sideName in
                    favoriteNames.contains { favoriteName in
                        sideName == favoriteName || sideName.contains(favoriteName) || favoriteName.contains(sideName)
                    }
                }
            }
        }
    }

    private var heroLabel: String {
        switch match.state {
        case .live: return isActuallyForYou ? "LIVE FOR YOU" : "RECOMMENDED LIVE"
        case .pre: return isActuallyForYou ? "NEXT FOR YOU" : "RECOMMENDED"
        case .final: return "FINAL"
        }
    }

    private var heroLabelColor: Color {
        if !isActuallyForYou { return Theme.textSecondary }
        return match.state == .live ? Theme.live : Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 5) {
                    if match.state == .live { PulsingLiveBadge() }
                    Text(heroLabel)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(heroLabelColor)
                }
                Spacer()
                Text(match.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    TeamLogo(url: match.away.logoURL, size: 32)
                    Text(match.away.shortName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if match.state != .pre, !spoilersHidden {
                    HStack(spacing: 6) {
                        Text(match.away.score ?? "-")
                        Text("–").foregroundStyle(Theme.textSecondary)
                        Text(match.home.score ?? "-")
                    }
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                } else {
                    Text("at")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 8) {
                    Text(match.home.shortName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    TeamLogo(url: match.home.logoURL, size: 32)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Text(statusLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                NavigationLink(value: match) {
                    Text(match.state == .live ? "Match Centre" : "Game Centre")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                Button { onSetAlert(match) } label: {
                    Label(
                        prefs.matchNotificationsEnabled ? "Alert Set" : "Set Alert",
                        systemImage: prefs.matchNotificationsEnabled ? "bell.fill" : "bell"
                    )
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.starting)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if !isActuallyForYou {
                Text("Recommended · \(match.league.shortName)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(match.state == .live ? Theme.live.opacity(0.42) : Theme.accent.opacity(0.32))
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: match.state == .live ? Theme.live.opacity(0.12) : .clear, radius: 16, y: 8)
        .contextMenu {
            Button("Set Alert", systemImage: "bell") { onSetAlert(match) }
            Button("Add to Calendar", systemImage: "calendar.badge.plus") { onAddToCalendar(match) }
            Divider()
            Button("Hide", systemImage: "eye.slash", role: .destructive) { onHide(match) }
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        switch match.state {
        case .live: parts.append("LIVE · \(match.statusDetail)")
        case .pre:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append(match.date.formatted(date: .abbreviated, time: .shortened))
            parts.append(formatter.localizedString(for: match.date, relativeTo: Date()))
        case .final: parts.append("Final")
        }
        if let venue = match.venue, !venue.isEmpty { parts.append(venue) }
        return parts.joined(separator: " · ")
    }
}

private struct CompactFollowingMatchRow: View {
    let match: Match
    let alertsEnabled: Bool
    let onSetAlert: () -> Void
    let onAddToCalendar: () -> Void
    let onHide: () -> Void
    @EnvironmentObject private var prefs: PreferencesStore

    private var spoilersHidden: Bool { prefs.spoilerFreeMode && match.state == .final }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeLabel)
                    .font(.caption.weight(.heavy).monospacedDigit())
                    .foregroundStyle(match.state == .live ? Theme.live : Theme.textPrimary)
                Text(match.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                teamLine(match.away)
                teamLine(match.home)
                HStack(spacing: 6) {
                    if !match.broadcasts.isEmpty {
                        Text(match.broadcasts.prefix(2).joined(separator: " · "))
                            .lineLimit(1)
                    } else if let venue = match.venue, !venue.isEmpty {
                        Text(venue).lineLimit(1)
                    } else {
                        Text(match.statusDetail).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 4)

            Image(systemName: alertsEnabled ? "bell.fill" : "bell")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(alertsEnabled ? Theme.starting : Theme.textSecondary)
                .frame(width: 28, height: 28)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .contextMenu {
            Button("Set Alert", systemImage: "bell") { onSetAlert() }
            Button("Add to Calendar", systemImage: "calendar.badge.plus") { onAddToCalendar() }
            Divider()
            Button("Hide", systemImage: "eye.slash", role: .destructive) { onHide() }
        }
    }

    private func teamLine(_ team: TeamSide) -> some View {
        HStack(spacing: 8) {
            TeamLogo(url: team.logoURL, size: 24)
            Text(team.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            if match.state != .pre {
                Text(spoilersHidden ? "?" : (team.score ?? ""))
                    .font(.subheadline.weight(.heavy).monospacedDigit())
                    .foregroundStyle(team.isWinner ? Theme.textPrimary : Theme.textSecondary)
            }
        }
    }

    private var timeLabel: String {
        switch match.state {
        case .live: return "LIVE"
        case .final: return "FINAL"
        case .pre: return match.date.formatted(date: .omitted, time: .shortened)
        }
    }
}

private struct FollowingUpdateRow: View {
    let article: ESPNArticle
    let isSaved: Bool
    let action: () -> Void
    let onToggleSaved: () -> Void
    let onHide: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: article.imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "newspaper.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 48, height: 48)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(article.league.shortName)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    if let published = article.published {
                        Text(relativeDate(published))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(article.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .contextMenu {
            Button(action: onToggleSaved) {
                Label(isSaved ? "Remove Saved Article" : "Save Article", systemImage: isSaved ? "bookmark.slash" : "bookmark")
            }
            if let url = article.url {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button("Not Interested", systemImage: "hand.thumbsdown", role: .destructive) { onHide() }
        }
        }
        .buttonStyle(.plain)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct FollowingStandingCard: View {
    let team: FavoriteTeam
    let recentMatch: Match?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TeamLogo(url: team.logoURL, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.displayName)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text(leagueName)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(contextLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }

            Text(contextMessage)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var leagueName: String {
        League.all.first { $0.path == team.leaguePath }?.name ?? "Followed team"
    }

    private var contextLabel: String {
        if let recentMatch, recentMatch.state == .live { return "Live now" }
        if recentMatch?.state == .pre { return "Next up" }
        return "Tracking"
    }

    private var contextMessage: String {
        guard let recentMatch else {
            return "Standings context will appear when league data is available."
        }
        switch recentMatch.state {
        case .live:
            return "\(team.displayName) is live against \(opponentName(in: recentMatch))."
        case .pre:
            return "Next game is \(recentMatch.date.formatted(date: .abbreviated, time: .shortened)) against \(opponentName(in: recentMatch))."
        case .final:
            return "Most recent result: \(recentMatch.away.shortName) at \(recentMatch.home.shortName)."
        }
    }

    private func opponentName(in match: Match) -> String {
        if match.home.displayName.localizedCaseInsensitiveContains(team.displayName) {
            return match.away.shortName
        }
        return match.home.shortName
    }
}

// MARK: - Inline standings panel

private struct FollowingStandingsPanel: View {
    let league: League
    var highlightTeamID: String? = nil
    @State private var groups: [StandingsGroup] = []
    @State private var isLoading = true
    @State private var showDivisions = false
    private let service = ESPNService()

    private var hasDivisionData: Bool {
        groups.contains { $0.name.localizedCaseInsensitiveContains("division") }
    }

    private var displayedGroups: [StandingsGroup] {
        guard hasDivisionData else { return groups }
        return groups.filter { group in
            let isDivision = group.name.localizedCaseInsensitiveContains("division")
            return showDivisions ? isDivision : !isDivision
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading && groups.isEmpty {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if groups.isEmpty {
                EmptyInlineCard(
                    title: "Standings unavailable",
                    message: "Standings for \(league.name) aren't available right now."
                )
            } else {
                if hasDivisionData {
                    HStack(spacing: 8) {
                        ForEach(["Conference", "Division"], id: \.self) { label in
                            let isDivTab = label == "Division"
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) { showDivisions = isDivTab }
                            } label: {
                                Text(label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(showDivisions == isDivTab ? .white : Theme.textSecondary)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(showDivisions == isDivTab ? Theme.accent : Theme.surface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(showDivisions == isDivTab ? Color.clear : Theme.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
                ForEach(displayedGroups) { group in
                    StandingsGroupCard(group: group, league: league, highlightTeamID: highlightTeamID)
                }
            }
        }
        .task(id: league.id) { await load() }
    }

    private func load() async {
        isLoading = true
        groups = (try? await service.standings(for: league)) ?? []
        isLoading = false
    }
}

private struct EmptyInlineCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
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
