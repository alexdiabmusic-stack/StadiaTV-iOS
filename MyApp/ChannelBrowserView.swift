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
        case .favorites:                               return "stadiatv.sort.favorites"
        case .allChannels:                             return "stadiatv.sort.all"
        case .customGroup(let id, _):                  return "stadiatv.sort.cg.\(id)"
        case .providerGroup(let pid, let g, _):        return "stadiatv.sort.pg.\(pid).\(g)"
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
        case .favorites:   return "No favourite channels yet.\nTap ♥ on any channel to add one."
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

    private var baseChannels: [Channel] {
        switch scope {
        case .favorites:
            let favIDs = Set(channelPrefs.favoriteChannelIDs)
            return store.allChannels.filter { favIDs.contains($0.id) }

        case .allChannels:
            return store.allChannels.filter { !channelPrefs.isHidden($0.id) }

        case .customGroup(let id, _):
            guard let group = customGroups.groups.first(where: { $0.id == id }) else { return [] }
            let byID = Dictionary(uniqueKeysWithValues: store.allChannels.map { ($0.id, $0) })
            return group.channelIDs.compactMap { byID[$0] }

        case .providerGroup(let providerID, let groupTitle, _):
            return (store.channelsByPlaylist[providerID] ?? [])
                .filter { ($0.group ?? "") == groupTitle && !channelPrefs.isHidden($0.id) }
        }
    }

    private var displayChannels: [Channel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = q.isEmpty ? baseChannels : baseChannels.filter {
            effectiveName($0).localizedCaseInsensitiveContains(q)
        }

        switch sortOrder {
        case .providerOrder:
            return filtered
        case .nameAZ:
            return filtered.sorted {
                effectiveName($0).localizedCaseInsensitiveCompare(effectiveName($1)) == .orderedAscending
            }
        case .nameZA:
            return filtered.sorted {
                effectiveName($0).localizedCaseInsensitiveCompare(effectiveName($1)) == .orderedDescending
            }
        case .channelNumber:
            return filtered.sorted {
                (channelNumber(effectiveName($0)) ?? Int.max) < (channelNumber(effectiveName($1)) ?? Int.max)
            }
        case .favoritesFirst:
            let favIDs = Set(channelPrefs.favoriteChannelIDs)
            return filtered.sorted { a, b in
                let aFav = favIDs.contains(a.id), bFav = favIDs.contains(b.id)
                if aFav != bFav { return aFav }
                return effectiveName(a).localizedCaseInsensitiveCompare(effectiveName(b)) == .orderedAscending
            }
        case .custom:
            return filtered   // baseChannels already in custom order for .customGroup scope
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if displayChannels.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(displayChannels) { channel in
                        channelRow(channel)
                            .listRowBackground(Theme.surface)
                            .listRowSeparatorTint(Theme.hairline)
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
        ChannelListRow(
            channel: displayed,
            action: { handleTap(channel) },
            isFavorite: channelPrefs.isFavorite(channel.id),
            isPicking: isPickingMultiscreen,
            isSelected: selectedMultiChannels.contains { $0.id == channel.id },
            onToggleFavorite: { channelPrefs.toggleFavorite(channelID: channel.id) }
        )
        .contextMenu { contextMenu(for: channel) }
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
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(ChannelSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: query.isEmpty ? "play.tv" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)
            Text(query.isEmpty ? scope.emptyMessage : "No channels match \"\(query)\".")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
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
            onPlay(channel, displayChannels)
        }
    }

    /// Returns the channel with any user-applied custom name substituted in.
    private func withCustomName(_ channel: Channel) -> Channel {
        guard let custom = channelPrefs.customName(for: channel.id) else { return channel }
        return Channel(id: channel.id, name: custom, streamURL: channel.streamURL,
                       logoURL: channel.logoURL, group: channel.group,
                       playlistID: channel.playlistID, playlistName: channel.playlistName)
    }

    private func effectiveName(_ channel: Channel) -> String {
        channelPrefs.customName(for: channel.id) ?? channel.name
    }

    private func channelNumber(_ name: String) -> Int? {
        guard let match = name.range(of: #"^\s*(\d+)\s*[.\-|)]\s*"#, options: .regularExpression),
              let numRange = name.range(of: #"\d+"#, options: .regularExpression, range: match)
        else { return nil }
        return Int(name[numRange])
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
                        .listRowSeparatorTint(Theme.hairline)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
