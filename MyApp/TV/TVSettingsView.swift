#if os(tvOS)
import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showingAddPlaylist = false
    @State private var showingTeamEditor = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    playlistsSection
                    teamsSection
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
