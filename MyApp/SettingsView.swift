import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var showingAddPlaylist = false
    @State private var showingTeamEditor = false
    @State private var isExportingCalendar = false
    @State private var calendarExportMessage: String?
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    premiumSection
                    playlistsSection
                    myTeamsSection
                    appearanceSection
                    notificationsSection
                    privacySection
                    setupSection
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
                .refreshable { await playlists.refreshAll() }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddPlaylist = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add playlist")
                }
            }
            .sheet(isPresented: $showingAddPlaylist) {
                AddPlaylistView { playlists.add($0) }
            }
            .sheet(isPresented: $showingTeamEditor) {
                TeamEditorView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Premium

    private var premiumSection: some View {
        Section {
            PremiumStatusCard(showPaywall: $showPaywall)
        } header: {
            Label("StadiaTV Premium", systemImage: "sparkles")
        }
    }

    // MARK: - Playlists

    private var playlistsSection: some View {
        Section {
            if playlists.playlists.isEmpty {
                Button {
                    showingAddPlaylist = true
                } label: {
                    Label("Add M3U or Xtream Playlist", systemImage: "plus")
                        .foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.surface)
            } else {
                ForEach(playlists.playlists) { playlist in
                    HStack(spacing: 12) {
                        Image(systemName: playlist.kind == .m3u ? "link" : "person.badge.key.fill")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(playlistSubtitle(playlist))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if playlists.isLoading(playlist) {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("\(playlists.channelCount(for: playlist))")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                .onDelete { playlists.remove(at: $0) }
            }
        } header: {
            Label("Playlists", systemImage: "list.and.film")
        } footer: {
            if let lastError = playlists.lastError {
                Text(lastError).foregroundStyle(Theme.live)
            } else {
                Text("Swipe left to delete a playlist. Pull to refresh all channel lists.")
            }
        }
    }

    // MARK: - My Teams & Leagues

    private var myTeamsSection: some View {
        Section {
            Button {
                showingTeamEditor = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "star.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit My Teams")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(myTeamsSummary)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)
        } header: {
            Label("My Teams & Leagues", systemImage: "person.3.fill")
        } footer: {
            Text("Follow leagues and star favorite teams to personalize Home, Sports, and notifications.")
        }
    }

    // MARK: - Appearance & Streaming

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: Binding(
                get: { prefs.appearance },
                set: { prefs.setAppearance($0) }
            )) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.surface)

            Menu {
                ForEach(StreamLanguage.all) { language in
                    Button {
                        prefs.setDefaultStreamLanguage(language)
                    } label: {
                        if prefs.isStreamLanguageSelected(language) {
                            Label(language.name, systemImage: "checkmark")
                        } else {
                            Text(language.name)
                        }
                    }
                }
            } label: {
                HStack {
                    Label("Stream Language", systemImage: "globe")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(defaultStreamLanguageName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            settingsToggle(
                title: "Spoiler-Free Mode",
                systemImage: "eye.slash",
                isOn: Binding(get: { prefs.spoilerFreeMode }, set: { prefs.setSpoilerFreeMode($0) })
            )

            settingsToggle(
                title: "Live Score in Player",
                systemImage: "sportscourt.fill",
                isOn: Binding(get: { prefs.showLiveScoreBadge }, set: { prefs.setShowLiveScoreBadge($0) })
            )
        } header: {
            Label("Appearance & Streaming", systemImage: "circle.lefthalf.filled")
        } footer: {
            Text("Spoiler-Free Mode hides final scores in match lists. Live Score shows a real-time badge while streaming — tap to expand, then × to dismiss.")
        }
    }

    // MARK: - Notifications & Calendar

    private var notificationsSection: some View {
        Section {
            HStack {
                Label("Smart Alerts", systemImage: "bell.badge.fill")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !entitlements.isPremium {
                    Button {
                        showPaywall = true
                    } label: {
                        Label("Premium", systemImage: "lock.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Toggle("", isOn: Binding(
                        get: { prefs.matchNotificationsEnabled },
                        set: { _ in toggleNotifications() }
                    ))
                    .labelsHidden()
                    .tint(Theme.accent)
                }
            }
            .listRowBackground(Theme.surface)

            if prefs.matchNotificationsEnabled {
                Picker("Remind me", selection: Binding(
                    get: { prefs.matchReminderLeadTime },
                    set: { updateReminderLeadTime($0) }
                )) {
                    ForEach(MatchReminderLeadTime.allCases) { leadTime in
                        Text(leadTime.label).tag(leadTime)
                    }
                }
                .listRowBackground(Theme.surface)

                settingsToggle(
                    title: "Morning Briefing",
                    systemImage: "sunrise.fill",
                    isOn: Binding(get: { prefs.morningDigestEnabled }, set: { prefs.setMorningDigestEnabled($0) })
                )
            }

            #if !os(tvOS)
            Button {
                Task { await exportFollowedGamesToCalendar() }
            } label: {
                HStack {
                    Label(
                        isExportingCalendar ? "Adding Games…" : "Add Upcoming Games to Calendar",
                        systemImage: "calendar.badge.plus"
                    )
                    .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if isExportingCalendar { ProgressView().tint(Theme.accent) }
                }
            }
            .disabled(isExportingCalendar)
            .listRowBackground(Theme.surface)
            #endif
        } header: {
            Label("Notifications & Calendar", systemImage: "bell.badge")
        } footer: {
            Text(calendarExportMessage ?? "Notifications are local and never leave your device. Calendar export adds upcoming games from your followed leagues.")
        }
    }

    // MARK: - Privacy & Sync

    private var privacySection: some View {
        Section {
            settingsToggle(
                title: "iCloud Sync",
                systemImage: "icloud.fill",
                isOn: Binding(get: { prefs.cloudSyncEnabled }, set: { prefs.setCloudSyncEnabled($0) })
            )
        } header: {
            Label("Privacy & Sync", systemImage: "lock.shield")
        } footer: {
            Text("iCloud sync covers preferences, favorite channels, and watch history. Xtream Codes credentials stay in Keychain on this device only.")
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section {
            Button {
                prefs.resetOnboarding()
            } label: {
                Label("Redo Setup", systemImage: "arrow.clockwise")
                    .foregroundStyle(Theme.accent)
            }
            .listRowBackground(Theme.surface)
        } footer: {
            Text("Run setup again to pick sports, leagues, teams, and an optional playlist.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder private func settingsToggle(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .listRowBackground(Theme.surface)
    }

    private var myTeamsSummary: String {
        let selectedLeagues = League.all.filter { prefs.isLeagueSelected($0) }.count
        let leagueText = selectedLeagues == 0 ? "All leagues" : "\(selectedLeagues) league\(selectedLeagues == 1 ? "" : "s")"
        let favorites = prefs.favoriteTeams.count
        return "\(leagueText) · \(favorites) favorite team\(favorites == 1 ? "" : "s")"
    }

    private var defaultStreamLanguageName: String {
        let selected = prefs.preferredStreamLanguages.first ?? "en"
        return StreamLanguage.all.first { $0.code == selected }?.name ?? "English"
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        switch playlist.kind {
        case .m3u: return playlist.m3uURL ?? "M3U"
        case .xtream: return playlist.host ?? "Xtream Codes"
        }
    }

    private func toggleNotifications() {
        if prefs.matchNotificationsEnabled {
            prefs.setMatchNotificationsEnabled(false)
            MatchNotificationService.shared.removeAllMatchNotifications()
        } else {
            Task {
                let granted = await MatchNotificationService.shared.requestAuthorization()
                prefs.setMatchNotificationsEnabled(granted)
                if granted { await syncFavoriteGameNotifications() }
            }
        }
    }

    private func updateReminderLeadTime(_ leadTime: MatchReminderLeadTime) {
        prefs.setMatchReminderLeadTime(leadTime)
        guard prefs.matchNotificationsEnabled else { return }
        Task { await syncFavoriteGameNotifications() }
    }

    private func syncFavoriteGameNotifications() async {
        let matches = await loadFollowedMatches()
        await MatchNotificationService.shared.syncNotifications(
            matches: matches,
            favorites: prefs.favoriteTeams,
            leadTime: prefs.matchReminderLeadTime
        )
    }

    #if !os(tvOS)
    private func exportFollowedGamesToCalendar() async {
        guard !isExportingCalendar else { return }
        isExportingCalendar = true
        defer { isExportingCalendar = false }
        let matches = await loadFollowedMatches()
        do {
            let saved = try await MatchCalendarService.shared.add(matches: matches)
            calendarExportMessage = saved == 1 ? "Added 1 upcoming game to Calendar." : "Added \(saved) upcoming games to Calendar."
        } catch {
            calendarExportMessage = error.localizedDescription
        }
    }
    #endif

    private func loadFollowedMatches() async -> [Match] {
        let service = ESPNService()
        var matches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in prefs.followedLeagues {
                group.addTask {
                    (try? await service.scoreboards(for: league, starting: Date(), days: 7)) ?? []
                }
            }
            for await loaded in group { matches.append(contentsOf: loaded) }
        }
        return Dictionary(grouping: matches, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.date < $1.date }
    }
}
