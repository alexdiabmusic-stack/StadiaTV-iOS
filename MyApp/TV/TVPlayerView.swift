#if os(tvOS)
import SwiftUI
import AVKit
import UIKit

struct TVPlayerView: View {
    let initialChannel: Channel
    @State private var selectedChannel: Channel?
    @State private var previousChannel: Channel?
    private enum Panel { case channels, guide, recents, settings, sports, multiview, paywall, fantasy }
    @StateObject private var playerGuideModel = TVGuideViewModel()
    @State private var presentedPanel: Panel?
    @State private var controlsLocked = false
    private var showingChannels: Bool {
        get { presentedPanel == .channels }
        nonmutating set { presentedPanel = newValue ? .channels : (presentedPanel == .channels ? nil : presentedPanel) }
    }
    private var showingGuide: Bool {
        get { presentedPanel == .guide }
        nonmutating set { presentedPanel = newValue ? .guide : (presentedPanel == .guide ? nil : presentedPanel) }
    }
    @FocusState private var focusedControl: String?
    private var channel: Channel { selectedChannel ?? initialChannel }
    /// Pre-resolved match from the detail screen; when set, skips league schedule search.
    let initialMatch: Match?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @EnvironmentObject private var streamStore: StreamAvailabilityStore

    /// Same playback engine as iOS: fast-start tuning, provider headers, watchdog and stall recovery.
    @StateObject private var playback = PlaybackController()
    @StateObject private var streamSelection: StreamSelectionState
    @State private var aspectMode: PlayerAspectMode = .fit
    @State private var audioGroup: AVMediaSelectionGroup?
    @State private var subtitleGroup: AVMediaSelectionGroup?
    @State private var selectedAudioIndex: Int?
    @State private var selectedSubtitleIndex: Int?
    @State private var streamMetadata: StreamRuntimeMetadata?
    @State private var failureMessage: String?
    @State private var isChromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    private var showMultiscreen: Bool {
        get { presentedPanel == .multiview }
        nonmutating set { presentedPanel = newValue ? .multiview : (presentedPanel == .multiview ? nil : presentedPanel) }
    }
    @State private var multiscreenChannelsList: [Channel] = []
    private var showPaywall: Bool {
        get { presentedPanel == .paywall }
        nonmutating set { presentedPanel = newValue ? .paywall : (presentedPanel == .paywall ? nil : presentedPanel) }
    }
    private var showingFantasySidebar: Bool {
        get { presentedPanel == .fantasy }
        nonmutating set { presentedPanel = newValue ? .fantasy : (presentedPanel == .fantasy ? nil : presentedPanel) }
    }
    @StateObject private var liveTracker = FantasyLiveTrackerEngine.shared

    // Live score
    @State private var liveScoreMatch: Match?
    private func publishMatch(_ match: Match?) {
        MatchNotificationService.shared.playerMatchID = match?.id
        liveScoreMatch = match
        spoilerBuffer.receive(match)
        scoreDisplayDate = Date()
    }
    @State private var spoilerBuffer = PlayerSpoilerBuffer()
    @State private var scoreDisplayDate = Date()
    private var displayedScoreMatch: Match? {
        guard !prefs.hidesSportsScores else { return nil }
        return spoilerBuffer.snapshot(delay: prefs.sportsScoreDelaySeconds, now: scoreDisplayDate)
    }
    private var isScoreExpanded: Bool {
        get { presentedPanel == .sports }
        nonmutating set { presentedPanel = newValue ? .sports : (presentedPanel == .sports ? nil : presentedPanel) }
    }
    @State private var isScoreDismissed = false

    init(channel: Channel, initialMatch: Match? = nil) {
        self.initialChannel = channel
        self.initialMatch = initialMatch
        _streamSelection = StateObject(wrappedValue: StreamSelectionState(channel: channel))
    }

    private func panelBinding(_ panel: Panel) -> Binding<Bool> {
        Binding(get: { presentedPanel == panel }, set: { visible in
            if visible { presentedPanel = panel }
            else if presentedPanel == panel { presentedPanel = nil }
        })
    }

    private var canStartMultiscreen: Bool {
        let hasOtherChannels = playlistStore.channelsByPlaylist.values.contains { channels in
            channels.contains { StreamLinkerAdapters.streamID($0) != StreamLinkerAdapters.streamID(channel) }
        }
        return hasOtherChannels
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TVVideoSurface(controller: playback, aspect: aspectMode)
                .modifier(OriginalVideoSize(mode: aspectMode, videoSize: playback.player.currentItem?.presentationSize ?? .zero))
                .ignoresSafeArea()
            playbackStatus
            if let match = displayedScoreMatch, prefs.showLiveScoreBadge, !isScoreDismissed {
                VStack {
                    HStack(spacing: 10) {
                        if prefs.sportsScoreDelaySeconds == 0 { TVLiveBadge() }
                        else { Text("Delayed \(prefs.sportsScoreDelaySeconds)s").font(.caption) }
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
                        .accessibilityLabel("Hide score")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.top, 60)
                    Spacer()
                }
            }
            if controlsLocked {
                Button("Unlock controls", systemImage: "lock.open.fill") {
                    controlsLocked = false
                    revealChromeTemporarily()
                }
                .buttonStyle(.card)
            } else if isChromeVisible {
                chromeOverlay
                    .transition(.opacity)
            }
        }
        .task(id: prefs.sportsScoreDelaySeconds) {
            guard prefs.sportsScoreDelaySeconds > 0 else { return }
            while !Task.isCancelled {
                scoreDisplayDate = Date()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: prefs.spoilerFreeMode) { _, hidden in
            if hidden { isScoreExpanded = false; showingFantasySidebar = false }
        }
        .onPlayPauseCommand {
            guard !controlsLocked else { return }
            togglePlayback()
            revealChromeTemporarily()
        }
        .onExitCommand {
            if controlsLocked { controlsLocked = false; revealChromeTemporarily() }
            else if presentedPanel != nil { presentedPanel = nil; revealChromeTemporarily() }
            else if isChromeVisible { isChromeVisible = false }
            else { dismiss() }
        }
        .onMoveCommand { direction in
            guard !isChromeVisible, !controlsLocked, presentedPanel == nil else { return }
            switch direction {
            case .left, .up: showingChannels = true
            case .down: showingGuide = true
            case .right:
                if liveScoreMatch != nil && !prefs.spoilerFreeMode { isScoreExpanded = true }
                else { revealChromeTemporarily() }
            @unknown default: revealChromeTemporarily()
            }
        }
        .onTapGesture { revealChromeTemporarily() }
        .onChange(of: presentedPanel) { previous, panel in
            if panel == nil {
                focusedControl = previous == .guide ? "guide" : (previous == .settings ? "settings" : "channels")
                revealChromeTemporarily()
            }
        }
        .onChange(of: aspectMode) { _, mode in PlayerAspectMode.save(mode, for: channel.id) }
        .sheet(isPresented: panelBinding(.recents)) {
            PlayerRecentsSheet(currentChannelID: StreamLinkerAdapters.streamID(channel), onSelect: switchChannel)
        }
        .sheet(isPresented: panelBinding(.settings)) {
            PlayerMoreSheet(
                channel: channel, streamSelection: streamSelection, playback: playback,
                bufferProfile: Binding(get: { prefs.playerBufferProfile }, set: { value in
                    prefs.setPlayerBufferProfile(value)
                    playback.setBufferProfile(value)
                }),
                aspect: $aspectMode, audioGroup: audioGroup,
                selectedAudioIndex: Binding(get: { selectedAudioIndex }, set: { index in
                    selectedAudioIndex = index
                    playback.selectMedia(index: index, group: audioGroup, isSubtitle: false, preferences: prefs)
                }),
                subtitleGroup: subtitleGroup,
                selectedSubtitleIndex: Binding(get: { selectedSubtitleIndex }, set: { index in
                    selectedSubtitleIndex = index
                    playback.selectMedia(index: index, group: subtitleGroup, isSubtitle: true, preferences: prefs)
                }),
                streamMetadata: streamMetadata, canStartMultiscreen: canStartMultiscreen,
                multiscreenAction: startMultiscreen,
                lockAction: { presentedPanel = nil; controlsLocked = true; isChromeVisible = false },
                compactAction: nil,
                recommendationAction: { channel in presentedPanel = nil; switchChannel(to: channel) }
            )
        }
        .sheet(isPresented: panelBinding(.sports)) {
            if let match = liveScoreMatch, !prefs.spoilerFreeMode {
                PlayerSportsPanel(match: match, broadcasts: streamStore.topRanked(for: match.id, limit: 20), onSelectBroadcast: { selected in
                    switchChannel(to: selected)
                    isScoreExpanded = false
                }, onClose: { isScoreExpanded = false })
            }
        }
        .sheet(isPresented: panelBinding(.channels)) {
            PlayerChannelListSheet(channels: playlistStore.allChannels, currentChannelID: StreamLinkerAdapters.streamID(channel)) { selected, _ in
                switchChannel(to: selected)
            }
        }
        .sheet(isPresented: panelBinding(.guide)) {
            TVGuideView(onChannelSelected: { canonical in
                if let selected = canonical.playableChannel { switchChannel(to: selected) }
                showingGuide = false
            }, onCatchupSelected: { selected in
                switchChannel(to: selected)
                showingGuide = false
            }, viewModel: playerGuideModel, preview: AnyView(TVVideoSurface(controller: playback, aspect: .fit)))
        }
        .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
        .fullScreenCoverCompat(isPresented: panelBinding(.multiview)) {
            MultiScreenPlayerView(channels: multiscreenChannelsList)
        }
        .fullScreenCoverCompat(isPresented: panelBinding(.paywall)) {
            TVPaywallView()
        }
        .onChange(of: showMultiscreen) { _, showing in
            if showing { playback.stop() }
            else { playback.load(channel) }
        }
        .onAppear {
            playback.setBufferProfile(prefs.playerBufferProfile)
            playback.onFailure = { reason in failureMessage = reason }
            playback.onFirstFrame = { _, _ in failureMessage = nil }
            playback.onMetadata = { metadata in streamMetadata = metadata }
            playback.onItemReady = { item in
                Task { @MainActor in
                    guard let tracks = await playback.mediaSelections(for: item, preferences: prefs) else { return }
                    audioGroup = tracks.audio
                    subtitleGroup = tracks.subtitles
                    selectedAudioIndex = tracks.audioIndex
                    selectedSubtitleIndex = tracks.subtitleIndex
                }
            }
            aspectMode = PlayerAspectMode.saved(for: channel.id)
            if playback.channel != channel || playback.currentItem == nil { playback.load(channel) }
            watchStore.recordWatch(channel)
            revealChromeTemporarily()
        }
        .onDisappear {
            // The controller's closures capture this view; clear them before stopping.
            guard presentedPanel == nil else { return }
            playback.onFailure = nil
            playback.onFirstFrame = nil
            playback.onItemReady = nil
            playback.onMetadata = nil
            playback.stop()
            chromeHideTask?.cancel()
        }
        .task(id: StreamLinkerAdapters.streamID(channel)) {
            isScoreDismissed = false
            isScoreExpanded = false
            publishMatch(nil)
            if selectedChannel == nil, let match = initialMatch,
               match.state == .live, abs(match.date.timeIntervalSinceNow) < 12 * 3600,
               await streamStore.confidenceScore(match: match, channel: channel, channels: playlistStore.allChannels, epgRepository: epgRepository) >= 70 {
                guard !Task.isCancelled else { return }
                publishMatch(match)
                await pollMatchUpdates(for: match)
            } else {
                await findAndPollLiveMatch()
            }
        }
        .overlay(alignment: .trailing) {
            if showingFantasySidebar && !prefs.spoilerFreeMode {
                FantasyMatchupSidebarView(
                    onWatchChannel: { ch in
                        withAnimation(.spring(duration: 0.3)) { showingFantasySidebar = false }
                        switchChannel(to: ch)
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
            if !prefs.spoilerFreeMode, prefs.notificationSettings.enabled, prefs.notificationSettings.liveAlerts, liveTracker.showToastAlert, let alert = liveTracker.recentAlert {
                FantasyRedZoneToastView(
                    alert: alert,
                    onWatchChannel: { ch in
                        liveTracker.dismissCurrentAlert()
                        switchChannel(to: ch)
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
            if !prefs.spoilerFreeMode && !showingFantasySidebar && isChromeVisible {
                FantasyDriveTickerOverlayView(onWatchChannel: { ch in
                    switchChannel(to: ch)
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
        .task(id: "\(playlistStore.channelsRevision)|\(StreamLinkerAdapters.streamID(channel))") {
            let channels = playlistStore.allChannels
            let current = channel
            multiscreenChannelsList = await Task.detached(priority: .utility) {
                var seenIDs: Set<String> = [StreamLinkerAdapters.streamID(current)]
                var result = [current]
                for candidate in channels.sorted(by: {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }) where seenIDs.insert(StreamLinkerAdapters.streamID(candidate)).inserted {
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
                .focused($focusedControl, equals: "back")

                Spacer()

                HStack(spacing: 10) {
                    TVChannelLogo(url: channel.logoURL, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let match = liveScoreMatch {
                            Text("\(match.league.shortName) · \(match.shortName)").font(.caption).lineLimit(1)
                        } else if let canonical = epgRepository.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID),
                                  let programme = epgRepository.currentProgramme(for: canonical.id) {
                            Text(programme.title).font(.caption).lineLimit(1)
                        }
                    }
                    TVLiveBadge()
                    if let height = streamMetadata?.height { Text("\(height)p").font(.caption) }
                    if let fps = streamMetadata?.frameRate { Text(String(format: "%.0f fps", fps)).font(.caption) }
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
                .focused($focusedControl, equals: "play")
            }
            .padding(.horizontal, 60)
            .padding(.top, 44)

            Spacer()

            // Focus-driven horizontal scrolling keeps all actions reachable on narrow displays.
            ScrollView(.horizontal) {
            HStack(spacing: 16) {
                if liveScoreMatch != nil && !prefs.spoilerFreeMode {
                    Button("Sports") { isScoreExpanded = true }
                        .focused($focusedControl, equals: "sports")
                }
                Button { selectAdjacentChannel(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous channel in list")
                    .focused($focusedControl, equals: "channelDown")
                Button { selectAdjacentChannel(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next channel")
                    .focused($focusedControl, equals: "channelUp")
                Button("Channels") { showingChannels = true }
                    .focused($focusedControl, equals: "channels")
                Button("Guide") { showingGuide = true }
                    .focused($focusedControl, equals: "guide")
                Button("Recent") { presentedPanel = .recents }
                    .focused($focusedControl, equals: "recents")
                Button("Options") { presentedPanel = .settings }
                    .focused($focusedControl, equals: "settings")
                if playback.isBehindLiveEdge {
                    Button("Go Live") { playback.seekToLiveEdge() }
                        .focused($focusedControl, equals: "live")
                }
                Button("Previous channel") {
                    if let previousChannel { switchChannel(to: previousChannel) }
                }
                .disabled(previousChannel == nil)
                .focused($focusedControl, equals: "previous")
                Button(playback.isMuted ? "Unmute" : "Mute") { playback.setMuted(!playback.isMuted) }
                    .focused($focusedControl, equals: "mute")
                if let group = channel.group {
                    Text(group)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                Spacer()
                if !prefs.spoilerFreeMode && !fantasyStore.playerGames.isEmpty {
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
                Button("Return to Guide") { showingGuide = true }
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
            try? await Task.sleep(for: .seconds(prefs.playerPanelTimeoutSeconds))
            guard !Task.isCancelled else { return }
            guard !voiceOverEnabled, focusedControl == nil, presentedPanel == nil else {
                scheduleChromeHide()
                return
            }
            isChromeVisible = false
        }
    }

    private func selectAdjacentChannel(_ offset: Int) {
        let channels = playlistStore.allChannels
        guard let current = channels.firstIndex(of: channel), channels.indices.contains(current + offset) else { return }
        switchChannel(to: channels[current + offset])
    }

    private func switchChannel(to selected: Channel) {
        guard selected != channel else { return }
        previousChannel = channel
        selectedChannel = selected
        streamSelection.reset(to: selected, canonicalChannel: nil)
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        streamMetadata = nil
        aspectMode = PlayerAspectMode.saved(for: selected.id)
        publishMatch(nil)
        failureMessage = nil
        playback.load(selected)
        watchStore.recordWatch(selected)
        watchStore.recordRecent(selected)
        revealChromeTemporarily()
    }

    private func pollMatchUpdates(for match: Match) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await SportsRepository.shared.legacyScoreboard(for: match.league).first(where: { $0.id == match.id }) {
                guard !Task.isCancelled else { return }
                let enriched = await SportsRepository.shared.enrichedLegacyMatch(updated)
                guard !Task.isCancelled else { return }
                guard updated.state == .live, abs(updated.date.timeIntervalSinceNow) < 12 * 3600 else {
                    publishMatch(nil)
                    return
                }
                publishMatch(enriched)
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
            for await matches in group { live.append(contentsOf: matches.filter { $0.state == .live && abs($0.date.timeIntervalSinceNow) < 12 * 3600 }) }
        }
        guard !Task.isCancelled, !live.isEmpty else { return }

        let allChannels = playlistStore.allChannels
        var best: Match?; var bestScore = 0; var confirmedCount = 0
        for match in live {
            let s = await streamStore.confidenceScore(match: match, channel: channel, channels: allChannels, epgRepository: epgRepository)
            if s >= 70 { confirmedCount += 1 }
            if s > bestScore { bestScore = s; best = match }
        }
        guard !Task.isCancelled, let match = best, bestScore >= 70, confirmedCount == 1 else { return }
        publishMatch(match)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await SportsRepository.shared.legacyScoreboard(for: match.league).first(where: { $0.id == match.id }) {
                guard !Task.isCancelled else { return }
                let enriched = await SportsRepository.shared.enrichedLegacyMatch(updated)
                guard !Task.isCancelled else { return }
                guard updated.state == .live, abs(updated.date.timeIntervalSinceNow) < 12 * 3600 else {
                    publishMatch(nil)
                    return
                }
                publishMatch(enriched)
            }
        }
    }
}

// MARK: - AVPlayerLayer surface

/// Attaches the controller's AVPlayer to a layer and reports the first displayable frame.
private struct TVVideoSurface: UIViewRepresentable {
    let controller: PlaybackController
    let aspect: PlayerAspectMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TVPlayerUIView {
        let view = TVPlayerUIView()
        view.playerLayer.player = controller.player
        view.playerLayer.videoGravity = aspect.videoGravity
        view.backgroundColor = .black
        context.coordinator.readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { @Sendable [weak controller] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak controller] in controller?.surfaceReadyForDisplay() }
        }
        return view
    }

    func updateUIView(_ view: TVPlayerUIView, context: Context) {
        view.playerLayer.videoGravity = aspect.videoGravity
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
