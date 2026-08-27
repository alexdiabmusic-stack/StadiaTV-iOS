#if os(tvOS)
import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @State private var showingAddPlaylist = false
    @State private var showingTeamEditor = false
    @State private var showingFantasyConnect = false
    @State private var showingFantasyDisconnect = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    playlistsSection
                    teamsSection
                    fantasySection
                    appearanceSection
                    streamingSection
                    setupSection
                }
                .listStyle(.grouped)
                .hidesScrollContentBackground()
            }
            .navigationTitle("Settings")
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $showingAddPlaylist) {
            AddPlaylistView { playlists.add($0) }
        }
        .fullScreenCover(isPresented: $showingTeamEditor) {
            TeamEditorView()
        }
        .sheet(isPresented: $showingFantasyConnect) {
            SleeperConnectSheet(channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages)
        }
        .confirmationDialog("Disconnect Sleeper?", isPresented: $showingFantasyDisconnect, titleVisibility: .visible) {
            Button("Disconnect Sleeper", role: .destructive) {
                Task { await fantasyStore.disconnectSleeper() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }


    // MARK: - Playlists

    private var playlistsSection: some View {
        Section {
            if playlists.playlists.isEmpty {
                Button { showingAddPlaylist = true } label: {
                    Label("Add Stream Playlist", systemImage: "plus")
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
                            Text(playlist.kind == .m3u ? (playlist.m3uURL ?? "M3U") : (playlist.host ?? "Stream Login"))
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
                Button { showingAddPlaylist = true } label: {
                    Label("Add Playlist", systemImage: "plus")
                        .foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.surface)
            }
        } header: {
            Label("Playlists", systemImage: "list.and.film")
        }
    }

    // MARK: - Teams

    private var teamsSection: some View {
        Section {
            Button { showingTeamEditor = true } label: {
                HStack {
                    Label(teamsSummary, systemImage: "star.fill")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.surface)
        } header: {
            Label("My Teams & Leagues", systemImage: "star.fill")
        }
    }

    // MARK: - Fantasy

    private var fantasySection: some View {
        Section {
            if let connection = fantasyStore.currentConnection {
                VStack(alignment: .leading, spacing: 4) {
                    Label(connection.displayName ?? connection.username ?? "Sleeper", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.textPrimary)
                    Text("Sleeper connected")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.surface)

                if !fantasyStore.leagues.isEmpty {
                    Picker("Default League", selection: Binding(
                        get: { fantasyStore.selectedLeague?.id ?? fantasyStore.leagues.first?.id ?? "" },
                        set: { leagueID in Task { await fantasyStore.selectLeague(id: leagueID, channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages) } }
                    )) {
                        ForEach(fantasyStore.leagues) { league in
                            Text(league.name).tag(league.id)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }

                Button(role: .destructive) { showingFantasyDisconnect = true } label: {
                    Label("Disconnect Sleeper", systemImage: "xmark.circle")
                }
                .listRowBackground(Theme.surface)
            } else {
                Button { showingFantasyConnect = true } label: {
                    Label("Connect Sleeper", systemImage: "star.circle")
                        .foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.surface)
            }

            Toggle(isOn: Binding(
                get: { fantasyStore.settings.showFantasyOnHome },
                set: { value in Task { await fantasyStore.setShowFantasyOnHome(value) } }
            )) {
                Label("Show on Home", systemImage: "house.fill")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .listRowBackground(Theme.surface)

            Toggle(isOn: Binding(
                get: { fantasyStore.settings.showFantasyIndicatorsInLive },
                set: { value in Task { await fantasyStore.setShowFantasyIndicatorsInLive(value) } }
            )) {
                Label("Live Indicators", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .listRowBackground(Theme.surface)

            Toggle(isOn: Binding(
                get: { fantasyStore.settings.showFantasyIndicatorsInGuide },
                set: { value in Task { await fantasyStore.setShowFantasyIndicatorsInGuide(value) } }
            )) {
                Label("Guide Indicators", systemImage: "rectangle.grid.2x2")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .listRowBackground(Theme.surface)
        } header: {
            Label("Fantasy", systemImage: "star.circle.fill")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: Binding(
                get: { prefs.appearance },
                set: { prefs.setAppearance($0) }
            )) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .listRowBackground(Theme.surface)

            Toggle(isOn: Binding(
                get: { prefs.spoilerFreeMode },
                set: { prefs.setSpoilerFreeMode($0) }
            )) {
                Label("Spoiler-Free Mode", systemImage: "eye.slash.fill")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .listRowBackground(Theme.surface)
        } header: {
            Label("Appearance", systemImage: "paintbrush.fill")
        }
    }

    // MARK: - Streaming

    private var streamingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { prefs.showLiveScoreBadge },
                set: { prefs.setShowLiveScoreBadge($0) }
            )) {
                Label("Live Score Overlay", systemImage: "sportscourt.fill")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .listRowBackground(Theme.surface)

            Toggle(isOn: Binding(
                get: { prefs.cloudSyncEnabled },
                set: { prefs.setCloudSyncEnabled($0) }
            )) {
                Label("iCloud Sync", systemImage: "icloud.fill")
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .listRowBackground(Theme.surface)
        } header: {
            Label("Streaming & Privacy", systemImage: "play.tv.fill")
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
            Text("Re-run setup to choose sports, leagues, and favorite teams.")
        }
    }

    private var teamsSummary: String {
        let count = prefs.favoriteTeams.count
        return count == 0 ? "Choose Favourite Teams" : "\(count) favourite \(count == 1 ? "team" : "teams")"
    }
}
#endif
