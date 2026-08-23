import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var channelPrefs: ChannelPreferencesStore
    @EnvironmentObject private var parentalControl: ParentalControlStore

    @State private var playingChannel: Channel?
    @State private var zapChannels: [Channel] = []
    @State private var isPickingMultiscreen = false
    @State private var selectedMultiChannels: [Channel] = []
    @State private var multiscreenSession: MultiscreenSession?
    @State private var pendingRestrictedChannel: Channel?
    @State private var pendingRestrictedZapChannels: [Channel] = []
    @State private var showingPINPrompt = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                content
                if isPickingMultiscreen { multiscreenFooter }
            }
            .navigationTitle("Live TV")
            .toolbar { multiscreenToolbarItem }
            .fullScreenCover(item: $playingChannel) { channel in
                PlayerView(
                    channel: channel,
                    zapChannels: zapChannels,
                    currentIndex: zapChannels.firstIndex(where: { $0.id == channel.id }) ?? 0
                )
            }
            .fullScreenCover(item: $multiscreenSession) { MultiScreenPlayerView(channels: $0.channels) }
            .fullScreenCover(isPresented: $showingPINPrompt) {
                PINPromptView(
                    title: "Parental Controls",
                    message: pendingRestrictedChannel.map { "\"\($0.name)\" is restricted." } ?? "This channel is restricted.",
                    onUnlock: { playPendingRestrictedChannel() },
                    onCancel: { pendingRestrictedChannel = nil; pendingRestrictedZapChannels = [] }
                )
                .environmentObject(parentalControl)
            }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var content: some View {
        if store.playlists.isEmpty {
            emptyPlaylistState
        } else if store.allChannels.isEmpty && !store.loadingPlaylistIDs.isEmpty {
            ProgressView().tint(Theme.accent)
        } else if store.allChannels.isEmpty {
            noChannelsState
        } else {
            LiveBrowserView(
                onPlay: { handleTap($0, scopeChannels: $1) },
                refreshAction: { await store.refreshAll() },
                isPickingMultiscreen: $isPickingMultiscreen,
                selectedMultiChannels: $selectedMultiChannels
            )
        }
    }

    // MARK: - Multiscreen

    @ToolbarContentBuilder
    private var multiscreenToolbarItem: some ToolbarContent {
        if store.allChannels.count >= 2 {
            ToolbarItem(placement: .topBarTrailing) {
                Button { toggleMultiscreenPicking() } label: {
                    Image(systemName: isPickingMultiscreen
                          ? "checkmark.rectangle.stack" : "rectangle.grid.2x2")
                }
                .accessibilityLabel(isPickingMultiscreen
                                    ? "Finish multiscreen selection" : "Select multiscreen sources")
            }
        }
    }

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
                .background(Theme.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button { startMultiscreen() } label: {
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
        .background(.black.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.hairline))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func handleTap(_ channel: Channel, scopeChannels: [Channel]) {
        if isPickingMultiscreen {
            if let idx = selectedMultiChannels.firstIndex(where: { $0.id == channel.id }) {
                selectedMultiChannels.remove(at: idx)
            } else if selectedMultiChannels.count < 4 {
                selectedMultiChannels.append(channel)
            }
        } else if parentalControl.isRestricted(channel) {
            pendingRestrictedZapChannels = scopeChannels.isEmpty ? [channel] : scopeChannels
            pendingRestrictedChannel = channel
            showingPINPrompt = true
        } else {
            zapChannels = scopeChannels.isEmpty ? [channel] : scopeChannels
            playingChannel = channel
        }
    }

    private func playPendingRestrictedChannel() {
        guard let ch = pendingRestrictedChannel else { return }
        zapChannels = pendingRestrictedZapChannels
        playingChannel = ch
        pendingRestrictedChannel = nil
        pendingRestrictedZapChannels = []
    }

    private func toggleMultiscreenPicking() {
        withAnimation {
            if isPickingMultiscreen { resetMultiscreenSelection() } else { isPickingMultiscreen = true }
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

    // MARK: - Empty states

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

// MARK: - MultiscreenSession

private struct MultiscreenSession: Identifiable {
    let id = UUID()
    let channels: [Channel]
}

// MARK: - ChannelListRow

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
                .background(Theme.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
