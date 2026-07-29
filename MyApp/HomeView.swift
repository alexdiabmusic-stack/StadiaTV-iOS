import SwiftUI
import Combine

// MARK: - Home Filter

enum HomeFilter: Hashable {
    case forYou
    case allSports
    case sport(SportGroup)

    var label: String {
        switch self {
        case .forYou: return "For You"
        case .allSports: return "All Sports"
        case .sport(let g): return g.rawValue
        }
    }

    var icon: String {
        switch self {
        case .forYou: return "sparkles"
        case .allSports: return "sportscourt"
        case .sport(let g): return g.systemImage
        }
    }
}

// MARK: - Schedule Day

enum ScheduleDay: String, CaseIterable, Identifiable {
    case today = "Today"
    case tomorrow = "Tomorrow"
    case weekend = "Weekend"
    var id: String { rawValue }
}

// MARK: - Home View

struct HomeView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var watchStore: WatchStore
    @StateObject private var viewModel = HomeViewModel()
    @State private var playingChannel: Channel?
    @State private var selectedLiveSport: SportGroup?
    @State private var selectedScheduleDay: ScheduleDay = .today
    @State private var showingNotificationAlert = false
    @State private var notificationAlertMessage = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                mainContent
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: Match.self) { MatchDetailView(match: $0) }
            .sheet(item: $playingChannel) { PlayerView(channel: $0) }
        }
        .tint(Theme.accent)
        .task(id: loadPreferencesKey) {
            await viewModel.load(
                leagues: prefs.followedLeagues,
                favorites: prefs.favoriteTeams,
                notificationsEnabled: prefs.matchNotificationsEnabled,
                notificationLeadTime: prefs.matchReminderLeadTime,
                morningDigestEnabled: prefs.morningDigestEnabled
            )
            viewModel.startAutoRefresh()
        }
        .onDisappear { viewModel.stopAutoRefresh() }
        .alert("Notifications", isPresented: $showingNotificationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notificationAlertMessage)
        }
        .refreshable {
            await viewModel.load(
                leagues: prefs.followedLeagues,
                favorites: prefs.favoriteTeams,
                notificationsEnabled: prefs.matchNotificationsEnabled,
                notificationLeadTime: prefs.matchReminderLeadTime,
                morningDigestEnabled: prefs.morningDigestEnabled,
                force: true
            )
        }
    }

    private var loadPreferencesKey: String {
        [
            prefs.followedLeagues.map(\.id).sorted().joined(separator: ","),
            prefs.favoriteTeams.map(\.id).sorted().joined(separator: ","),
            prefs.matchNotificationsEnabled ? "n1" : "n0",
            "lead-\(prefs.matchReminderLeadTime.rawValue)",
            prefs.morningDigestEnabled ? "d1" : "d0"
        ].joined(separator: "|")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) { BrandMark() }
        ToolbarItem(placement: .primaryAction) {
            NavigationLink(destination: SearchView()) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isLoading && viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            VStack(spacing: 16) {
                ProgressView().tint(Theme.accent)
                Text("Loading your sports day…")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
        } else if let msg = viewModel.errorMessage, viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
            errorView(msg)
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                greetingSection

                heroSection

                sportsDaySummaryCard

                liveNowSection

                if !viewModel.startingSoon.isEmpty {
                    StartingSoonTimeline(matches: viewModel.startingSoon)
                }

                scheduleSection

                if !viewModel.recentHighlights.isEmpty {
                    TrendingSection(highlights: viewModel.recentHighlights)
                }

                if !watchStore.history.isEmpty {
                    ContinueWatchingSection(entries: watchStore.history) { playingChannel = $0 }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Here's what's happening")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let pick = viewModel.featuredPicks.first { p in
                guard let end = p.endDate else { return true }
                return end > ctx.date
            }
            if let pick {
                FeaturedHeroCard(pick: pick, match: viewModel.featuredMatchesByPickID[pick.id]) { match in
                    Task { await setAlert(for: match) }
                }
            } else if let prime = viewModel.primeMatch {
                PrimeHeroCard(match: prime)
            }
        }
    }

    // MARK: - Sports Day Summary

    @ViewBuilder
    private var sportsDaySummaryCard: some View {
        let teamsToday = viewModel.favoriteTeamMatchesToday.count
        let liveCount = viewModel.favoriteTeamLiveMatches.count

        if teamsToday > 0 || liveCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR SPORTS DAY")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 0) {
                    summaryPill("\(teamsToday)", "teams playing", Theme.upcoming)
                    if liveCount > 0 {
                        dividerDot
                        summaryPill("\(liveCount)", liveCount == 1 ? "game live" : "games live", Theme.live)
                    }
                    if prefs.matchNotificationsEnabled {
                        dividerDot
                        Label("Alerts on", systemImage: "bell.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
        } else if !prefs.favoriteTeams.isEmpty {
            noTeamsPlayingCard
        }
    }

    private func summaryPill(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(color)
            Text(label).font(.subheadline).foregroundStyle(Theme.textPrimary)
        }
    }

    private var dividerDot: some View {
        Text(" · ").font(.subheadline).foregroundStyle(Theme.textSecondary)
    }

    private var noTeamsPlayingCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("No followed teams play today")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let next = viewModel.favoriteTeamUpcoming.first {
                    Text("Next: \(next.shortName) · \(next.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: - Live Now

    private var liveNowSection: some View {
        LiveNowCommandCenter(
            matches: viewModel.liveNow,
            startingSoon: viewModel.startingSoon,
            nextMatches: viewModel.nextMatchesAcrossSports,
            selectedSport: $selectedLiveSport,
            onSetAlert: { match in Task { await setAlert(for: match) } },
            onAddToCalendar: { match in Task { await addToCalendar(match) } }
        )
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        ScheduleSection(
            upcoming: viewModel.upcoming,
            selectedDay: $selectedScheduleDay
        )
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

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task {
                    await viewModel.load(
                        leagues: prefs.followedLeagues,
                        favorites: prefs.favoriteTeams,
                        notificationsEnabled: prefs.matchNotificationsEnabled
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(32)
    }
}

// MARK: - Home Filter Bar

private struct HomeFilterBar: View {
    @Binding var selected: HomeFilter
    let followedLeagues: [League]

    private var filters: [HomeFilter] {
        var result: [HomeFilter] = [.forYou, .allSports]
        var seenGroups: Set<String> = []
        for league in followedLeagues {
            let group = league.group
            if seenGroups.insert(group.rawValue).inserted {
                result.append(.sport(group))
            }
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private func filterChip(_ filter: HomeFilter) -> some View {
        Button { withAnimation(.snappy) { selected = filter } } label: {
            Label(filter.label, systemImage: filter.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected == filter ? .white : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected == filter ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected == filter ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Featured Hero Card

private struct FeaturedHeroCard: View {
    let pick: FeaturedEventPick
    let match: Match?
    let onSetAlert: (Match) -> Void

    private var isLive: Bool { match?.state == .live }

    var body: some View {
        card
    }

    private var card: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            cardContent(now: ctx.date)
        }
    }

    private func cardContent(now: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // Background image
                Image("FeaturedHeroBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: 220)
                    .accessibilityHidden(true)

                // Cinematic gradient overlay
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.88), location: 0),
                        .init(color: .black.opacity(0.55), location: 0.5),
                        .init(color: .black.opacity(0.2), location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: proxy.size.width, height: 220)

                // Live edge glow
                if isLive {
                    LinearGradient(
                        colors: [Theme.live.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width, height: 220)
                }

                // Content
                VStack(alignment: .leading, spacing: 12) {
                    // League + state badge
                    HStack(spacing: 8) {
                        if isLive {
                            HStack(spacing: 6) {
                                PulsingLiveBadge()
                                Text("LIVE")
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.live, in: Capsule())
                        } else {
                            Text("FEATURED")
                                .font(.caption.weight(.black))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Theme.accent.opacity(0.9), in: Capsule())
                        }
                        Text(pick.league)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // Title or matchup
                    if let match {
                        HStack(spacing: 0) {
                            heroTeam(match.away)
                            Spacer()
                            VStack(spacing: 4) {
                                if match.state == .pre {
                                    if let start = pick.startDate, start > now {
                                        let secs = max(0, Int(start.timeIntervalSince(now)))
                                        let h = secs / 3600; let m = (secs % 3600) / 60
                                        VStack(spacing: 2) {
                                            Text(m < 1 && h == 0 ? "NOW" : "STARTS IN")
                                                .font(.system(size: 9, weight: .heavy))
                                                .foregroundStyle(.white.opacity(0.65))
                                                .tracking(0.5)
                                            Text(h > 0 ? "\(h)h \(m)m" : (m < 1 ? "NOW" : "\(m) MIN"))
                                                .font(.system(size: 20, weight: .black, design: .rounded).monospacedDigit())
                                                .foregroundStyle(.white)
                                            Text(start, style: .time)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.7))
                                        }
                                    } else {
                                        Text("VS")
                                            .font(.system(size: 20, weight: .black))
                                            .foregroundStyle(.white)
                                    }
                                } else {
                                    Text("\(match.away.score ?? "-") – \(match.home.score ?? "-")")
                                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                                        .foregroundStyle(.white)
                                    Text(match.statusDetail)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(isLive ? Theme.live : .white.opacity(0.7))
                                }
                            }
                            Spacer()
                            heroTeam(match.home)
                        }
                        .frame(maxWidth: proxy.size.width - 40)
                    } else {
                        Text(pick.title)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: min(280, proxy.size.width - 32), alignment: .leading)
                    }

                    // Action buttons
                    HStack(spacing: 10) {
                        if let match {
                            switch match.state {
                            case .live:
                                NavigationLink(value: match) {
                                    heroButtonLabel("Watch Live", icon: "play.fill", primary: true)
                                }
                                .buttonStyle(.plain)
                                NavigationLink(value: match) {
                                    heroButtonLabel("Match Centre", icon: "sportscourt", primary: false)
                                }
                                .buttonStyle(.plain)
                            case .pre:
                                Button { onSetAlert(match) } label: {
                                    heroButtonLabel("Set Alert", icon: "bell", primary: false)
                                }
                                .buttonStyle(.plain)
                                NavigationLink(value: match) {
                                    heroButtonLabel("Streams", icon: "tv", primary: true)
                                }
                                .buttonStyle(.plain)
                            case .final:
                                NavigationLink(value: match) {
                                    heroButtonLabel("Highlights", icon: "film", primary: true)
                                }
                                .buttonStyle(.plain)
                                NavigationLink(value: match) {
                                    heroButtonLabel("Recap", icon: "doc.text", primary: false)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            heroButtonLabel("Streams", icon: "tv", primary: true)
                        }
                    }
                }
                .padding(20)
                .frame(width: proxy.size.width, height: 220, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: 220)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(isLive ? 0 : 0.12)))
            .overlay(alignment: .bottomLeading) {
                if isLive {
                    shape.strokeBorder(Theme.live.opacity(0.5), lineWidth: 1.5)
                }
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
    }

    private func heroTeam(_ side: TeamSide) -> some View {
        VStack(spacing: 6) {
            TeamLogo(url: side.logoURL, size: 52)
            Text(side.shortName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 72)
        }
    }

    private func countdownText(to date: Date, now: Date) -> some View {
        let secs = max(0, Int(date.timeIntervalSince(now)))
        let h = secs / 3600; let m = (secs % 3600) / 60
        return Text(h > 0 ? "Starts in \(h)h \(m)m" : "Starts in \(m) min")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))
    }

    private func heroButtonLabel(_ title: String, icon: String, primary: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                primary ? Theme.accent.opacity(0.92) : Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(primary ? 0.2 : 0.25))
            )
    }
}

// MARK: - Prime Hero Card (no featured pick)

private struct PrimeHeroCard: View {
    let match: Match

    var body: some View {
        NavigationLink(value: match) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if match.state == .live {
                            PulsingLiveBadge()
                            Text("LIVE")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(Theme.live)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                            Text("TOP MATCH")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        Text(match.league.shortName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    HStack(spacing: 12) {
                        teamColumn(match.away)
                        VStack(spacing: 4) {
                            Text(match.state == .pre
                                 ? "VS"
                                 : "\(match.away.score ?? "-") – \(match.home.score ?? "-")")
                                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                            Text(match.statusDetail)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 80)
                        teamColumn(match.home)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [Theme.surfaceElevated, Theme.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(match.state == .live ? Theme.live.opacity(0.4) : Theme.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    private func teamColumn(_ side: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: side.logoURL, size: 44)
            Text(side.shortName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live Now Command Center

private struct LiveNowCommandCenter: View {
    let matches: [Match]
    let startingSoon: [Match]
    let nextMatches: [Match]
    @Binding var selectedSport: SportGroup?
    let onSetAlert: (Match) -> Void
    let onAddToCalendar: (Match) -> Void
    @State private var hiddenMatchIDs: Set<String> = []

    private var visibleMatches: [Match] {
        matches.filter { !hiddenMatchIDs.contains($0.id) }
    }

    private var activeSports: [SportGroup] {
        var seen: [SportGroup] = []
        for m in visibleMatches where !seen.contains(m.league.group) { seen.append(m.league.group) }
        return seen
    }

    private var displayed: [Match] {
        guard let s = selectedSport else { return visibleMatches }
        return visibleMatches.filter { $0.league.group == s }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                PulsingLiveBadge()
                Text("LIVE NOW")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.live)
                Spacer()
                if !matches.isEmpty {
                    NavigationLink(destination: LiveView()) {
                        Text("See All")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            // Sport chips
            if !activeSports.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        sportChip(title: "All", icon: "sportscourt", selected: selectedSport == nil) {
                            withAnimation(.snappy) { selectedSport = nil }
                        }
                        ForEach(activeSports) { sport in
                            sportChip(title: sport.rawValue, icon: sport.systemImage, selected: selectedSport == sport) {
                                withAnimation(.snappy) { selectedSport = selectedSport == sport ? nil : sport }
                            }
                        }
                    }
                }
            }

            // Content
            if visibleMatches.isEmpty {
                noLiveContent
            } else if displayed.isEmpty {
                Text("No live \(selectedSport?.rawValue ?? "games") right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                ForEach(displayed.prefix(4)) { match in
                    NavigationLink(value: match) {
                        LiveMatchCard(
                            match: match,
                            onSetAlert: { onSetAlert(match) },
                            onAddToCalendar: { onAddToCalendar(match) },
                            onHide: { hiddenMatchIDs.insert(match.id) }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var noLiveContent: some View {
        if !startingSoon.isEmpty || !nextMatches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                let soonMatches = startingSoon.isEmpty ? Array(nextMatches.prefix(3)) : startingSoon
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.fill")
                    Text("Nothing live right now — starting soon")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.starting)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(soonMatches) { match in
                            NavigationLink(value: match) {
                                SoonTimelineCard(match: match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(Theme.textSecondary)
                Text("Nothing is live right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func sportChip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .white : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Theme.live : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.live : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Starting Soon Timeline

struct StartingSoonTimeline: View {
    let matches: [Match]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.fill")
                Text("STARTING SOON")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.starting)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(matches.prefix(8)) { match in
                        NavigationLink(value: match) {
                            SoonTimelineCard(match: match)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct SoonTimelineCard: View {
    let match: Match

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let secs = max(0, Int(match.date.timeIntervalSince(ctx.date)))
            let h = secs / 3600; let m = (secs % 3600) / 60
            let urgent = m < 10 && h == 0

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(match.date, style: .time)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(match.league.shortName)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 6) {
                    TeamLogo(url: match.away.logoURL, size: 28)
                    Text("vs")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                    TeamLogo(url: match.home.logoURL, size: 28)
                }

                Text(match.shortName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(secs < 60 ? "Starts now" : (h > 0 ? "In \(h)h \(m)m" : "In \(m) min"))
                    .font(.system(size: 12, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(urgent ? Theme.live : Theme.starting)

                if !match.broadcasts.isEmpty {
                    Label(match.broadcasts.first!, systemImage: "tv")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(width: 150)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(urgent ? Theme.live : Theme.starting)
                    .frame(height: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

// MARK: - Schedule Section

private struct ScheduleSection: View {
    let upcoming: [Match]
    @Binding var selectedDay: ScheduleDay

    private let calendar = Calendar.current

    private var todayMatches: [Match] {
        matches(inDayOffset: 0)
    }

    private var tomorrowMatches: [Match] {
        matches(inDayOffset: 1)
    }

    private func matches(inDayOffset offset: Int) -> [Match] {
        let start = calendar.startOfDay(for: Date())
        guard let dayStart = calendar.date(byAdding: .day, value: offset, to: start),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }
        return upcoming.filter { $0.date >= dayStart && $0.date < dayEnd }
    }

    // Only the actual upcoming Sat+Sun (or today if Sat/Sun).
    private var weekendMatches: [Match] {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // 1=Sun … 7=Sat

        let startDate: Date
        let endDate: Date

        switch weekday {
        case 7: // Saturday — show Sat + Sun
            startDate = today
            endDate = calendar.date(byAdding: .day, value: 2, to: today)!
        case 1: // Sunday — show just today
            startDate = today
            endDate = calendar.date(byAdding: .day, value: 1, to: today)!
        default: // Mon–Fri: find next Saturday
            let daysToSat = 7 - weekday // Mon(2)→5, Tue(3)→4, …, Fri(6)→1
            startDate = calendar.date(byAdding: .day, value: daysToSat, to: today)!
            endDate   = calendar.date(byAdding: .day, value: daysToSat + 2, to: today)!
        }

        return upcoming.filter {
            let d = calendar.startOfDay(for: $0.date)
            return d >= startDate && d < endDate
        }
    }

    private var displayedMatches: [Match] {
        switch selectedDay {
        case .today: return todayMatches
        case .tomorrow: return tomorrowMatches
        case .weekend: return weekendMatches
        }
    }

    // Groups matches by calendar day, preserving order.
    private func groupByDay(_ matches: [Match]) -> [(label: String, matches: [Match])] {
        var order: [Date] = []
        var groups: [Date: [Match]] = [:]
        for match in matches {
            let day = calendar.startOfDay(for: match.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(match)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return order.map { day in
            (label: fmt.string(from: day), matches: groups[day]!)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR SCHEDULE")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            // Day picker
            HStack(spacing: 0) {
                ForEach(ScheduleDay.allCases) { day in
                    let isSelected = selectedDay == day
                    Button { withAnimation(.snappy) { selectedDay = day } } label: {
                        Text(day.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                GeometryReader { proxy in
                    let idx = ScheduleDay.allCases.firstIndex(of: selectedDay) ?? 0
                    let w = proxy.size.width / CGFloat(ScheduleDay.allCases.count)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.15))
                        .frame(width: w, height: proxy.size.height)
                        .offset(x: w * CGFloat(idx))
                        .animation(.snappy, value: selectedDay)
                }
            )

            // Matches — grouped by date for Tomorrow/Weekend
            if displayedMatches.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(Theme.textSecondary)
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
            } else if selectedDay == .today {
                ForEach(displayedMatches) { match in
                    NavigationLink(value: match) { ScheduleRow(match: match) }
                        .buttonStyle(.plain)
                }
            } else {
                let groups = groupByDay(displayedMatches)
                ForEach(groups, id: \.label) { group in
                    Text(group.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                    ForEach(group.matches) { match in
                        NavigationLink(value: match) { ScheduleRow(match: match) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        switch selectedDay {
        case .today: return "No games for your followed leagues today."
        case .tomorrow: return "No announced games for tomorrow yet."
        case .weekend: return "No weekend games found for your leagues."
        }
    }
}

private struct ScheduleRow: View {
    let match: Match

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(match.date, style: .time)
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(match.league.shortName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 68, alignment: .trailing)

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1, height: 36)

            HStack(spacing: 10) {
                TeamLogo(url: match.away.logoURL, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.shortName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !match.broadcasts.isEmpty {
                        Text(match.broadcasts.prefix(2).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TeamLogo(url: match.home.logoURL, size: 28)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Trending Section

private struct TrendingSection: View {
    let highlights: [MatchHighlight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                Text("RECENT HIGHLIGHTS")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(highlights) { clip in
                        HighlightCard(clip: clip)
                    }
                }
            }
        }
    }
}

// MARK: - Continue Watching Section

struct ContinueWatchingSection: View {
    let entries: [WatchHistoryEntry]
    let onPlay: (Channel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text("CONTINUE WATCHING")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(entries) { entry in
                        if let channel = entry.saved.channel {
                            Button { onPlay(channel) } label: {
                                ContinueWatchingCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    let entry: WatchHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.surfaceElevated
                AsyncImage(url: entry.saved.channel?.logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(10)
                    } else {
                        Image(systemName: "play.tv.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .padding(6)
            }

            Text(entry.saved.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(entry.lastWatched.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 150)
    }
}

// MARK: - Home View Model (unchanged)

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var liveNow: [Match] = []
    @Published private(set) var favoriteTeamLiveMatches: [Match] = []
    @Published private(set) var favoriteTeamMatchesToday: [Match] = []
    @Published private(set) var favoriteTeamUpcoming: [Match] = []
    @Published private(set) var nextMatchesAcrossSports: [Match] = []
    @Published private(set) var startingSoon: [Match] = []
    @Published private(set) var upcoming: [Match] = []
    @Published private(set) var featuredPicks: [FeaturedEventPick] = []
    @Published private(set) var featuredMatchesByPickID: [String: Match] = [:]
    @Published private(set) var primeMatch: Match?
    @Published private(set) var recentHighlights: [MatchHighlight] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service = ESPNService()
    private let featuredCalendar = FeaturedEventCalendar.shared

    private var lastLoadedLeagueIDs: Set<String> = []
    private var lastLoadedAt: Date?
    private let cacheLifetime: TimeInterval = 120

    private var demandScoreCache: [String: Int] = [:]

    private var refreshTask: Task<Void, Never>?
    private var lastLoadArgs: (leagues: [League], favorites: [FavoriteTeam], notificationsEnabled: Bool, notificationLeadTime: MatchReminderLeadTime, morningDigestEnabled: Bool)?

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled, let self, let args = self.lastLoadArgs else { continue }
                await self.load(leagues: args.leagues, favorites: args.favorites, notificationsEnabled: args.notificationsEnabled, notificationLeadTime: args.notificationLeadTime, morningDigestEnabled: args.morningDigestEnabled)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func load(leagues: [League], favorites: [FavoriteTeam], notificationsEnabled: Bool = false, notificationLeadTime: MatchReminderLeadTime = .thirty, morningDigestEnabled: Bool = false, force: Bool = false) async {
        lastLoadArgs = (leagues, favorites, notificationsEnabled, notificationLeadTime, morningDigestEnabled)
        let leagueIDs = Set(leagues.map(\.id))
        featuredPicks = featuredCalendar.picks()
        let hasData = !(liveNow.isEmpty && upcoming.isEmpty && favoriteTeamUpcoming.isEmpty)
        if !force, hasData, leagueIDs == lastLoadedLeagueIDs,
           let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < cacheLifetime {
            return
        }
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        demandScoreCache.removeAll(keepingCapacity: true)
        let favoriteIDs = Set(favorites.map(\.id))
        let favoriteNames = Set(favorites.map { $0.displayName.lowercased() })
        var matchesByLeague: [String: [Match]] = [:]

        await withTaskGroup(of: (String, [Match]).self) { group in
            for league in leagues {
                group.addTask {
                    (league.id, (try? await self.service.scoreboards(for: league, starting: Date(), days: 7)) ?? [])
                }
            }
            for await (id, matches) in group {
                guard !matches.isEmpty else { continue }
                matchesByLeague[id] = matches
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
            }
        }

        await withTaskGroup(of: (String, [Match]).self) { group in
            for league in League.all where !leagueIDs.contains(league.id) {
                group.addTask {
                    (league.id, (try? await self.service.scoreboards(for: league, starting: Date(), days: 3)) ?? [])
                }
            }
            for await (id, matches) in group {
                guard !matches.isEmpty else { continue }
                matchesByLeague[id] = matches
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
            }
        }

        isLoading = false
        if matchesByLeague.isEmpty {
            errorMessage = "ESPN did not return games for your followed leagues."
        }

        let favoriteLeagueIDs = Set(favorites.map(\.leaguePath))
        await withTaskGroup(of: (String, [Match]).self) { group in
            for league in League.all where favoriteLeagueIDs.contains(league.id) {
                group.addTask {
                    (league.id, (try? await self.service.scoreboards(for: league, starting: Date(), days: 365)) ?? [])
                }
            }
            for await (id, matches) in group {
                guard !matches.isEmpty else { continue }
                let existing = matchesByLeague[id] ?? []
                matchesByLeague[id] = mergeMatches(existing + matches)
                rebuildSections(matchesByLeague: matchesByLeague, followedIDs: leagueIDs, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
            }
        }

        if notificationsEnabled {
            let allMatchesFlat = matchesByLeague.values.flatMap { $0 }
            await MatchNotificationService.shared.syncNotifications(
                matches: allMatchesFlat,
                favorites: favorites,
                leadTime: notificationLeadTime
            )
            if morningDigestEnabled {
                await MatchNotificationService.shared.scheduleMorningDigest(matches: allMatchesFlat)
            }
        }

        let recentlyFinished = matchesByLeague
            .filter { leagueIDs.contains($0.key) }
            .values.flatMap { $0 }
            .filter { $0.state == .final }
            .sorted { $0.date > $1.date }
            .prefix(3)

        if !recentlyFinished.isEmpty {
            var clips: [MatchHighlight] = []
            await withTaskGroup(of: [MatchHighlight].self) { group in
                for match in recentlyFinished {
                    group.addTask { [service] in
                        (try? await service.gameSummary(for: match.league, eventID: match.id))?.highlights ?? []
                    }
                }
                for await matchClips in group {
                    clips.append(contentsOf: matchClips)
                }
            }
            recentHighlights = Array(clips.prefix(8))
        }

        if !Task.isCancelled, !matchesByLeague.isEmpty {
            errorMessage = nil
            lastLoadedLeagueIDs = leagueIDs
            lastLoadedAt = Date()
        }
    }

    private func rebuildSections(matchesByLeague: [String: [Match]], followedIDs: Set<String>, favoriteIDs: Set<String>, favoriteNames: Set<String>) {
        let now = Date()
        let calendar = Calendar.current
        let allMatches = mergeMatches(matchesByLeague.values.flatMap { $0 })
        let followedMatches = mergeMatches(matchesByLeague
            .filter { followedIDs.contains($0.key) }
            .values.flatMap { $0 })

        var scores: [String: Int] = [:]
        scores.reserveCapacity(allMatches.count)
        for match in allMatches {
            scores[match.id] = primeScore(match, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames)
        }
        func score(_ match: Match) -> Int { scores[match.id] ?? 0 }

        liveNow = allMatches
            .filter { $0.state == .live }
            .sorted { score($0) > score($1) }
        favoriteTeamLiveMatches = liveNow
            .filter { involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
        favoriteTeamMatchesToday = allMatches
            .filter { calendar.isDateInToday($0.date) && involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
            .sorted { $0.date < $1.date }
        favoriteTeamUpcoming = allMatches
            .filter { $0.state == .pre && $0.date >= now && involvesFavorite($0, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) }
            .sorted { $0.date < $1.date }
        nextMatchesAcrossSports = allMatches
            .filter { $0.state == .pre && $0.date >= now }
            .sorted { $0.date < $1.date }
            .prefix(3)
            .map { $0 }
        // Compute featured IDs first so we can suppress duplicates below
        var syncedFeaturedMatches = Dictionary(uniqueKeysWithValues: featuredPicks.map { ($0.id, $0.streamMatch) })
        for match in allMatches.sorted(by: { score($0) > score($1) }) {
            for pick in featuredCalendar.matchingPicks(for: match) {
                syncedFeaturedMatches[pick.id] = match
            }
        }
        featuredMatchesByPickID = syncedFeaturedMatches
        let featuredIDs = Set(syncedFeaturedMatches.values.map { $0.id })
        liveNow = liveNow.filter { !featuredIDs.contains($0.id) }
        let soonWindow = now.addingTimeInterval(6 * 60 * 60)
        startingSoon = allMatches
            .filter { $0.state == .pre && $0.date > now && $0.date <= soonWindow && !featuredIDs.contains($0.id) }
            .sorted { $0.date < $1.date }
            .prefix(8)
            .map { $0 }
        upcoming = followedMatches
            .filter { $0.state == .pre && $0.date >= now }
            .sorted { $0.date < $1.date }
            .prefix(12)
            .map { $0 }
        primeMatch = (liveNow + favoriteTeamUpcoming + upcoming)
            .max { score($0) < score($1) }
    }

    private func mergeMatches(_ matches: [Match]) -> [Match] {
        var seenIDs: Set<String> = []
        var unique: [Match] = []
        for match in matches.sorted(by: { $0.date < $1.date }) where seenIDs.insert(match.id).inserted {
            unique.append(match)
        }
        return unique
    }

    private func primeScore(_ match: Match, favoriteIDs: Set<String> = [], favoriteNames: Set<String> = []) -> Int {
        var score = cachedDemandScore(match)
        if match.state == .live { score += 100 }
        if involvesFavorite(match, favoriteIDs: favoriteIDs, favoriteNames: favoriteNames) { score += 50 }
        if !match.broadcasts.isEmpty { score += 20 }
        score -= max(0, Int(match.date.timeIntervalSinceNow / 3600))
        return score
    }

    private func cachedDemandScore(_ match: Match) -> Int {
        if let cached = demandScoreCache[match.id] { return cached }
        let score = eventDemandScore(match)
        demandScoreCache[match.id] = score
        return score
    }

    private func eventDemandScore(_ match: Match) -> Int {
        let text = [match.name, match.shortName, match.statusDetail, match.league.name, match.league.shortName]
            .joined(separator: " ")
            .lowercased()
        var score = featuredCalendar.demandBoost(for: match)

        if text.contains("world cup") || text.contains("fifa") { score += 220 }
        if text.contains("champions league") || text.contains("uefa") { score += 140 }
        if text.contains("final") || text.contains("championship") || text.contains("title") { score += 130 }
        if text.contains("semifinal") || text.contains("semi-final") || text.contains("playoff") { score += 80 }
        if text.contains("derby") || text.contains("rivalry") { score += 30 }

        switch match.league.name {
        case "NFL": score += 70
        case "NBA", "Premier League", "Champions League": score += 55
        case "MLB", "NHL": score += 35
        case "MLS", "La Liga", "Serie A", "Bundesliga", "Ligue 1": score += 25
        default: score += 10
        }

        return score
    }

    private func involvesFavorite(_ match: Match, favoriteIDs: Set<String>, favoriteNames: Set<String>) -> Bool {
        guard !favoriteIDs.isEmpty || !favoriteNames.isEmpty else { return false }
        let sides = [match.home, match.away]
        return sides.contains { side in
            if let teamID = side.teamID, favoriteIDs.contains("\(match.league.path)-\(teamID)") {
                return true
            }
            return favoriteNames.contains(side.displayName.lowercased())
        }
    }
}
