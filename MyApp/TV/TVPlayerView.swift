#if os(tvOS)
import SwiftUI
import AVKit
import UIKit

struct TVPlayerView: View {
    let channel: Channel
    /// Pre-resolved match from the detail screen; when set, skips league schedule search.
    let initialMatch: Match?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @EnvironmentObject private var streamStore: StreamAvailabilityStore

    /// Same playback engine as iOS: fast-start tuning, provider headers, watchdog and stall recovery.
    @StateObject private var playback = PlaybackController()
    @State private var failureMessage: String?
    @State private var isChromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showMultiscreen = false
    @State private var multiscreenChannelsList: [Channel] = []
    @State private var showPaywall = false
    @State private var showingFantasySidebar = false
    @StateObject private var liveTracker = FantasyLiveTrackerEngine.shared

    // Live score
    @State private var liveScoreMatch: Match?
    @State private var isScoreExpanded = false
    @State private var isScoreDismissed = false

    private var canStartMultiscreen: Bool {
        let hasOtherChannels = playlistStore.channelsByPlaylist.values.contains { channels in
            channels.contains { $0.id != channel.id }
        }
        guard hasOtherChannels else { return false }
        // A single-connection (or unknown-limit) Xtream account can't safely open a
        // second stream on top of the one already playing.
        return !playlistStore.xtreamAccountStatus.blocksAdditionalConnection(forPlaylistID: channel.playlistID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TVVideoSurface(controller: playback)
                .ignoresSafeArea()
            playbackStatus
            if let match = liveScoreMatch, prefs.showLiveScoreBadge, !isScoreDismissed {
                VStack {
                    HStack(spacing: 10) {
                        TVLiveBadge()
                        Text("\(match.away.abbreviation) \(match.away.score ?? "–") – \(match.home.score ?? "–") \(match.home.abbreviation)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Button {
                            withAnimation(.spring(duration: 0.28)) { isScoreDismissed = true }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.top, 60)
                    Spacer()
                }
            }
            if isChromeVisible {
                chromeOverlay
                    .transition(.opacity)
            }
        }
        .onPlayPauseCommand {
            togglePlayback()
            revealChromeTemporarily()
        }
        .onExitCommand {
            dismiss()
        }
        .onMoveCommand { _ in
            revealChromeTemporarily()
        }
        .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
        .fullScreenCover(isPresented: $showMultiscreen) {
            MultiScreenPlayerView(channels: multiscreenChannelsList)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            TVPaywallView()
        }
        .onAppear {
            playback.setBufferProfile(prefs.playerBufferProfile)
            playback.onFailure = { reason in failureMessage = reason }
            playback.onFirstFrame = { _, _ in failureMessage = nil }
            playback.load(channel)
            watchStore.recordWatch(channel)
            revealChromeTemporarily()
        }
        .onDisappear {
            // The controller's closures capture this view; clear them before stopping.
            playback.onFailure = nil
            playback.onFirstFrame = nil
            playback.stop()
            chromeHideTask?.cancel()
        }
        .task(id: channel.id) {
            isScoreDismissed = false
            isScoreExpanded = false
            if let match = initialMatch {
                liveScoreMatch = match
                await pollMatchUpdates(for: match)
            } else {
                await findAndPollLiveMatch()
            }
        }
        .overlay(alignment: .trailing) {
            if showingFantasySidebar {
                FantasyMatchupSidebarView(
                    onWatchChannel: { ch in
                        withAnimation(.spring(duration: 0.3)) { showingFantasySidebar = false }
                    },
                    onClose: {
                        withAnimation(.spring(duration: 0.3)) { showingFantasySidebar = false }
                    }
                )
                .environmentObject(fantasyStore)
                .transition(.move(edge: .trailing))
                .zIndex(100)
            }
        }
        .overlay(alignment: .topTrailing) {
            if liveTracker.showToastAlert, let alert = liveTracker.recentAlert {
                FantasyRedZoneToastView(
                    alert: alert,
                    onWatchChannel: { ch in
                        liveTracker.dismissCurrentAlert()
                    },
                    onDismiss: {
                        liveTracker.dismissCurrentAlert()
                    }
                )
                .padding(.top, 60)
                .padding(.trailing, 16)
                .zIndex(90)
            }
        }
        .overlay(alignment: .bottom) {
            if !showingFantasySidebar && isChromeVisible {
                FantasyDriveTickerOverlayView(onWatchChannel: { ch in
                })
                .padding(.bottom, 85)
                .zIndex(85)
            }
        }
        .task(id: fantasyStore.playerGames.count) {
            liveTracker.processLiveGames(
                playerGames: fantasyStore.playerGames,
                matchup: fantasyStore.matchup,
                channels: playlistStore.allChannels
            )
            FantasyDriveTickerEngine.shared.updateDriveData(
                playerGames: fantasyStore.playerGames,
                matches: fantasyStore.playerGames.compactMap(\.event)
            )
        }
        .task(id: playlistStore.channelsRevision) {
            let channels = playlistStore.allChannels
            let current = channel
            multiscreenChannelsList = await Task.detached(priority: .utility) {
                var seenIDs: Set<String> = [current.id]
                var result = [current]
                for candidate in channels.sorted(by: {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }) where seenIDs.insert(candidate.id).inserted {
                    result.append(candidate)
                }
                return result
            }.value
        }
    }

    // MARK: - Chrome

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.backward").font(.headline.weight(.bold))
                        Text("Back").font(.headline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                }
                .buttonStyle(.card)

                Spacer()

                HStack(spacing: 10) {
                    TVChannelLogo(url: channel.logoURL, size: 32)
                    Text(channel.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))

                Spacer()

                Button { togglePlayback() } label: {
                    Image(systemName: playback.isUserPaused ? "play.fill" : "pause.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.72), in: Circle())
                }
                .buttonStyle(.card)
                .accessibilityLabel(playback.isUserPaused ? "Play" : "Pause")
            }
            .padding(.horizontal, 60)
            .padding(.top, 44)

            Spacer()

            // Bottom bar
            HStack(spacing: 16) {
                if let group = channel.group {
                    Text(group)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                Spacer()
                if !fantasyStore.playerGames.isEmpty {
                    Button {
                        withAnimation(.spring(duration: 0.3)) { showingFantasySidebar.toggle() }
                    } label: {
                        Label("Fantasy", systemImage: "star.fill")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.card)
                }
                if canStartMultiscreen {
                    Button { startMultiscreen() } label: {
                        Label("Multiscreen", systemImage: "rectangle.split.2x1.fill")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 44)
        }
    }

    // MARK: - Helpers

    private func togglePlayback() {
        playback.togglePlayPause()
    }

    /// Spinner until the first frame, a reconnect pill, and a retry panel on failure.
    @ViewBuilder
    private var playbackStatus: some View {
        if let failureMessage {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.live)
                Text(failureMessage)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    self.failureMessage = nil
                    playback.load(channel)
                }
            }
            .padding(Theme.Spacing.xl)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        } else if !playback.firstFrameRendered || playback.showsBufferingIndicator {
            VStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                if playback.reconnectAttempt > 0 {
                    Text("Reconnecting (\(playback.reconnectAttempt)/\(PlaybackController.maxReconnectAttempts))…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func startMultiscreen() {
        guard entitlements.isPremium else { showPaywall = true; return }
        showMultiscreen = true
    }

    private func revealChromeTemporarily() {
        chromeHideTask?.cancel()
        isChromeVisible = true
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            isChromeVisible = false
        }
    }

    private func pollMatchUpdates(for match: Match) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await SportsRepository.shared.legacyScoreboard(for: match.league).first(where: { $0.id == match.id }) {
                liveScoreMatch = updated
                if updated.state == .final { break }
            }
        }
    }

    private func findAndPollLiveMatch() async {
        let channel = self.channel
        let leagues = ["football/nfl", "basketball/nba", "hockey/nhl", "baseball/mlb",
                       "soccer/eng.1", "soccer/esp.1", "soccer/ger.1", "soccer/ita.1",
                       "soccer/usa.1", "racing/f1"]
            .compactMap { path in League.all.first { $0.path == path } }

        var live: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask { (try? await SportsRepository.shared.legacyScoreboard(for: league)) ?? [] }
            }
            for await matches in group { live.append(contentsOf: matches.filter { $0.state == .live }) }
        }
        guard !Task.isCancelled, !live.isEmpty else { return }

        let allChannels = playlistStore.allChannels
        var best: Match?; var bestScore = 0
        for match in live {
            let s = await streamStore.confidenceScore(match: match, channel: channel, channels: allChannels, epgRepository: epgRepository)
            if s > bestScore { bestScore = s; best = match }
        }
        guard !Task.isCancelled, let match = best, bestScore >= 35 else { return }
        liveScoreMatch = match

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await SportsRepository.shared.legacyScoreboard(for: match.league).first(where: { $0.id == match.id }) {
                liveScoreMatch = updated
                if updated.state == .final { break }
            }
        }
    }
}

// MARK: - AVPlayerLayer surface

/// Attaches the controller's AVPlayer to a layer and reports the first displayable frame.
private struct TVVideoSurface: UIViewRepresentable {
    let controller: PlaybackController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TVPlayerUIView {
        let view = TVPlayerUIView()
        view.playerLayer.player = controller.player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        context.coordinator.readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { @Sendable [weak controller] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak controller] in controller?.surfaceReadyForDisplay() }
        }
        return view
    }

    func updateUIView(_ view: TVPlayerUIView, context: Context) {
        if view.playerLayer.player !== controller.player {
            view.playerLayer.player = controller.player
        }
    }

    static func dismantleUIView(_ view: TVPlayerUIView, coordinator: Coordinator) {
        coordinator.readyObservation?.invalidate()
    }

    final class Coordinator {
        var readyObservation: NSKeyValueObservation?
    }

    class TVPlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }
    }
}
#endif
