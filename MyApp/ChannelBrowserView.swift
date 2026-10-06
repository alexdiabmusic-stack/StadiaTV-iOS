import SwiftUI

// MARK: - Scope

/// Identifies what set of channels a ChannelBrowserView should display.
enum ChannelBrowserScope {
    case favorites
    case allChannels
    case customGroup(id: String, name: String)
    case providerGroup(providerID: UUID, groupTitle: String, providerName: String)

    var title: String {
        switch self {
        case .favorites:                               return "Favourites"
        case .allChannels:                             return "All Channels"
        case .customGroup(_, let name):                return name
        case .providerGroup(_, let title, _):          return title
        }
    }

    /// Key used to persist per-scope sort choice in UserDefaults.
    var sortStorageKey: String {
        switch self {
        case .favorites:                               return "bannertv.sort.favorites"
        case .allChannels:                             return "bannertv.sort.all"
        case .customGroup(let id, _):                  return "bannertv.sort.cg.\(id)"
        case .providerGroup(let pid, let g, _):        return "bannertv.sort.pg.\(pid).\(g)"
        }
    }

    var defaultSortOrder: ChannelSortOrder {
        switch self {
        case .favorites:   return .favoritesFirst
        case .customGroup: return .custom
        default:           return .providerOrder
        }
    }

    var emptyMessage: String {
        switch self {
        case .favorites:   return "No favourite channels yet.\nSwipe right on any channel to add one."
        case .allChannels: return "No channels loaded from your playlists."
        case .customGroup: return "This group has no channels yet.\nUse the context menu on any channel to add it."
        case .providerGroup: return "No channels in this group."
        }
    }
}

// MARK: - ChannelBrowserView

/// Lazy channel list for a given ChannelBrowserScope.
/// Supports search, sort, context menus (Favorite, Add to Group, Rename, Hide, Info).
struct ChannelBrowserView: View {
    let scope: ChannelBrowserScope
    let onPlay: (Channel, [Channel]) -> Void
    @Binding var isPickingMultiscreen: Bool
    @Binding var selectedMultiChannels: [Channel]

    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var channelPrefs: ChannelPreferencesStore
    @EnvironmentObject private var customGroups: CustomGroupStore
    @EnvironmentObject private var watchStore: WatchStore

    @State private var query = ""
    @State private var sortOrder: ChannelSortOrder
    private let sortStorageKey: String

    @State private var channelToRename: Channel?
    @State private var renameText = ""
    @State private var channelForGroup: Channel?
    @State private var channelForInfo: Channel?
    @StateObject private var model = ChannelBrowserModel()
    @State private var hasComputedOnce = false

    init(scope: ChannelBrowserScope,
         onPlay: @escaping (Channel, [Channel]) -> Void,
         isPickingMultiscreen: Binding<Bool>,
         selectedMultiChannels: Binding<[Channel]>) {
        self.scope = scope
        self.onPlay = onPlay
        self._isPickingMultiscreen = isPickingMultiscreen
        self._selectedMultiChannels = selectedMultiChannels
        self.sortStorageKey = scope.sortStorageKey
        let saved = UserDefaults.standard.string(forKey: scope.sortStorageKey)
        let initial = saved.flatMap(ChannelSortOrder.init(rawValue:)) ?? scope.defaultSortOrder
        self._sortOrder = State(initialValue: initial)
    }

    // MARK: - Data

    /// Changes whenever the list's inputs do; drives `model.update`.
    private var inputKey: String {
        var groupHash = 0
        if case .customGroup(let id, _) = scope {
            groupHash = customGroups.groups.first(where: { $0.id == id })?.channelIDs.hashValue ?? 0
        }
        return "\(store.channelsRevision)|\(channelPrefs.revision)|\(groupHash)|\(sortOrder.rawValue)|\(query)"
    }

    private var modelInput: ChannelBrowserModel.Input {
        let source: ChannelBrowserModel.Input.Source
        var byPlaylist: [Channel] = []
        switch scope {
        case .favorites:
            source = .favorites
        case .allChannels:
            source = .all
        case .customGroup(let id, _):
            source = .ids(customGroups.groups.first(where: { $0.id == id })?.channelIDs ?? [])
        case .providerGroup(let providerID, let groupTitle, _):
            source = .playlistGroup(providerID, groupTitle)
            byPlaylist = store.channelsByPlaylist[providerID] ?? []
        }
        return ChannelBrowserModel.Input(
            source: source,
            channels: store.allChannels,
            byPlaylist: byPlaylist,
            channelsByID: store.channelsByID,
            hiddenIDs: channelPrefs.hiddenChannelIDs,
            favoriteIDs: channelPrefs.favoriteChannelIDs,
            customNames: channelPrefs.customNames,
            query: query,
            sortOrder: sortOrder
        )
    }

    private var displayChannels: [Channel] { model.displayChannels }

    // MARK: - Body

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if displayChannels.isEmpty && (model.isComputing || !hasComputedOnce) {
                List {
                    ForEach(0..<8, id: \.self) { _ in
                        SkeletonRow().listRowBackground(Theme.background)
                    }
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
                .allowsHitTesting(false)
            } else if displayChannels.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(displayChannels) { channel in
                        channelRow(channel)
                            .listRowBackground(Theme.background)
                            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.md, bottom: 0, trailing: Theme.Spacing.md))
                            #if !os(tvOS)
                            .listRowSeparatorTint(Theme.hairline)
                            // Separators start at the text, not under the logo tile.
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 56 + Theme.Spacing.sm }
                            #endif
                    }
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
            }
        }
        .navigationTitle(scope.title)
        .inlineNavigationTitle()
        .searchable(text: $query, prompt: "Search")
        .toolbar { sortMenu }
        .onChange(of: sortOrder) { _, new in
            UserDefaults.standard.set(new.rawValue, forKey: sortStorageKey)
        }
        .onChange(of: inputKey, initial: true) {
            model.update(modelInput)
        }
        .onChange(of: model.isComputing) { _, computing in
            if !computing { hasComputedOnce = true }
        }
        // Rename alert
        .alert("Rename Channel", isPresented: Binding(
            get: { channelToRename != nil },
            set: { if !$0 { channelToRename = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let ch = channelToRename {
                    channelPrefs.setCustomName(renameText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : renameText, for: ch.id)
                }
                channelToRename = nil
            }
            Button("Cancel", role: .cancel) { channelToRename = nil }
        } message: {
            Text("Enter a custom display name for this channel. Leave blank to reset to the original name.")
        }
        // Add-to-group sheet
        .sheet(item: $channelForGroup) { channel in
            AddToGroupSheet(channel: channel)
        }
        // Channel info sheet
        .sheet(item: $channelForInfo) { channel in
            ChannelInfoSheet(channel: channel)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        let displayed = withCustomName(channel)
        let isFavorite = channelPrefs.isFavorite(channel.id)
        ChannelListRow(
            channel: displayed,
            action: { handleTap(channel) },
            isFavorite: isFavorite,
            isPicking: isPickingMultiscreen,
            isSelected: selectedMultiChannels.contains { $0.id == channel.id },
            channelNumber: sortOrder == .channelNumber ? ChannelBrowserModel.channelNumber(displayed.name) : nil
        )
        .contextMenu { contextMenu(for: channel) }
        #if !os(tvOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                channelPrefs.toggleFavorite(channelID: channel.id)
            } label: {
                Label(isFavorite ? "Unfavourite" : "Favourite", systemImage: isFavorite ? "star.slash" : "star")
            }
            .tint(Theme.starting)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                channelPrefs.setHidden(true, for: channel.id)
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            Button {
                channelForGroup = channel
            } label: {
                Label("Group", systemImage: "folder.badge.plus")
            }
            .tint(Theme.accent)
            Button {
                renameText = channelPrefs.customName(for: channel.id) ?? channel.name
                channelToRename = channel
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Theme.textTertiary)
        }
        #endif
        // Logo tiles are ≤ 64 pt; 192 px covers @3x.
        .onAppear { model.prefetchLogos(after: channel.id, maxPixelSize: 192) }
    }

    @ViewBuilder
    private func contextMenu(for channel: Channel) -> some View {
        let isFav = channelPrefs.isFavorite(channel.id)
        Button {
            channelPrefs.toggleFavorite(channelID: channel.id)
        } label: {
            Label(isFav ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: isFav ? "heart.slash" : "heart")
        }

        Button {
            channelForGroup = channel
        } label: {
            Label("Add to Group…", systemImage: "folder.badge.plus")
        }

        Divider()

        Button {
            renameText = channelPrefs.customName(for: channel.id) ?? channel.name
            channelToRename = channel
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        if channelPrefs.customName(for: channel.id) != nil {
            Button {
                channelPrefs.setCustomName(nil, for: channel.id)
            } label: {
                Label("Reset Name", systemImage: "arrow.counterclockwise")
            }
        }

        Divider()

        Button(role: .destructive) {
            channelPrefs.setHidden(true, for: channel.id)
        } label: {
            Label("Hide Channel", systemImage: "eye.slash")
        }

        Button {
            channelForInfo = channel
        } label: {
            Label("Channel Info", systemImage: "info.circle")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .compatTopBarTrailing) {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(ChannelSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
            .accessibilityLabel("Sort channels")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            systemImage: query.isEmpty ? "play.tv" : "magnifyingglass",
            title: query.isEmpty ? scope.title : "No Results",
            message: query.isEmpty ? scope.emptyMessage : "No channels match \"\(query)\"."
        )
    }

    // MARK: - Helpers

    private func handleTap(_ channel: Channel) {
        if isPickingMultiscreen {
            if let idx = selectedMultiChannels.firstIndex(where: { $0.id == channel.id }) {
                selectedMultiChannels.remove(at: idx)
            } else if selectedMultiChannels.count < 4 {
                selectedMultiChannels.append(channel)
            }
        } else {
            PlaybackTapClock.record()
            onPlay(channel, displayChannels)
        }
    }

    /// Returns the channel with any user-applied custom name substituted in.
    private func withCustomName(_ channel: Channel) -> Channel {
        guard let custom = channelPrefs.customNames[channel.id] else { return channel }
        return Channel(id: channel.id, name: custom, streamURL: channel.streamURL,
                       logoURL: channel.logoURL, group: channel.group,
                       playlistID: channel.playlistID, playlistName: channel.playlistName,
                       tvgId: channel.tvgId, httpHeaders: channel.httpHeaders)
    }
}

// MARK: - AddToGroupSheet

struct AddToGroupSheet: View {
    let channel: Channel
    @EnvironmentObject private var customGroups: CustomGroupStore
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""
    @State private var showingCreate = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    if customGroups.groups.isEmpty {
                        Text("No groups yet. Tap + to create one.")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.surface)
                    }
                    ForEach(customGroups.groups) { group in
                        let inGroup = group.channelIDs.contains(channel.id)
                        Button {
                            if inGroup {
                                customGroups.removeChannel(channel.id, from: group.id)
                            } else {
                                customGroups.addChannel(channel.id, to: group.id)
                            }
                        } label: {
                            HStack {
                                Text(group.name)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if inGroup {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Theme.surface)
                        #if !os(tvOS)
                        .listRowSeparatorTint(Theme.hairline)
                        #endif
                    }
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
            }
            .navigationTitle("Add to Group")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New group")
                }
            }
            .alert("New Group", isPresented: $showingCreate) {
                TextField("Group name", text: $newGroupName)
                Button("Create") {
                    let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        let id = customGroups.createGroup(named: trimmed)
                        customGroups.addChannel(channel.id, to: id)
                    }
                    newGroupName = ""
                }
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
        }
        .tint(Theme.accent)
    }
}

// MARK: - ChannelInfoSheet

struct ChannelInfoSheet: View {
    let channel: Channel
    @EnvironmentObject private var channelPrefs: ChannelPreferencesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    Section("Channel") {
                        infoRow("Name", channel.name)
                        if let custom = channelPrefs.customName(for: channel.id) {
                            infoRow("Custom Name", custom)
                        }
                        if let group = channel.group { infoRow("Group", group) }
                        infoRow("Playlist", channel.playlistName)
                    }
                    .listRowBackground(Theme.surface)

                    Section("Stream") {
                        infoRow("URL", channel.streamURL.absoluteString)
                    }
                    .listRowBackground(Theme.surface)
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
            }
            .navigationTitle("Channel Info")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}
