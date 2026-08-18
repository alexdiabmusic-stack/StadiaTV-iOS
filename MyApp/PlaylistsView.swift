import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if store.playlists.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPlaylistView { store.add($0) }
            }
        }
        .tint(Theme.accent)
    }

    private var list: some View {
        List {
            ForEach(store.playlists) { playlist in
                PlaylistRow(playlist: playlist)
                    .listRowBackground(Theme.surface)
                    #if !os(tvOS)
                    .listRowSeparatorTint(Theme.hairline)
                    #endif
            }
            .onDelete { store.remove(at: $0) }
        }
        .listStyle(.plain)
        .hidesScrollContentBackground()
        .refreshable { await store.refreshAll() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.and.film")
                .font(.system(size: Theme.scaled(50)))
                .foregroundStyle(Theme.accent)
            Text("No Playlists Yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Add an M3U link or stream login to connect your personal channels.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showingAdd = true
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }
}

private struct PlaylistRow: View {
    @EnvironmentObject private var store: PlaylistStore
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playlist.kind == .m3u ? "link" : "person.badge.key.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isLoading(playlist) {
                ProgressView().tint(Theme.accent)
            } else {
                Text("\(store.channelCount(for: playlist))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch playlist.kind {
        case .m3u: return playlist.m3uURL ?? "M3U"
        case .xtream: return playlist.host ?? "Stream Login"
        }
    }
}

// MARK: - Add playlist

struct AddPlaylistView: View {
    enum Mode: String, CaseIterable { case m3u = "M3U", xtream = "Stream Login" }

    let initialPlaylist: Playlist?
    let onAdd: (Playlist) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode
    @State private var name: String
    // M3U
    @State private var m3uURL: String
    // Xtream
    @State private var host: String
    @State private var username = ""
    @State private var password = ""

    init(initialPlaylist: Playlist? = nil, onAdd: @escaping (Playlist) -> Void) {
        self.initialPlaylist = initialPlaylist
        self.onAdd = onAdd
        _mode = State(initialValue: initialPlaylist?.kind == .xtream ? .xtream : .m3u)
        _name = State(initialValue: initialPlaylist?.name ?? "")
        _m3uURL = State(initialValue: initialPlaylist?.m3uURL ?? "")
        _host = State(initialValue: initialPlaylist?.host ?? "")
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch mode {
        case .m3u:
            return isSupportedPlaylistURL(m3uURL)
        case .xtream:
            return isSupportedPlaylistURL(host) && !username.isEmpty && !password.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Theme.surface)

                Section("Name") {
                    TextField("My Playlist", text: $name)
                }
                .listRowBackground(Theme.surface)

                switch mode {
                case .m3u:
                    Section {
                        TextField("http://example.com/playlist.m3u", text: $m3uURL)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("M3U URL")
                    } footer: {
                        Text("Paste the M3U playlist URL provided by your subscription service — such as Plex, Channels DVR, fuboTV, or a cable/satellite provider that offers a live TV export.")
                    }
                    .listRowBackground(Theme.surface)
                case .xtream:
                    Section {
                        TextField("http://server.com:8080", text: $host)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("Server")
                    } footer: {
                        Text("Enter the server address for your subscription service. Compatible with Plex, Channels DVR, and other services that support the Xtream Codes API.")
                    }
                    .listRowBackground(Theme.surface)
                    Section("Credentials") {
                        TextField("Username", text: $username)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    }
                    .listRowBackground(Theme.surface)
                }

                Section {
                    Text("Stadia TV does not provide, host, or sell streaming content. This feature is intended for use with paid subscription services and personal DVR systems (such as Plex or Channels DVR) that you already subscribe to and that permit playlist export.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.background)
            }
            .hidesScrollContentBackground()
            .background(Theme.background)
            .navigationTitle(initialPlaylist == nil ? "Add Playlist" : "Edit Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(initialPlaylist == nil ? "Add" : "Save") { add() }.disabled(!isValid)
                }
            }
        }
        .tint(Theme.accent)
    }

    private func isSupportedPlaylistURL(_ value: String) -> Bool {
        guard let scheme = URL(string: value.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func add() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let playlist: Playlist
        switch mode {
        case .m3u:
            playlist = Playlist(id: initialPlaylist?.id ?? UUID(), name: trimmedName, kind: .m3u,
                                m3uURL: m3uURL.trimmingCharacters(in: .whitespaces),
                                credentialID: initialPlaylist?.credentialID)
        case .xtream:
            playlist = Playlist(id: initialPlaylist?.id ?? UUID(), name: trimmedName, kind: .xtream,
                                host: host.trimmingCharacters(in: .whitespaces),
                                credentialID: initialPlaylist?.credentialID,
                                username: username.trimmingCharacters(in: .whitespaces),
                                password: password)
        }
        onAdd(playlist)
        dismiss()
    }
}
