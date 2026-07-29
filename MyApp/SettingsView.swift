import SwiftUI

struct SettingsView: View {
    var body: some View {
        MoreView()
    }
}

struct PlaylistsSettingsView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showingAddPlaylist = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                Section("CONNECTED") {
                    if playlists.playlists.isEmpty {
                        Button { showingAddPlaylist = true } label: {
                            Label("Add M3U or Xtream Playlist", systemImage: "plus")
                                .foregroundStyle(Theme.accent)
                        }
                    } else {
                        ForEach(playlists.playlists) { playlist in
                            NavigationLink {
                                PlaylistDetailSettingsView(playlist: playlist)
                            } label: {
                                PlaylistConnectionRow(
                                    playlist: playlist,
                                    refresh: { Task { await playlists.refresh(playlist) } },
                                    edit: { },
                                    makeDefault: { },
                                    delete: { delete(playlist) }
                                )
                            }
                            .swipeActions {
                                Button(role: .destructive) { delete(playlist) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu { playlistActions(for: playlist) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .hidesScrollContentBackground()
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddPlaylist = true } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPlaylist) {
            AddPlaylistView { playlists.add($0) }
        }
        .refreshable { await playlists.refreshAll() }
    }

    @ViewBuilder private func playlistActions(for playlist: Playlist) -> some View {
        Button { Task { await playlists.refresh(playlist) } } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        Button { } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button { } label: {
            Label("Make Default", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) { delete(playlist) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func delete(_ playlist: Playlist) {
        guard let index = playlists.playlists.firstIndex(of: playlist) else { return }
        playlists.remove(at: IndexSet(integer: index))
    }
}

struct PlaylistDetailSettingsView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    let playlist: Playlist
    @State private var revealAddress = false

    private var currentPlaylist: Playlist {
        playlists.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(currentPlaylist.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.upcoming)
                    }
                    .padding(.vertical, 8)
                }

                Section("DETAILS") {
                    DetailValueRow(title: "Channel count", value: "\(playlists.channelCount(for: currentPlaylist))")
                    DetailValueRow(title: "Last refresh", value: playlists.isLoading(currentPlaylist) ? "Refreshing" : "Recently")
                    DetailValueRow(title: "Preferred playlist", value: "Off")
                    if let address = playlistAddress {
                        Button { revealAddress.toggle() } label: {
                            DetailValueRow(title: "Server address", value: revealAddress ? address : "Hidden")
                        }
                    }
                }

                Section("ACTIONS") {
                    Button { Task { await playlists.refresh(currentPlaylist) } } label: {
                        Label("Refresh playlist", systemImage: "arrow.clockwise")
                    }
                    Button { } label: {
                        Label("Edit credentials", systemImage: "key.fill")
                    }
                    Button { } label: {
                        Label("Preferred playlist", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) { deleteCurrentPlaylist() } label: {
                        Label("Delete playlist", systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .hidesScrollContentBackground()
        }
        .navigationTitle(currentPlaylist.name)
    }

    private var playlistAddress: String? {
        switch currentPlaylist.kind {
        case .m3u: currentPlaylist.m3uURL
        case .xtream: currentPlaylist.host
        }
    }

    private func deleteCurrentPlaylist() {
        guard let index = playlists.playlists.firstIndex(of: currentPlaylist) else { return }
        playlists.remove(at: IndexSet(integer: index))
    }
}

struct AppearancePlaybackSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        SettingsPage(title: "Appearance & Playback") {
            SettingsPanel(title: "APPEARANCE") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Theme")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    Picker("Theme", selection: Binding(get: { prefs.appearance }, set: { prefs.setAppearance($0) })) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(14)
            }

            SettingsPanel(title: "PLAYBACK") {
                Menu {
                    ForEach(StreamLanguage.all) { language in
                        Button { prefs.setDefaultStreamLanguage(language) } label: {
                            if prefs.isStreamLanguageSelected(language) {
                                Label(language.name, systemImage: "checkmark")
                            } else {
                                Text(language.name)
                            }
                        }
                    }
                } label: {
                    SettingsDisclosureRow(title: "Streaming Language", value: defaultStreamLanguageName)
                }
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Preferred Player", value: "Built-in")
                Divider().overlay(Theme.hairline)
                SettingsToggleRow(title: "Autoplay Next Channel", isOn: .constant(true))
                Divider().overlay(Theme.hairline)
                SettingsToggleRow(title: "Picture in Picture", isOn: .constant(true))
            }

            SettingsPanel(title: "SCORES") {
                SettingsToggleRow(title: "Spoiler-Free Mode", isOn: Binding(get: { prefs.spoilerFreeMode }, set: { prefs.setSpoilerFreeMode($0) }))
                Text("When spoiler-free mode is enabled, completed-game scores and result headlines are hidden.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                Divider().overlay(Theme.hairline)
                SettingsToggleRow(title: "Live Score Overlay", isOn: Binding(get: { prefs.showLiveScoreBadge }, set: { prefs.setShowLiveScoreBadge($0) }))
            }
        }
    }

    private var defaultStreamLanguageName: String {
        let selected = prefs.preferredStreamLanguages.first ?? "en"
        return StreamLanguage.all.first { $0.code == selected }?.name ?? "English"
    }
}

struct NotificationsCalendarSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var isExportingCalendar = false
    @State private var calendarExportMessage: String?
    @State private var showPaywall = false

    var body: some View {
        SettingsPage(title: "Notifications & Calendar") {
            SettingsPanel(title: "MASTER CONTROL") {
                HStack {
                    Text("Smart Alerts")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if entitlements.isPremium {
                        Toggle("Smart Alerts", isOn: Binding(get: { prefs.matchNotificationsEnabled }, set: { _ in toggleNotifications() }))
                            .labelsHidden()
                            .tint(Theme.accent)
                    } else {
                        Button("Premium") { showPaywall = true }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(14)
            }

            SettingsPanel(title: "GAME ALERTS") {
                Group {
                    Menu {
                        ForEach(MatchReminderLeadTime.allCases) { leadTime in
                            Button { updateReminderLeadTime(leadTime) } label: {
                                if prefs.matchReminderLeadTime == leadTime {
                                    Label(leadTime.label, systemImage: "checkmark")
                                } else {
                                    Text(leadTime.label)
                                }
                            }
                        }
                    } label: {
                        SettingsDisclosureRow(title: "Game starting", value: reminderValue)
                    }
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Game begins", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Score changes", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Close game", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Overtime or extra innings", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Final result", isOn: false)
                }
                .opacity(prefs.matchNotificationsEnabled ? 1 : 0.42)
                .disabled(!prefs.matchNotificationsEnabled)
            }

            SettingsPanel(title: "DAILY") {
                SettingsToggleRow(title: "Morning Briefing", isOn: Binding(get: { prefs.morningDigestEnabled }, set: { prefs.setMorningDigestEnabled($0) }))
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Briefing Time", value: "8:00 AM")
            }
            .opacity(prefs.matchNotificationsEnabled ? 1 : 0.42)

            SettingsPanel(title: "CALENDAR") {
                Button { Task { await exportFollowedGamesToCalendar() } } label: {
                    SettingsDisclosureRow(title: "Calendar Sync", value: calendarValue)
                }
                .disabled(isExportingCalendar)
                if let calendarExportMessage {
                    Text(calendarExportMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var reminderValue: String {
        switch prefs.matchReminderLeadTime {
        case .sixty: "1 hr"
        case .thirty: "30 min"
        case .ten: "10 min"
        case .five: "5 min"
        }
    }

    private var calendarValue: String {
        isExportingCalendar ? "Setting Up" : "Not connected"
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
        await MatchNotificationService.shared.syncNotifications(matches: matches, favorites: prefs.favoriteTeams, leadTime: prefs.matchReminderLeadTime)
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
            for await loaded in group { matches.append(contentsOf: loaded) }
        }
        return Dictionary(grouping: matches, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.date < $1.date }
    }
}

struct PrivacySyncSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        SettingsPage(title: "Privacy & Sync") {
            SettingsPanel(title: "ICLOUD") {
                SettingsToggleRow(title: "iCloud Sync", isOn: Binding(get: { prefs.cloudSyncEnabled }, set: { prefs.setCloudSyncEnabled($0) }))
                Text(prefs.cloudSyncEnabled ? "Last synced 3 minutes ago" : "Not syncing")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            SettingsPanel(title: "SYNCED DATA") {
                InfoTextRow("Preferences")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Favourite channels")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Followed teams and leagues")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Watch history")
            }

            SettingsPanel(title: "DEVICE-ONLY DATA") {
                InfoTextRow("Playlist credentials")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Authentication information")
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Theme.accent)
                Text("Playlist credentials remain encrypted in Keychain and are not uploaded to iCloud.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))

            SettingsPanel(title: "DATA CONTROLS") {
                SettingsDisclosureRow(title: "Clear Watch History")
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Reset Recommendations")
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Delete Local Data")
            }

            SettingsPanel(title: "ADVANCED") {
                Button { prefs.resetOnboarding() } label: {
                    SettingsDisclosureRow(title: "Redo Setup")
                }
            }
        }
    }
}

private struct PlaylistConnectionRow: View {
    @EnvironmentObject private var playlists: PlaylistStore
    let playlist: Playlist
    let refresh: () -> Void
    let edit: () -> Void
    let makeDefault: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(playlist.name)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(playlists.channelCount(for: playlist)) channels")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Text(playlists.isLoading(playlist) ? "Refreshing" : "Connected")
                    .foregroundStyle(playlists.isLoading(playlist) ? Theme.starting : Theme.upcoming)
                Text("·")
                Text("Updated recently")
                Spacer()
                Menu {
                    Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button(action: edit) { Label("Edit", systemImage: "pencil") }
                    Button(action: makeDefault) { Label("Make Default", systemImage: "checkmark.circle") }
                    Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 8)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(20)
            }
        }
        .navigationTitle(title)
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct StaticSwitchRow: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(isOn ? "On" : "Off")
                .font(.subheadline)
                .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct SettingsDisclosureRow: View {
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct DetailValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct InfoTextRow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
    }
}
