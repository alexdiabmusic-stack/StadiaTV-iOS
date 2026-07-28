#if os(tvOS)
import SwiftUI

struct TVLiveTVView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @State private var query = ""
    @State private var selectedCategory: ChannelCategory? = nil
    @State private var favoritesOnly = false
    @State private var playingChannel: Channel?

    private var filteredChannels: [Channel] {
        let base = store.allChannels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return ChannelFilterEngine.apply(
            buildFilter(),
            query: query,
            to: base,
            favoriteChannelIDs: Set(watchStore.favorites.map(\.id))
        )
    }

    private func buildFilter() -> ChannelFilter {
        var f = ChannelFilter()
        f.favoritesOnly = favoritesOnly
        if let cat = selectedCategory { f.categories = [cat] }
        return f
    }

    private var availableCategories: [ChannelCategory] {
        ChannelFilterEngine.availableOptions(in: store.allChannels).categories.sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if store.playlists.isEmpty {
                    TVEmptyState(
                        systemImage: "tv.slash",
                        title: "No Playlists Added",
                        subtitle: "Add an M3U or Xtream Codes playlist in Settings to watch live channels."
                    )
                } else if store.allChannels.isEmpty && !store.loadingPlaylistIDs.isEmpty {
                    ProgressView().tint(Theme.accent).scaleEffect(2)
                } else if store.allChannels.isEmpty {
                    TVEmptyState(
                        systemImage: "tv.slash",
                        title: "No Channels Found",
                        subtitle: "Your playlists loaded but returned no channels."
                    )
                } else {
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 280)
                        Divider()
                            .background(Theme.hairline)
                        channelGrid
                    }
                }
            }
            .navigationTitle("Live TV")
            .searchable(text: $query, prompt: "Search channels")
        }
        .tint(Theme.accent)
        .fullScreenCover(item: $playingChannel) { TVPlayerView(channel: $0) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                sidebarButton(title: "All Channels", systemImage: "tv", selected: selectedCategory == nil && !favoritesOnly) {
                    selectedCategory = nil
                    favoritesOnly = false
                }
                sidebarButton(title: "Favourites", systemImage: "heart.fill", selected: favoritesOnly) {
                    favoritesOnly.toggle()
                    if favoritesOnly { selectedCategory = nil }
                }

                Divider().background(Theme.hairline).padding(.vertical, 6)

                Text("CATEGORIES")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)

                ForEach(availableCategories) { category in
                    sidebarButton(
                        title: category.rawValue,
                        systemImage: category.systemImage,
                        selected: selectedCategory == category
                    ) {
                        selectedCategory = selectedCategory == category ? nil : category
                        favoritesOnly = false
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .background(Theme.surface)
    }

    private func sidebarButton(title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 24)
                    .foregroundStyle(selected ? .white : Theme.textSecondary)
                Text(title)
                    .font(.body.weight(selected ? .bold : .regular))
                    .foregroundStyle(selected ? .white : Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(selected ? Theme.accent.opacity(0.9) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Channel Grid

    private var channelGrid: some View {
        Group {
            if filteredChannels.isEmpty {
                TVEmptyState(systemImage: "magnifyingglass", title: "No Channels Found", subtitle: "Try adjusting your filters or search.")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 20)],
                        spacing: 20
                    ) {
                        ForEach(filteredChannels) { channel in
                            Button { playingChannel = channel } label: {
                                TVChannelCard(channel: channel, isFavorite: watchStore.isFavorite(channel))
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
