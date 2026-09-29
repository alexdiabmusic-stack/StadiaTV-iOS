import SwiftUI

/// The Channels section of the Live tab: playlists, groups, favourites and channel lists.
/// Lives inside the Live tab's NavigationStack, so it doesn't create its own.
struct LiveChannelsView: View {
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
        ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                content
                if isPickingMultiscreen { multiscreenFooter }
            }
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
            .tint(Theme.accent)
    }

    @ViewBuilder
    private var content: some View {
        if store.playlists.isEmpty {
            emptyPlaylistState
        } else if store.allChannels.isEmpty && !store.loadingPlaylistIDs.isEmpty {
            loadingState
        } else if store.allChannels.isEmpty {
            noChannelsState
        } else {
            LiveBrowserView(
                onPlay: { handleTap($0, scopeChannels: $1) },
                refreshAction: { await store.refreshAll(force: true) },
                isPickingMultiscreen: $isPickingMultiscreen,
                selectedMultiChannels: $selectedMultiChannels
            )
        }
    }

    private var loadingState: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                SkeletonRow()
                    .listRowBackground(Theme.background)
                    #if !os(tvOS)
                    .listRowSeparator(.hidden)
                    #endif
            }
        }
        .listStyle(.plain)
        .hidesScrollContentBackground()
        .allowsHitTesting(false)
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
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Label("\(selectedMultiChannels.count)/4", systemImage: "rectangle.grid.2x2")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textPrimary)
                Text("Select 2–4 channels to watch together")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            HStack(spacing: Theme.Spacing.sm) {
                Button("Cancel") {
                    withAnimation(Theme.Motion.snappy) { resetMultiscreenSelection() }
                }
                .buttonStyle(SecondaryButtonStyle())

                Button { startMultiscreen() } label: {
                    Label("Watch", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .opacity(selectedMultiChannels.count >= 2 ? 1 : 0.4)
                .disabled(selectedMultiChannels.count < 2)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
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
            PlaybackTapClock.record()
            playingChannel = channel
        }
    }

    private func playPendingRestrictedChannel() {
        guard let ch = pendingRestrictedChannel else { return }
        zapChannels = pendingRestrictedZapChannels
        PlaybackTapClock.record()
        playingChannel = ch
        pendingRestrictedChannel = nil
        pendingRestrictedZapChannels = []
    }

    private func toggleMultiscreenPicking() {
        withAnimation(Theme.Motion.snappy) {
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
        EmptyStateView(
            systemImage: "tv",
            title: "No Playlists Added",
            message: "Add a subscription playlist in Settings to connect your personal channels."
        )
    }

    private var noChannelsState: some View {
        EmptyStateView(
            systemImage: "antenna.radiowaves.left.and.right.slash",
            title: "No Channels Yet",
            message: store.lastError ?? "No channels loaded from your playlists yet.",
            actionTitle: "Refresh"
        ) {
            Task { await store.refreshAll(force: true) }
        }
    }
}

// MARK: - MultiscreenSession

private struct MultiscreenSession: Identifiable {
    let id = UUID()
    let channels: [Channel]
}

// MARK: - ChannelListRow

/// Flat channel row: logo tile, name, current programme with progress, optional
/// channel number and a star when favourited. Secondary actions (favourite, hide,
/// rename, add to group) live in swipe actions and the context menu, so the row
/// has a single tap target.
struct ChannelListRow: View {
    let channel: Channel
    let action: () -> Void
    var isFavorite: Bool = false
    var isPicking: Bool = false
    var isSelected: Bool = false
    var channelNumber: Int?

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                ChannelLogo(url: channel.logoURL, name: channel.name)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let channelNumber {
                            Text("\(channelNumber)")
                                .font(Theme.Typography.captionDigits)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(channel.name)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.starting)
                                .accessibilityLabel("Favourite")
                        }
                    }
                    ChannelNowPlayingLine(channelID: channel.id, fallback: channel.group ?? channel.playlistName)
                }
                Spacer(minLength: 0)
                if isPicking {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Now: {programme}" with a thin progress bar, refreshed every minute from the guide.
/// Reads the EPG through non-observing references so guide imports don't re-render every row.
private struct ChannelNowPlayingLine: View {
    let channelID: String
    let fallback: String
    @Environment(\.playerStores) private var stores

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let programme = currentProgramme(at: context.date) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Now: \(programme.title)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    ProgressView(value: programme.progress(at: context.date))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(height: 2)
                        .scaleEffect(x: 1, y: 0.5, anchor: .center)
                        .accessibilityHidden(true)
                }
            } else {
                Text(fallback)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func currentProgramme(at date: Date) -> EPGProgramme? {
        guard let epg = stores?.epgRepository,
              let canonicalID = epg.channelToCanonicalMap[channelID] else { return nil }
        return epg.currentProgramme(for: canonicalID, at: date)
    }
}
