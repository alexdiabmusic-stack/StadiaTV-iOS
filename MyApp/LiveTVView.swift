import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @State private var query = ""
    @State private var playingChannel: Channel?
    @State private var isPickingMultiscreen = false
    @State private var selectedMultiChannelIDs: Set<String> = []
    @State private var multiscreenSession: MultiscreenSession?

    private var filteredChannels: [Channel] {
        let channels = store.allChannels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return channels }
        return channels.filter { channel in
            (channel.name + " " + (channel.group ?? "") + " " + channel.playlistName)
                .localizedCaseInsensitiveContains(trimmed)
        }
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

    private var selectedChannels: [Channel] {
        (favoriteChannels + filteredChannels).reduce(into: [Channel]()) { result, channel in
            if selectedMultiChannelIDs.contains(channel.id), !result.contains(where: { $0.id == channel.id }) {
                result.append(channel)
            }
        }
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
                    channelList
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
            .sheet(item: $playingChannel) { channel in
                PlayerView(channel: channel)
            }
            .sheet(item: $multiscreenSession) { session in
                MultiScreenPlayerView(channels: session.channels)
            }
        }
        .tint(Theme.accent)
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                if !isSearching && !watchStore.history.isEmpty {
                    ContinueWatchingSection(entries: watchStore.history) { channel in
                        handleTap(channel)
                    }
                }

                if !isSearching && !favoriteChannels.isEmpty {
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
            isSelected: selectedMultiChannelIDs.contains(channel.id),
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
                Label("\(selectedChannels.count)/4", systemImage: "rectangle.grid.2x2")
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
                .background(selectedChannels.count >= 2 ? Theme.accent : Theme.accent.opacity(0.36),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(selectedChannels.count < 2)
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
            if selectedMultiChannelIDs.contains(channel.id) {
                selectedMultiChannelIDs.remove(channel.id)
            } else if selectedMultiChannelIDs.count < 4 {
                selectedMultiChannelIDs.insert(channel.id)
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
        let channels = Array(selectedChannels.prefix(4))
        guard channels.count >= 2 else { return }
        multiscreenSession = MultiscreenSession(channels: channels)
        resetMultiscreenSelection()
    }

    private func resetMultiscreenSelection() {
        isPickingMultiscreen = false
        selectedMultiChannelIDs.removeAll()
    }

    private var emptyPlaylistState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("No Playlists Added")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Add an M3U link or Xtream account in Settings to populate Live TV.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var noChannelsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 44))
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
