import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showingAddPlaylist = false
    @State private var isExportingCalendar = false
    @State private var calendarExportMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    playlistsSection
                    leaguesSection
                    favoritesSection
                    integrationsSection
                    setupSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
        }
        .tint(Theme.accent)
    }

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
                Text("Live TV uses all channels loaded from your M3U and Xtream playlists.")
            }
        }
    }

    private var leaguesSection: some View {
        ForEach(SportGroup.allCases) { sport in
            Section {
                ForEach(League.leagues(in: sport)) { league in
                    Button {
                        prefs.toggleLeague(league)
                    } label: {
                        HStack {
                            Text(league.name).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if prefs.isLeagueSelected(league) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            } header: {
                Label(sport.rawValue, systemImage: sport.systemImage)
            }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        if !prefs.favoriteTeams.isEmpty {
            Section("Favorite Teams") {
                ForEach(prefs.favoriteTeams) { favorite in
                    HStack(spacing: 12) {
                        AsyncImage(url: favorite.logoURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Image(systemName: "shield.fill")
                                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
                            }
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(favorite.displayName)
                                .foregroundStyle(Theme.textPrimary)
                            if let league = League.all.first(where: { $0.path == favorite.leaguePath }) {
                                Text(league.name)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer()
                        Button {
                            removeFavorite(favorite)
                        } label: {
                            Image(systemName: "star.slash")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
    }

    private var integrationsSection: some View {
        Section {
            Button {
                toggleNotifications()
            } label: {
                HStack {
                    Label("Match Notifications", systemImage: prefs.matchNotificationsEnabled ? "bell.fill" : "bell")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(prefs.matchNotificationsEnabled ? "On" : "Off")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            if prefs.matchNotificationsEnabled {
                Picker("Reminder", selection: Binding(
                    get: { prefs.matchReminderLeadTime },
                    set: { updateReminderLeadTime($0) }
                )) {
                    ForEach(MatchReminderLeadTime.allCases) { leadTime in
                        Text(leadTime.label).tag(leadTime)
                    }
                }
                .pickerStyle(.menu)
                .listRowBackground(Theme.surface)
            }

            Button {
                Task { await exportFollowedGamesToCalendar() }
            } label: {
                HStack {
                    Label(isExportingCalendar ? "Adding Games" : "Add Upcoming Games to Calendar", systemImage: "calendar.badge.plus")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if isExportingCalendar { ProgressView().tint(Theme.accent) }
                }
            }
            .disabled(isExportingCalendar)
            .listRowBackground(Theme.surface)

            Button {
                prefs.setCloudSyncEnabled(!prefs.cloudSyncEnabled)
            } label: {
                HStack {
                    Label("iCloud Sync", systemImage: prefs.cloudSyncEnabled ? "icloud.fill" : "icloud")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(prefs.cloudSyncEnabled ? "On" : "Off")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            HStack {
                Label("External API Configuration", systemImage: "key.horizontal")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(AppConfiguration.isOddsEnabled ? "Configured" : "Not Bundled")
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        } header: {
            Label("Privacy & Integrations", systemImage: "lock.shield")
        } footer: {
            Text(calendarExportMessage ?? "Notifications are local. Calendar export uses write-only access. iCloud sync covers preferences, favorite channels, and watch history; Xtream secrets stay in Keychain on this device.")
        }
    }

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
                if granted {
                    await syncFavoriteGameNotifications()
                }
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

    private func loadFollowedMatches() async -> [Match] {
        let service = ESPNService()
        var matches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in prefs.followedLeagues {
                group.addTask {
                    (try? await service.scoreboards(for: league, starting: Date(), days: 7)) ?? []
                }
            }
            for await loaded in group {
                matches.append(contentsOf: loaded)
            }
        }
        return Dictionary(grouping: matches, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.date < $1.date }
    }

    private func removeFavorite(_ favorite: FavoriteTeam) {
        guard let league = League.all.first(where: { $0.path == favorite.leaguePath }) else { return }
        let team = Team(
            id: favorite.teamID,
            displayName: favorite.displayName,
            shortDisplayName: favorite.displayName,
            abbreviation: favorite.abbreviation,
            logoURL: favorite.logoURL
        )
        prefs.toggleFavorite(team, in: league)
    }
}
