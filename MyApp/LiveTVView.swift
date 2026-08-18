import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @State private var query = ""
    @State private var playingChannel: Channel?
    @State private var isPickingMultiscreen = false
    @State private var selectedMultiChannels: [Channel] = []
    @State private var multiscreenSession: MultiscreenSession?
    @State private var filter = ChannelFilter()
    @State private var showingFilters = false

    private var availableCategories: [ChannelCategory] {
        ChannelFilterEngine.availableOptions(in: store.allChannels).categories
    }

    private var filteredChannels: [Channel] {
        let channels = store.allChannels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return ChannelFilterEngine.apply(filter, query: query, to: channels,
                                         favoriteChannelIDs: Set(favoriteChannels.map(\.id)))
    }

    private var groupedChannels: [(String, [Channel])] {
        let grouped = Dictionary(grouping: filteredChannels) { channel in
            channel.group?.isEmpty == false ? channel.group! : channel.playlistName
        }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private var favoriteChannels: [Channel] {
        watchStore.favorites.compactMap(\.channel)
    }

    private var selectedChannelIDs: Set<String> {
        Set(selectedMultiChannels.map(\.id))
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                if store.playlists.isEmpty {
                    emptyPlaylistState
                } else if store.allChannels.isEmpty && !store.loadingPlaylistIDs.isEmpty {
                    ProgressView().tint(Theme.accent)
                } else if store.allChannels.isEmpty {
                    noChannelsState
                } else {
                    VStack(spacing: 0) {
                        filterBar
                        if filteredChannels.isEmpty {
                            noFilterResultsState
                        } else {
                            channelList
                        }
                    }
                }

                if isPickingMultiscreen {
                    multiscreenFooter
                }
            }
            .navigationTitle("Live TV")
            .searchToolbar()
            .searchable(text: $query, prompt: "Search channels")
            .refreshable { await store.refreshAll() }
            .toolbar {
                if store.allChannels.count >= 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            toggleMultiscreenPicking()
                        } label: {
                            Image(systemName: isPickingMultiscreen ? "checkmark.rectangle.stack" : "rectangle.grid.2x2")
                        }
                        .accessibilityLabel(isPickingMultiscreen ? "Finish multiscreen selection" : "Select multiscreen sources")
                    }
                }
            }
            .fullScreenCover(item: $playingChannel) { channel in
                PlayerView(channel: channel)
            }
            .fullScreenCover(item: $multiscreenSession) { session in
                MultiScreenPlayerView(channels: session.channels)
            }
            .sheet(isPresented: $showingFilters) {
                ChannelFiltersSheet(filter: $filter,
                                    channels: store.allChannels,
                                    playlists: store.playlists)
            }
        }
        .tint(Theme.accent)
    }

    /// Compact bar with the filter entry point and quick toggles, so long
    /// playlists can be narrowed without endless scrolling.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableCategories.prefix(10)) { category in
                    filterChip(title: category.rawValue,
                               systemImage: category.systemImage,
                               isSelected: filter.categories.contains(category)) {
                        withAnimation(.snappy) { toggleCategory(category) }
                    }
                }
                filterChip(title: filter.activeCount > 0 ? "Filters · \(filter.activeCount)" : "Filters",
                           systemImage: "line.3.horizontal.decrease.circle.fill",
                           isSelected: filter.activeCount > 0) {
                    showingFilters = true
                }
                filterChip(title: "Favourites",
                           systemImage: filter.favoritesOnly ? "heart.fill" : "heart",
                           isSelected: filter.favoritesOnly) {
                    withAnimation(.snappy) { filter.favoritesOnly.toggle() }
                }
                if filter.isActive {
                    filterChip(title: "Clear", systemImage: "xmark.circle.fill", isSelected: false) {
                        withAnimation(.snappy) { filter = ChannelFilter() }
                    }
                }
                Spacer(minLength: 0)
                Text("\(filteredChannels.count) channels")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.background)
    }

    private func toggleCategory(_ category: ChannelCategory) {
        if filter.categories.contains(category) {
            filter.categories.remove(category)
        } else {
            filter.categories.insert(category)
        }
    }

    private func filterChip(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private var noFilterResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: Theme.scaled(40)))
                .foregroundStyle(Theme.textSecondary)
            Text("No channels match your filters.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Button("Clear Filters") {
                withAnimation(.snappy) {
                    filter = ChannelFilter()
                    query = ""
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Spacer()
        }
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                if !isSearching && !filter.isActive && !watchStore.history.isEmpty {
                    ContinueWatchingSection(entries: watchStore.history) { channel in
                        handleTap(channel)
                    }
                }

                if !isSearching && !filter.isActive && !favoriteChannels.isEmpty {
                    Section {
                        ForEach(favoriteChannels) { channel in
                            row(for: channel)
                        }
                    } header: {
                        sectionHeader(title: "Favourites", count: favoriteChannels.count)
                    }
                }

                ForEach(groupedChannels, id: \.0) { group, channels in
                    Section {
                        ForEach(channels) { channel in
                            row(for: channel)
                        }
                    } header: {
                        sectionHeader(title: group, count: channels.count)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, isPickingMultiscreen ? 92 : 0)
        }
    }

    private func row(for channel: Channel) -> some View {
        ChannelListRow(
            channel: channel,
            action: { handleTap(channel) },
            isFavorite: watchStore.isFavorite(channel),
            isPicking: isPickingMultiscreen,
            isSelected: selectedChannelIDs.contains(channel.id),
            onToggleFavorite: { watchStore.toggleFavorite(channel) }
        )
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.footnote.weight(.bold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.vertical, 6)
        .background(Theme.background)
    }

    // MARK: Multiscreen

    private var multiscreenFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label("\(selectedMultiChannels.count)/4", systemImage: "rectangle.grid.2x2")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Select 2–4 channels to watch together")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { resetMultiscreenSelection() }
                }
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    startMultiscreen()
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .foregroundStyle(.white)
                .background(selectedMultiChannels.count >= 2 ? Theme.accent : Theme.accent.opacity(0.36),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(selectedMultiChannels.count < 2)
            }
        }
        .padding(12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func handleTap(_ channel: Channel) {
        if isPickingMultiscreen {
            if let index = selectedMultiChannels.firstIndex(where: { $0.id == channel.id }) {
                selectedMultiChannels.remove(at: index)
            } else if selectedMultiChannels.count < 4 {
                selectedMultiChannels.append(channel)
            }
        } else {
            playingChannel = channel
        }
    }

    private func toggleMultiscreenPicking() {
        withAnimation {
            if isPickingMultiscreen {
                resetMultiscreenSelection()
            } else {
                isPickingMultiscreen = true
            }
        }
    }

    private func startMultiscreen() {
        let channels = Array(selectedMultiChannels.prefix(4))
        guard channels.count >= 2 else { return }
        multiscreenSession = MultiscreenSession(channels: channels)
        resetMultiscreenSelection()
    }

    private func resetMultiscreenSelection() {
        isPickingMultiscreen = false
        selectedMultiChannels.removeAll()
    }

    private var emptyPlaylistState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv")
                .font(.system(size: Theme.scaled(48)))
                .foregroundStyle(Theme.accent)
            Text("No Playlists Added")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Add a subscription playlist in Settings to connect your personal channels.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var noChannelsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: Theme.scaled(44)))
                .foregroundStyle(Theme.textSecondary)
            Text(store.lastError ?? "No channels loaded from your playlists yet.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Refresh") { Task { await store.refreshAll() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }
}

private struct MultiscreenSession: Identifiable {
    let id = UUID()
    let channels: [Channel]
}

// MARK: - Filter sheet

/// Multi-select filter editor. Only offers values that exist in the loaded
/// channels, so every row visibly narrows the list.
private struct ChannelFiltersSheet: View {
    @Binding var filter: ChannelFilter
    let channels: [Channel]
    let playlists: [Playlist]
    @Environment(\.dismiss) private var dismiss
    @State private var options = ChannelFilterOptions()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                List {
                    favoritesSection
                    if playlists.count > 1 { playlistsSection }
                    if !options.categories.isEmpty { categoriesSection }
                    if !options.groups.isEmpty { groupsSection }
                    if !options.languages.isEmpty { languagesSection }
                    if !options.qualities.isEmpty { qualitiesSection }
                }
                .listStyle(.plain)
                .hidesScrollContentBackground()
            }
            .navigationTitle("Filter Channels")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { filter = ChannelFilter() }
                        .disabled(!filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .onAppear {
            options = ChannelFilterEngine.availableOptions(in: channels)
        }
    }

    private var favoritesSection: some View {
        Section {
            toggleRow(title: "Favourites only",
                      systemImage: "heart.fill",
                      isOn: filter.favoritesOnly) {
                filter.favoritesOnly.toggle()
            }
        } header: {
            Label("Quick", systemImage: "bolt.fill")
        }
    }

    private var playlistsSection: some View {
        Section {
            ForEach(playlists) { playlist in
                selectableRow(title: playlist.name,
                              isSelected: filter.playlistIDs.contains(playlist.id)) {
                    toggle(playlist.id, in: &filter.playlistIDs)
                }
            }
        } header: {
            Label("Playlists", systemImage: "list.and.film")
        }
    }

    private var categoriesSection: some View {
        Section {
            ForEach(options.categories) { category in
                selectableRow(title: category.rawValue,
                              isSelected: filter.categories.contains(category)) {
                    toggle(category, in: &filter.categories)
                }
            }
        } header: {
            Label("Channel Type", systemImage: "tag.fill")
        }
    }

    private var groupsSection: some View {
        Section {
            ForEach(options.groups, id: \.self) { group in
                selectableRow(title: group,
                              isSelected: filter.groups.contains(group)) {
                    toggle(group, in: &filter.groups)
                }
            }
        } header: {
            Label("Categories", systemImage: "square.grid.2x2")
        } footer: {
            Text("Categories come from your playlists' group tags.")
        }
    }

    private var languagesSection: some View {
        Section {
            ForEach(options.languages) { language in
                selectableRow(title: language.name,
                              detail: language.code.uppercased(),
                              isSelected: filter.languages.contains(language.code)) {
                    toggle(language.code, in: &filter.languages)
                }
            }
        } header: {
            Label("Languages", systemImage: "globe")
        } footer: {
            Text("Detected from tags in channel names, e.g. \"EN\" marks an English stream.")
        }
    }

    private var qualitiesSection: some View {
        Section {
            ForEach(options.qualities) { quality in
                selectableRow(title: quality.rawValue,
                              isSelected: filter.qualities.contains(quality)) {
                    toggle(quality, in: &filter.qualities)
                }
            }
        } header: {
            Label("Quality", systemImage: "sparkles.tv")
        }
    }

    private func toggle<Value: Hashable>(_ value: Value, in set: inout Set<Value>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    private func toggleRow(title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(isOn ? "On" : "Off")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func selectableRow(title: String, detail: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .listRowBackground(Theme.surface)
    }
}

struct ChannelListRow: View {
    let channel: Channel
    let action: () -> Void
    var isFavorite: Bool = false
    var isPicking: Bool = false
    var isSelected: Bool = false
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncImage(url: channel.logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "play.tv.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 42, height: 42)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(channel.group ?? channel.playlistName)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if let onToggleFavorite, !isPicking {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.headline)
                            .foregroundStyle(isFavorite ? Theme.live : Theme.textSecondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "Remove from favourites" : "Add to favourites")
                }
                trailingIcon
            }
            .padding(12)
            .background(isSelected ? Theme.accent.opacity(0.15) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailingIcon: some View {
        if isPicking {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
        } else {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
        }
    }
}
