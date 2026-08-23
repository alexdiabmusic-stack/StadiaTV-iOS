import SwiftUI

/// Navigation root for the Live TV tab.
/// Shows Favourites, All Channels, user-created custom groups, and
/// per-provider group sections — each linking to a ChannelBrowserView.
struct LiveBrowserView: View {
    let onPlay: (Channel, [Channel]) -> Void
    let refreshAction: () async -> Void
    @Binding var isPickingMultiscreen: Bool
    @Binding var selectedMultiChannels: [Channel]

    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var channelPrefs: ChannelPreferencesStore
    @EnvironmentObject private var customGroups: CustomGroupStore
    @EnvironmentObject private var groupPrefs: GroupPreferencesStore

    @State private var editMode: EditMode = .inactive
    @State private var showingCreateGroup = false
    @State private var newGroupName = ""
    @State private var groupToRename: CustomGroup?
    @State private var renameText = ""

    var body: some View {
        List {
            // Continue Watching (only when not editing)
            if editMode == .inactive, !watchStore.history.isEmpty {
                Section {
                    ContinueWatchingSection(entries: watchStore.history) { channel in
                        onPlay(channel, [channel])
                    }
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
                }
            }

            // Fixed scopes
            Section {
                scopeRow(
                    title: "Favourites",
                    systemImage: "heart.fill",
                    count: channelPrefs.favoriteCount,
                    scope: .favorites
                )
                scopeRow(
                    title: "All Channels",
                    systemImage: "list.bullet",
                    count: store.allChannels.filter { !channelPrefs.isHidden($0.id) }.count,
                    scope: .allChannels
                )
            }

            // Custom groups
            Section {
                ForEach(customGroups.groups) { group in
                    NavigationLink {
                        ChannelBrowserView(
                            scope: .customGroup(id: group.id, name: group.name),
                            onPlay: onPlay,
                            isPickingMultiscreen: $isPickingMultiscreen,
                            selectedMultiChannels: $selectedMultiChannels
                        )
                    } label: {
                        BrowserRow(title: group.name, systemImage: "folder.fill",
                                   count: group.channelIDs.count)
                    }
                    .listRowBackground(Theme.surface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            customGroups.deleteGroup(group.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            renameText = group.name
                            groupToRename = group
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
                .onMove { customGroups.moveGroups(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("My Groups")
                    Spacer()
                    Button {
                        showingCreateGroup = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Per-provider sections
            ForEach(store.playlists) { playlist in
                providerSection(for: playlist)
            }
        }
        .listStyle(.plain)
        .hidesScrollContentBackground()
        .background(Theme.background)
        .environment(\.editMode, $editMode)
        .refreshable { await refreshAction() }
        .toolbar { editToolbar }
        .animation(.snappy, value: customGroups.groups.map(\.id))
        // Create group alert
        .alert("New Group", isPresented: $showingCreateGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { customGroups.createGroup(named: trimmed) }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
        // Rename group alert
        .alert("Rename Group", isPresented: Binding(
            get: { groupToRename != nil },
            set: { if !$0 { groupToRename = nil } }
        )) {
            TextField("Group name", text: $renameText)
            Button("Save") {
                if let g = groupToRename {
                    customGroups.renameGroup(g.id, to: renameText.trimmingCharacters(in: .whitespaces))
                }
                groupToRename = nil
            }
            Button("Cancel", role: .cancel) { groupToRename = nil }
        }
    }

    // MARK: - Provider section

    @ViewBuilder
    private func providerSection(for playlist: Playlist) -> some View {
        let channels = store.channelsByPlaylist[playlist.id] ?? []
        if !channels.isEmpty {
            let groups = providerGroups(in: channels, providerID: playlist.id)
            let visible = editMode == .active ? groups : groups.filter { !groupPrefs.isHidden($0.id) }
            if !visible.isEmpty {
                Section(playlist.name) {
                    ForEach(visible) { group in
                        NavigationLink {
                            ChannelBrowserView(
                                scope: .providerGroup(
                                    providerID: playlist.id,
                                    groupTitle: group.title,
                                    providerName: playlist.name
                                ),
                                onPlay: onPlay,
                                isPickingMultiscreen: $isPickingMultiscreen,
                                selectedMultiChannels: $selectedMultiChannels
                            )
                        } label: {
                            BrowserRow(
                                title: groupPrefs.customName(for: group.id) ?? group.title,
                                systemImage: "rectangle.stack.fill",
                                count: group.count,
                                isHidden: groupPrefs.isHidden(group.id)
                            )
                        }
                        .listRowBackground(groupPrefs.isHidden(group.id)
                                           ? Theme.surface.opacity(0.5) : Theme.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                groupPrefs.setHidden(!groupPrefs.isHidden(group.id), for: group.id)
                            } label: {
                                Label(groupPrefs.isHidden(group.id) ? "Unhide" : "Hide",
                                      systemImage: groupPrefs.isHidden(group.id) ? "eye" : "eye.slash")
                            }
                            .tint(groupPrefs.isHidden(group.id) ? .green : .secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(editMode == .active ? "Done" : "Edit") {
                withAnimation { editMode = editMode == .active ? .inactive : .active }
            }
        }
    }

    // MARK: - Helpers

    private func scopeRow(title: String, systemImage: String, count: Int, scope: ChannelBrowserScope) -> some View {
        NavigationLink {
            ChannelBrowserView(
                scope: scope,
                onPlay: onPlay,
                isPickingMultiscreen: $isPickingMultiscreen,
                selectedMultiChannels: $selectedMultiChannels
            )
        } label: {
            BrowserRow(title: title, systemImage: systemImage, count: count)
        }
        .listRowBackground(Theme.surface)
    }

    /// Returns deduplicated groups with counts, sorted by user-set order then alphabetically.
    private func providerGroups(in channels: [Channel], providerID: UUID) -> [ProviderGroupEntry] {
        let grouped = Dictionary(grouping: channels) { $0.group ?? $0.playlistName }
        return grouped.map { title, chs in
            let id = "\(providerID.uuidString)|\(title)"
            return ProviderGroupEntry(id: id, title: title, count: chs.count)
        }
        .sorted { a, b in
            let ao = groupPrefs.sortOrder(for: a.id) ?? Int.max
            let bo = groupPrefs.sortOrder(for: b.id) ?? Int.max
            if ao != Int.max || bo != Int.max { return ao < bo }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}

// MARK: - Supporting types

private struct ProviderGroupEntry: Identifiable {
    let id: String
    let title: String
    let count: Int
}

// MARK: - BrowserRow

/// A single row in the LiveBrowserView hierarchy list.
struct BrowserRow: View {
    let title: String
    let systemImage: String
    let count: Int
    var isHidden: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isHidden ? Theme.textSecondary : Theme.accent)
                .frame(width: 28)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(isHidden ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}
