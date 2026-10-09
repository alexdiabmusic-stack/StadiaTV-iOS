import SwiftUI
import AVKit
#if os(macOS)
import AppKit
#endif
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import MediaPlayer
#endif

// MARK: - Keyboard command handler

/// Maps hardware keyboard shortcuts to semantic Live player actions.
/// Returns EmptyView on tvOS; does not affect touch interactions.
private struct LiveCommandKeyboardHandler: View {
    let onChannelUp: () -> Void
    let onChannelDown: () -> Void
    let onToggleChrome: () -> Void
    let onOpenGuide: () -> Void
    let onOpenChannelList: () -> Void
    let onOpenRecents: () -> Void
    let onExit: () -> Void
    let onMute: () -> Void
    let onFullscreen: () -> Void
    let onSports: () -> Void
    let onPrevious: () -> Void
    let onPictureInPicture: () -> Void
    let onRestoreMultiview: (Int) -> Void

    var body: some View {
        #if !os(tvOS)
        ZStack {
            keyButton("chUp",    shortcut: .init(.upArrow,   modifiers: []), action: onChannelUp)
            keyButton("chDown",  shortcut: .init(.downArrow, modifiers: []), action: onChannelDown)
            keyButton("chrome",  shortcut: .init(.space,     modifiers: []), action: onToggleChrome)
            keyButton("guide",   shortcut: .init("g",        modifiers: []), action: onOpenGuide)
            keyButton("chList",  shortcut: .init("c",        modifiers: []), action: onOpenChannelList)
            keyButton("recents", shortcut: .init("r",        modifiers: []), action: onOpenRecents)
            keyButton("pip", shortcut: .init("p", modifiers: []), action: onPictureInPicture)
            keyButton("mute", shortcut: .init("m", modifiers: []), action: onMute)
            keyButton("fullscreen", shortcut: .init("f", modifiers: []), action: onFullscreen)
            keyButton("sports", shortcut: .init("s", modifiers: []), action: onSports)
            keyButton("next", shortcut: .init("n", modifiers: []), action: onChannelDown)
            keyButton("previous", shortcut: .init("b", modifiers: []), action: onPrevious)
            ForEach(1...4, id: \.self) { slot in
                keyButton("layout\(slot)", shortcut: .init(KeyEquivalent(Character(String(slot))), modifiers: .command)) {
                    onRestoreMultiview(slot)
                }
            }
            keyButton("exit",    shortcut: .init(.escape,    modifiers: []), action: onExit)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }

    #if !os(tvOS)
    private func keyButton(_ id: String, shortcut: KeyboardShortcut, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(shortcut)
            .frame(width: 0, height: 0)
    }
    #endif
}

// MARK: - Player

/// Presents a channel's stream full screen.
struct PlayerView: View {
    let channel: Channel
    let zapChannels: [Channel]
    /// When false, hides the Guide button (and other IPTV-only controls) from the control bar.
    /// Set to false when opening from a sports match context where EPG navigation is irrelevant.
    let showsLiveTVControls: Bool
    /// Explicit event identity passed from the match detail screen. When set, the player skips
    /// `findAndPollLiveMatch` and uses `pollMatchUpdates(for:)` on the known match instead.
    let matchPlaybackContext: MatchPlaybackContext?
    @StateObject private var streamSelection: StreamSelectionState
    /// The shared `AVPlayer`-owning controller (`BannerAppEnvironment.playbackController`) —
    /// not constructed per presentation, so layout changes, re-presentation, and switching
    /// to/from CarPlay all keep using the same player instead of restarting it.
    @StateObject private var playback: PlaybackController
    /// Captured at init and applied via `playback.notePendingTapDate(_:)` right before this
    /// presentation's first `load()`, since the controller itself is no longer constructed
    /// fresh per presentation (see above).
    @State private var initialTapDate: Date
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var prefs: PreferencesStore
    /// Playlist/EPG stores, read without observing so imports don't re-render the player.
    @Environment(\.playerStores) private var stores

    // Zap / channel navigation state
    @State private var currentZapChannel: Channel
    @State private var zapIndex: Int
    @State private var dwellTask: Task<Void, Never>?
    @State private var previousChannel: Channel?
    @State private var lastAppliedLoadToken: Int?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    // Playback options
    @State private var activeStreamMetadata: StreamRuntimeMetadata?
    @State private var currentPlayerItem: AVPlayerItem?
    @State private var audioGroup: AVMediaSelectionGroup?
    @State private var subtitleGroup: AVMediaSelectionGroup?
    @State private var selectedAudioIndex: Int?
    @State private var selectedSubtitleIndex: Int?

    private enum Panel {
        case settings, channels, recents, guide, broadcasts, multiview, paywall, fantasy, sports
    }
    @StateObject private var playerGuideModel = TVGuideViewModel()
    @State private var presentedPanel: Panel?

    private func panelBinding(_ panel: Panel) -> Binding<Bool> {
        Binding(get: { presentedPanel == panel }, set: { visible in
            if visible { presentedPanel = panel }
            else if presentedPanel == panel { presentedPanel = nil }
        })
    }

    // Player chrome panels
    private var showingMore: Bool {
        get { presentedPanel == .settings }
        nonmutating set {
            if newValue { presentedPanel = .settings }
            else if presentedPanel == .settings { presentedPanel = nil }
        }
    }
    private var showingChannelList: Bool {
        get { presentedPanel == .channels }
        nonmutating set {
            if newValue { presentedPanel = .channels }
            else if presentedPanel == .channels { presentedPanel = nil }
        }
    }
    private var showingRecents: Bool {
        get { presentedPanel == .recents }
        nonmutating set {
            if newValue { presentedPanel = .recents }
            else if presentedPanel == .recents { presentedPanel = nil }
        }
    }
    private var showingGuideFromPlayer: Bool {
        get { presentedPanel == .guide }
        nonmutating set {
            if newValue { presentedPanel = .guide }
            else if presentedPanel == .guide { presentedPanel = nil }
        }
    }

    @State private var isChromeVisible = true
    @State private var controlsLocked = false
    #if os(macOS)
    @State private var desktopWindowState: (window: NSWindow, frame: NSRect, minimum: NSSize, aspect: NSSize, level: NSWindow.Level)?
    #endif
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var preferredOrientation: PlayerOrientation = .portrait
    private var isShowingMultiscreenPicker: Bool {
        get { presentedPanel == .multiview }
        nonmutating set {
            if newValue { presentedPanel = .multiview }
            else if presentedPanel == .multiview { presentedPanel = nil }
        }
    }
    @State private var selectedMultiChannelIDs: Set<String> = []
    @State private var multiscreenSession: PlayerMultiscreenSession?
    /// Chosen in the picker; presented once the picker sheet has finished dismissing.
    @State private var pendingMultiscreenSession: PlayerMultiscreenSession?
    #if os(iOS)
    @State private var brightnessDragStart: CGFloat?
    @State private var volumeDragStart: Float?
    @State private var brightnessController = ScreenBrightnessController()
    @State private var volumeController = SystemVolumeController()
    @State private var brightnessOverlay: CGFloat?
    @State private var volumeOverlay: Float?
    @State private var hudHideTask: Task<Void, Never>?
    @State private var showGestureHint = false
    private static let gestureOnboardingKey = "bannertv.player.gestureOnboarding.v1"
    #endif

    // Live score overlay
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
    @State private var isScoreDismissed = false
    @State private var scoreFetchTask: Task<Void, Never>?
    @State private var matchResolutionState: PlayerMatchResolutionState = .resolving
    @State private var selectedPlayerTab: SportPlayerTab = .game
    private var isLandscapeGameCentreVisible: Bool {
        get { presentedPanel == .sports }
        nonmutating set {
            if newValue { presentedPanel = .sports }
            else if presentedPanel == .sports { presentedPanel = nil }
        }
    }
    private var showPaywall: Bool {
        get { presentedPanel == .paywall }
        nonmutating set {
            if newValue { presentedPanel = .paywall }
            else if presentedPanel == .paywall { presentedPanel = nil }
        }
    }
    private var showingSourceSelector: Bool {
        get { presentedPanel == .broadcasts }
        nonmutating set {
            if newValue { presentedPanel = .broadcasts }
            else if presentedPanel == .broadcasts { presentedPanel = nil }
        }
    }
    private var showingFantasySidebar: Bool {
        get { presentedPanel == .fantasy }
        nonmutating set {
            if newValue { presentedPanel = .fantasy }
            else if presentedPanel == .fantasy { presentedPanel = nil }
        }
    }
    /// Shown briefly when Auto moves to another source after a failure.
    @State private var failoverNotice: String?
    @State private var aspectMode: PlayerAspectMode = .fit
    /// True when the player is laid out wider than tall (device or orientation button).
    @State private var isLandscapeLayout = false
    /// The player's own height. The swipe gestures measure against it rather than the screen's, which
    /// is wrong in Split View and Stage Manager windows.
    @State private var containerHeight: CGFloat = 0
    /// Lock-screen / Control Center metadata and remote play/pause while the player is open.
    @State private var nowPlaying = VideoNowPlaying()
    @StateObject private var liveTracker = FantasyLiveTrackerEngine.shared
    #if os(iOS)
    @State private var dismissalDragOffset: CGSize = .zero
    @State private var activeDismissalGesture: PlayerDismissalGestureKind?
    @State private var pipController: AVPictureInPictureController?
    #endif

    /// - Parameter tapDate: when the user asked for playback; defaults to the last
    ///   `PlaybackTapClock` tap, used to measure time-to-first-frame.
    init(channel: Channel, zapChannels: [Channel] = [], currentIndex: Int = 0, showsLiveTVControls: Bool = true, tapDate: Date? = nil) {
        self.channel = channel
        self.showsLiveTVControls = showsLiveTVControls
        self.matchPlaybackContext = nil
        let zap = zapChannels.isEmpty ? [channel] : zapChannels
        self.zapChannels = zap
        let idx = zap.indices.contains(currentIndex) ? currentIndex : 0
        _currentZapChannel = State(initialValue: zap[idx])
        _zapIndex = State(initialValue: idx)
        _streamSelection = StateObject(wrappedValue: StreamSelectionState(channel: zap[idx]))
        _playback = StateObject(wrappedValue: BannerAppEnvironment.shared.playbackController)
        _initialTapDate = State(initialValue: tapDate ?? PlaybackTapClock.consume() ?? Date())
    }

    init(canonicalChannel: CanonicalChannel, tapDate: Date? = nil) {
        let channel = canonicalChannel.playableChannel ?? Channel(
            id: canonicalChannel.id,
            name: canonicalChannel.name,
            streamURL: URL(string: "about:blank")!,
            logoURL: canonicalChannel.effectiveLogoURL,
            group: canonicalChannel.categoryId,
            playlistID: UUID(),
            playlistName: "Guide"
        )
        self.channel = channel
        self.showsLiveTVControls = true
        self.matchPlaybackContext = nil
        self.zapChannels = [channel]
        _currentZapChannel = State(initialValue: channel)
        _zapIndex = State(initialValue: 0)
        _streamSelection = StateObject(wrappedValue: StreamSelectionState(channel: channel, canonicalChannel: canonicalChannel))
        _playback = StateObject(wrappedValue: BannerAppEnvironment.shared.playbackController)
        _initialTapDate = State(initialValue: tapDate ?? PlaybackTapClock.consume() ?? Date())
    }

    init(context: MatchPlaybackContext, showsLiveTVControls: Bool = false, tapDate: Date? = nil) {
        self.channel = context.channel
        self.showsLiveTVControls = showsLiveTVControls
        self.matchPlaybackContext = context
        self.zapChannels = [context.channel]
        _currentZapChannel = State(initialValue: context.channel)
        _zapIndex = State(initialValue: 0)
        // The match's other ranked sources become failover/cycle candidates, in rank order.
        let candidates = context.rankedSources.filter(\.isConfirmed).prefix(StreamSelectionState.maxRawCandidates).map(\.channel)
        _streamSelection = StateObject(wrappedValue: StreamSelectionState(channel: context.channel, candidates: Array(candidates)))
        _playback = StateObject(wrappedValue: BannerAppEnvironment.shared.playbackController)
        _initialTapDate = State(initialValue: tapDate ?? PlaybackTapClock.consume() ?? Date())
    }

    private var compactPlayerAction: (() -> Void)? {
        #if os(macOS)
        return { toggleDesktopCompact() }
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private func toggleDesktopCompact() {
        if desktopWindowState != nil { restoreDesktopWindow(); return }
        guard let window = NSApplication.shared.keyWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        desktopWindowState = (window, window.frame, window.contentMinSize, window.contentAspectRatio, window.level)
        presentedPanel = nil
        window.contentMinSize = NSSize(width: 480, height: 270)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.setContentSize(NSSize(width: 640, height: 360))
        window.level = .floating
    }

    private func restoreDesktopWindow() {
        guard let saved = desktopWindowState else { return }
        saved.window.level = saved.level
        saved.window.contentMinSize = saved.minimum
        saved.window.contentAspectRatio = saved.aspect
        saved.window.setFrame(saved.frame, display: true)
        desktopWindowState = nil
    }
    #endif

    private var pictureInPictureAction: (() -> Void)? {
        #if os(iOS)
        guard let controller = pipController, controller.isPictureInPicturePossible else { return nil }
        return { controller.startPictureInPicture() }
        #else
        return nil
        #endif
    }

    private var canonicalChannel: CanonicalChannel? {
        streamSelection.canonicalChannel
    }

    // Sorting and deduping a big playlist is expensive, so it runs once off
    // the main thread instead of inside every body evaluation.
    @State private var multiscreenChannels: [Channel] = []

    private var canStartMultiscreen: Bool {
        guard let stores else { return false }
        let hasOtherChannels = stores.playlistStore.channelsByPlaylist.values.contains { channels in
            channels.contains { $0.id != currentZapChannel.id }
        }
        return hasOtherChannels
    }

    /// "More in {group}": other channels in the zap list from the same group.
    private var relatedChannels: [Channel] {
        let group = currentZapChannel.group
        return zapChannels.filter { $0.id != activePlaybackChannel.id && $0.group == group }.prefix(12).map { $0 }
    }

    private var activePlaybackChannel: Channel {
        streamSelection.activeChannel
    }

    private var playerScaleForDismissal: CGFloat {
        #if os(iOS)
        let travel = max(dismissalDragOffset.width, dismissalDragOffset.height, 0)
        return max(0.92, 1 - travel / 1800)
        #else
        return 1
        #endif
    }

    private var playerDimForDismissal: Double {
        #if os(iOS)
        let travel = max(dismissalDragOffset.width, dismissalDragOffset.height, 0)
        return max(0.58, 1 - Double(travel / 650))
        #else
        return 1
        #endif
    }

    /// The screen plus its presentation modifiers; split from `body` to keep type-checking fast.
    private var playerCore: some View {
        MatchPlayerScreen(
            channel: activePlaybackChannel,
            canonicalChannel: canonicalChannel,
            match: prefs.spoilerFreeMode ? nil : liveScoreMatch,
            scoreBugMatch: prefs.showLiveScoreBadge && !isScoreDismissed ? displayedScoreMatch : nil,
            matchResolutionState: matchResolutionState,
            selectedTab: $selectedPlayerTab,
            isChromeVisible: isChromeVisible && !controlsLocked,
            isLandscapeGameCentreVisible: panelBinding(.sports),
            streamSummary: activeStreamMetadata.map { metadata in
                [metadata.height.map { "\($0)p" }, metadata.frameRate.map { String(format: "%.0f fps", $0) }]
                    .compactMap { $0 }.joined(separator: " · ")
            } ?? "Live",
            canStartMultiscreen: canStartMultiscreen,
            hasPreviousChannel: zapIndex > 0,
            hasNextChannel: zapIndex < zapChannels.count - 1,
            showsLiveTVControls: showsLiveTVControls,
            hasMultipleSources: streamSelection.hasSelectableStreams,
            isBehindLiveEdge: playback.isBehindLiveEdge,
            chrome: chromeState,
            actions: PlayerChromeActions(
                onPlayPause: { togglePlayPause() },
                onToggleMute: { playback.setMuted(!playback.isMuted); revealChromeTemporarily() },
                onCycleAspect: { setAspect(aspectMode.next) }
            ),
            onGoLive: { playback.seekToLiveEdge(); revealChromeTemporarily() },
            onDismiss: { dismiss() },
            onPreviousChannel: { zapTo(index: zapIndex - 1) },
            onNextChannel: { zapTo(index: zapIndex + 1) },
            onGuide: { showingGuideFromPlayer = true },
            onChannels: { showingChannelList = true },
            onRecents: { showingRecents = true },
            onMore: { showingMore = true },
            onSourceSelector: { showingSourceSelector = true; revealChromeTemporarily() },
            onCycleSource: cycleSource(direction:),
            onToggleOrientation: { toggleOrientation() },
            onPiP: pictureInPictureAction,
            orientation: preferredOrientation
        ) {
            PlayerSurface(controller: playback, videoGravity: aspectMode.videoGravity) { controller in
                #if os(iOS)
                pipController = controller
                #endif
            }
            .modifier(OriginalVideoSize(mode: aspectMode, videoSize: playback.player.currentItem?.presentationSize ?? .zero))
            .overlay { PlaybackStatusOverlay(controller: playback, channel: activePlaybackChannel, failoverNotice: failoverNotice) }
            #if os(macOS)
            .onTapGesture(count: 2) { NSApplication.shared.keyWindow?.toggleFullScreen(nil) }
            #endif
            #if os(iOS)
            .overlay { playerGestureZones.allowsHitTesting(!controlsLocked) }
            #endif
        } channelPage: {
            PlayerChannelInfoPage(
                channel: activePlaybackChannel,
                canonicalChannel: canonicalChannel ?? stores?.epgRepository.canonicalChannel(forProviderChannelID: activePlaybackChannel.id, playlistID: activePlaybackChannel.playlistID),
                isResolvingMatch: matchResolutionState.isPending,
                relatedChannels: relatedChannels,
                onSelectChannel: { switchChannel(to: $0) }
            )
        }
        .overlay(alignment: .topTrailing) { PlayerSportsAlertBanner() }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape in
            isLandscapeLayout = landscape
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
        #if os(iOS)
        .offset(x: dismissalDragOffset.width, y: max(0, dismissalDragOffset.height))
        .scaleEffect(playerScaleForDismissal)
        .opacity(playerDimForDismissal)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: dismissalDragOffset)
        #endif
        .overlay(alignment: .topTrailing) {
            if controlsLocked {
                Button { controlsLocked = false; revealChromeTemporarily() } label: {
                    Label("Unlock controls", systemImage: "lock.open.fill")
                        .padding(12).background(.black.opacity(0.75), in: Capsule())
                }
                .foregroundStyle(.white).padding()
            }
        }
        .contentShape(Rectangle())
        #if os(iOS)
        .simultaneousGesture(playerDismissalGesture)
        .simultaneousGesture(landscapeSwipeGesture)
        .overlay {
            ZStack {
                ScreenBrightnessHost(controller: brightnessController)
                SystemVolumeView(controller: volumeController)
            }
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .allowsHitTesting(false)
        }
        .overlay {
            ZStack {
                if let level = brightnessOverlay {
                    PlayerAdjustmentHUD(
                        icon: level < 0.35 ? "sun.min.fill" : "sun.max.fill",
                        level: Double(level),
                        tint: Theme.Palette.gold
                    )
                    .id("brightness")
                } else if let level = volumeOverlay {
                    PlayerAdjustmentHUD(
                        icon: level == 0 ? "speaker.slash.fill" : (level < 0.4 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"),
                        level: Double(level),
                        tint: .white
                    )
                    .id("volume")
                }
            }
            .animation(Theme.Motion.snappy, value: brightnessOverlay != nil || volumeOverlay != nil)
            .allowsHitTesting(false)
        }
        #endif
        .overlay(alignment: .center) {
            if case let .failed(message) = streamSelection.switchState {
                StreamFailurePanel(
                    message: message,
                    tryAgain: { streamSelection.retryActiveStream(); revealChromeTemporarily() },
                    chooseAnother: streamSelection.hasSelectableStreams ? { showingSourceSelector = true; revealChromeTemporarily() } : nil,
                    switchToAuto: { streamSelection.selectAuto(); revealChromeTemporarily() },
                    returnToGuide: { showingGuideFromPlayer = true }
                )
                .padding(24)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .overlay(alignment: .center) {
            if streamSelection.switchState == .switching {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(18)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
        }
        // Gesture onboarding hint
        #if os(iOS)
        .overlay(alignment: .center) {
            if showGestureHint {
                PlayerGestureHint {
                    withAnimation(Theme.Motion.snappy) { showGestureHint = false }
                    UserDefaults.standard.set(true, forKey: Self.gestureOnboardingKey)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(Theme.Motion.snappy, value: showGestureHint)
        #endif
        .sheet(isPresented: panelBinding(.multiview), onDismiss: {
            multiscreenChannels = []
            if let session = pendingMultiscreenSession {
                pendingMultiscreenSession = nil
                multiscreenSession = session
            }
        }) {
            PlayerMultiscreenPicker(currentChannel: currentZapChannel,
                                    allChannels: multiscreenChannels,
                                    selectedChannelIDs: $selectedMultiChannelIDs,
                                    startAction: startMultiscreen)
        }
        .sheet(isPresented: panelBinding(.broadcasts)) {
            NavigationStack {
                StreamSourceSelectionView(selection: streamSelection)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingSourceSelector = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: panelBinding(.settings)) {
            PlayerMoreSheet(
                channel: activePlaybackChannel,
                streamSelection: streamSelection,
                playback: playback,
                bufferProfile: Binding(
                    get: { prefs.playerBufferProfile },
                    set: { profile in
                        prefs.setPlayerBufferProfile(profile)
                        playback.setBufferProfile(profile)
                    }
                ),
                aspect: Binding(get: { aspectMode }, set: { setAspect($0) }),
                audioGroup: audioGroup,
                selectedAudioIndex: Binding(get: { selectedAudioIndex }, set: { selectedAudioIndex = $0; applyAudioTrack(index: $0) }),
                subtitleGroup: subtitleGroup,
                selectedSubtitleIndex: Binding(get: { selectedSubtitleIndex }, set: { selectedSubtitleIndex = $0; applySubtitleTrack(index: $0) }),
                streamMetadata: activeStreamMetadata,
                canStartMultiscreen: canStartMultiscreen,
                multiscreenAction: { showingMore = false; showMultiscreenPicker() },
                lockAction: { showingMore = false; controlsLocked = true },
                compactAction: compactPlayerAction,
                recommendationAction: { channel in showingMore = false; switchChannel(to: channel) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: panelBinding(.channels)) {
            PlayerChannelListSheet(
                channels: stores?.playlistStore.allChannels ?? zapChannels,
                currentChannelID: StreamLinkerAdapters.streamID(currentZapChannel),
                onSelect: { channel, _ in switchChannel(to: channel) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: panelBinding(.recents)) {
            PlayerRecentsSheet(
                currentChannelID: StreamLinkerAdapters.streamID(currentZapChannel),
                onSelect: { ch in switchChannel(to: ch) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #if os(macOS)
        .sheet(isPresented: panelBinding(.guide)) {
            TVGuideView(onChannelSelected: { canonicalChannel in
                if let ch = canonicalChannel.playableChannel {
                    switchChannel(to: ch, canonicalChannel: canonicalChannel)
                }
                showingGuideFromPlayer = false
            }, onCatchupSelected: { channel in
                switchChannel(to: channel)
                showingGuideFromPlayer = false
            }, viewModel: playerGuideModel, preview: AnyView(VideoSurface(player: playback.player, showsPlaybackControls: false, allowsPictureInPicture: false) { _ in }))
        }
        #else
        .fullScreenCover(isPresented: panelBinding(.guide)) {
            TVGuideView(onChannelSelected: { canonicalChannel in
                if let ch = canonicalChannel.playableChannel {
                    switchChannel(to: ch, canonicalChannel: canonicalChannel)
                }
                showingGuideFromPlayer = false
            }, onCatchupSelected: { channel in
                switchChannel(to: channel)
                showingGuideFromPlayer = false
            }, viewModel: playerGuideModel, preview: AnyView(VideoSurface(player: playback.player, showsPlaybackControls: false, allowsPictureInPicture: false) { _ in }))
        }
        #endif
        .overlay(alignment: .trailing) {
            if showingFantasySidebar && !prefs.spoilerFreeMode {
                FantasyMatchupSidebarView(
                    onWatchChannel: { ch in
                        withAnimation(Theme.Motion.snappy) { showingFantasySidebar = false }
                        zapToChannel(ch)
                    },
                    onClose: {
                        withAnimation(Theme.Motion.snappy) { showingFantasySidebar = false }
                    }
                )
                .environmentObject(FantasyStore.shared)
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
                        zapToChannel(ch)
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
                    zapToChannel(ch)
                })
                .padding(.bottom, 85)
                .zIndex(85)
            }
        }
        .background {
            // Observes FantasyStore on its own so fantasy updates don't re-render the player.
            PlayerFantasyTrackerBridge(liveTracker: liveTracker, channels: { stores?.playlistStore.allChannels ?? [] })
        }
        #if os(macOS)
        .sheet(item: $multiscreenSession) { session in
            MultiScreenPlayerView(channels: session.channels, initialLayout: session.savedLayout, initialAudioChannelID: session.audioChannelID)
        }
        #else
        .fullScreenCover(item: $multiscreenSession) { session in
            MultiScreenPlayerView(channels: session.channels, initialLayout: session.savedLayout, initialAudioChannelID: session.audioChannelID)
        }
        #endif
        .sheet(isPresented: panelBinding(.paywall)) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Keyboard shortcuts and VoiceOver actions, so the player can be driven without finding each control.
    private var accessiblePlayer: some View {
        let playPauseName = Text(playback.isUserPaused ? "Play" : "Pause")
        return playerCore
            .overlay { if !isAnySheetPresented && !controlsLocked { keyboardCommandHandler } }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active: revealChromeTemporarily()
                case .ended: break
                }
            }
            #endif
            .accessibilityAction(named: playPauseName) { playback.togglePlayPause() }
            .accessibilityAction(named: Text("Next channel")) { zapTo(index: zapIndex + 1) }
            .accessibilityAction(named: Text("Previous channel")) { zapTo(index: zapIndex - 1) }
            .accessibilityAction(named: Text("Show controls")) { revealChromeTemporarily() }
            .animation(Theme.Motion.snappy, value: isChromeVisible)
    }

    var body: some View {
        accessiblePlayer
        .onAppear {
            startPlayback()
            watchStore.recordWatch(channel)
            startDwellTimer()
            revealChromeTemporarily()
        }
        #if os(iOS)
        // The brightness/volume swipes only exist in landscape, so only teach them there.
        .onChange(of: isLandscapeLayout) { _, landscape in
            guard landscape, !UserDefaults.standard.bool(forKey: Self.gestureOnboardingKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.gestureOnboardingKey)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                withAnimation(Theme.Motion.smooth) { showGestureHint = true }
                try? await Task.sleep(for: .seconds(4))
                withAnimation(Theme.Motion.smooth) { showGestureHint = false }
            }
        }
        #endif
        .task(id: prefs.sportsScoreDelaySeconds) {
            guard prefs.sportsScoreDelaySeconds > 0 else { return }
            while !Task.isCancelled {
                scoreDisplayDate = Date()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: prefs.spoilerFreeMode) { _, hidden in
            if hidden && (presentedPanel == .sports || presentedPanel == .fantasy) { presentedPanel = nil }
        }
        .onChange(of: playback.isUserPaused) { _, paused in
            // Controls stay up while paused; resume the auto-hide when playing again.
            if paused { chromeHideTask?.cancel(); isChromeVisible = true } else { revealChromeTemporarily() }
            updateNowPlaying()
        }
        .onChange(of: StreamLinkerAdapters.streamID(activePlaybackChannel)) {
            aspectMode = PlayerAspectMode.saved(for: activePlaybackChannel.id)
            updateNowPlaying()
        }
        .onDisappear {
            dwellTask?.cancel()
            chromeHideTask?.cancel()
            scoreFetchTask?.cancel()
            // A guide cover is navigation within this playback session.
            if !showingGuideFromPlayer { endPlayback() }
            #if os(iOS)
            brightnessDragStart = nil
            volumeDragStart = nil
            #endif
            requestOrientation(.portrait)
        }
        .onChange(of: multiscreenSession?.id) { _, session in
            if session != nil { playback.stop() }
            else { startPlayback() }
        }
        .onChange(of: streamSelection.loadToken) {
            // A new channel, source, failover or retry: swap the item on the same player.
            loadActiveStream()
        }
        .task(id: StreamLinkerAdapters.streamID(currentZapChannel)) {
            isScoreDismissed = false
            scoreFetchTask?.cancel()
            publishMatch(nil)
            if let ctx = matchPlaybackContext,
               ctx.channel.id == currentZapChannel.id,
               ctx.channel.playlistID == currentZapChannel.playlistID,
               await matchCandidateScore(ctx.match, channel: currentZapChannel, programme: currentProgramme(for: currentZapChannel)) >= 70 {
                guard !Task.isCancelled else { return }
                publishMatch(ctx.match)
                matchResolutionState = .connected
                let match = ctx.match
                scoreFetchTask = Task { await pollMatchUpdates(for: match) }
            } else {
                let zapChannel = currentZapChannel
                scoreFetchTask = Task { await findAndPollLiveMatch(for: zapChannel) }
            }
        }
    }

    #if os(iOS)
    /// Taps and swipes on the video. Tap toggles the controls; double-tap the left/right
    /// half for previous/next channel; pinch switches Fit/Fill. In landscape, a vertical
    /// swipe on the left half changes brightness and on the right half volume.
    private var playerGestureZones: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                gestureZone(side: .brightness, height: proxy.size.height, doubleTap: { handleDoubleTap(direction: -1) })
                gestureZone(side: .volume, height: proxy.size.height, doubleTap: { handleDoubleTap(direction: 1) })
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onEnded { value in
                        if value.magnification > 1.15, aspectMode == .fit { setAspect(.fill) }
                        if value.magnification < 0.87, aspectMode != .fit { setAspect(.fit) }
                    }
            )
        }
    }

    @ViewBuilder
    private func gestureZone(side: PlayerAdjustmentSide, height: CGFloat, doubleTap: @escaping () -> Void) -> some View {
        let zone = Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: doubleTap)
            .onTapGesture { toggleChromeVisibility() }
        if isLandscapeLayout {
            zone.gesture(verticalAdjustmentGesture(height: height, side: side))
        } else {
            zone
        }
    }

    private var playerDismissalGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                if activeDismissalGesture == nil {
                    activeDismissalGesture = dismissalGestureKind(for: value)
                }
                guard let gesture = activeDismissalGesture else { return }
                switch gesture {
                case .edgePop:
                    dismissalDragOffset = CGSize(width: max(0, value.translation.width), height: 0)
                case .pullDown:
                    dismissalDragOffset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                guard let gesture = activeDismissalGesture else {
                    resetDismissalDrag()
                    return
                }
                let shouldDismiss: Bool
                switch gesture {
                case .edgePop:
                    shouldDismiss = value.translation.width > 110 || value.predictedEndTranslation.width > 220
                case .pullDown:
                    shouldDismiss = value.translation.height > 150 || value.predictedEndTranslation.height > 300
                }
                if shouldDismiss {
                    dismiss()
                } else {
                    resetDismissalDrag()
                }
            }
    }

    private func dismissalGestureKind(for value: DragGesture.Value) -> PlayerDismissalGestureKind? {
        guard !controlsLocked else { return nil }
        let horizontal = value.translation.width
        let vertical = value.translation.height
        if value.startLocation.x <= 24, horizontal > 18, abs(horizontal) > abs(vertical) * 1.25 {
            return .edgePop
        }
        let upperPlayerLimit = containerHeight * 0.46
        if value.startLocation.y <= upperPlayerLimit, vertical > 18, abs(vertical) > abs(horizontal) * 1.2 {
            return .pullDown
        }
        return nil
    }

    private func resetDismissalDrag() {
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
            dismissalDragOffset = .zero
            activeDismissalGesture = nil
        }
    }

    private var landscapeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 80, coordinateSpace: .global)
            .onEnded { value in
                guard !controlsLocked, preferredOrientation == .portrait else { return }
                guard value.translation.height < -80,
                      abs(value.translation.height) > abs(value.translation.width) * 1.5,
                      abs(value.predictedEndTranslation.height) > 160 else { return }
                let videoAreaThreshold = containerHeight * 0.55
                guard value.startLocation.y < videoAreaThreshold else { return }
                toggleOrientation()
            }
    }
    #endif

    private var keyboardCommandHandler: some View {
        LiveCommandKeyboardHandler(
            onChannelUp:       { zapTo(index: zapIndex - 1) },
            onChannelDown:     { zapTo(index: zapIndex + 1) },
            onToggleChrome:    { togglePlayPause() },
            onOpenGuide:       { showingGuideFromPlayer = true; revealChromeTemporarily() },
            onOpenChannelList: { showingChannelList = true; revealChromeTemporarily() },
            onOpenRecents:     { showingRecents = true; revealChromeTemporarily() },
            onExit:            { handleBack() },
            onMute:            { playback.setMuted(!playback.isMuted) },
            onFullscreen:      {
                #if os(macOS)
                NSApplication.shared.keyWindow?.toggleFullScreen(nil)
                #else
                toggleOrientation()
                #endif
            },
            onSports:          { if liveScoreMatch != nil && !prefs.spoilerFreeMode { isLandscapeGameCentreVisible.toggle() } },
            onPrevious:        { if let previousChannel { switchChannel(to: previousChannel) } },
            onPictureInPicture: {
                #if os(macOS)
                toggleDesktopCompact()
                #else
                pictureInPictureAction?()
                #endif
            },
            onRestoreMultiview: restoreMultiview
        )
    }

    private func restoreMultiview(slot: Int) {
        guard let saved = prefs.savedMultiview(slot: slot), let stores else { return }
        guard entitlements.isPremium else { showPaywall = true; return }
        let channels = saved.channelIDs.compactMap { id in
            stores.playlistStore.allChannels.first { StreamLinkerAdapters.streamID($0) == id }
        }
        guard !channels.isEmpty else { return }
        multiscreenSession = PlayerMultiscreenSession(channels: Array(channels.prefix(min(PlaybackController.multiviewCapacity, prefs.playerMaximumStreams))), savedLayout: saved.layout, audioChannelID: saved.audioChannelID)
    }

    private func handleBack() {
        if isLandscapeGameCentreVisible { isLandscapeGameCentreVisible = false; return }
        if showingFantasySidebar { showingFantasySidebar = false; return }
        #if os(macOS)
        if let window = NSApplication.shared.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        #endif
        dismiss()
    }

    private func toggleOrientation() {
        preferredOrientation = preferredOrientation.toggled
        requestOrientation(preferredOrientation)
        revealChromeTemporarily()
    }

    private func showMultiscreenPicker() {
        guard entitlements.isPremium else {
            showPaywall = true
            return
        }
        selectedMultiChannelIDs = [StreamLinkerAdapters.streamID(activePlaybackChannel)]
        isShowingMultiscreenPicker = true
        revealChromeTemporarily()
        // Sorting a big playlist is expensive, so it only happens when the picker opens.
        let channels = stores?.playlistStore.allChannels ?? []
        let current = activePlaybackChannel
        Task {
            multiscreenChannels = await Task.detached(priority: .userInitiated) {
                var seenIDs: Set<String> = [StreamLinkerAdapters.streamID(current)]
                var result = [current]
                let sorted = channels.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                for candidate in sorted where seenIDs.insert(StreamLinkerAdapters.streamID(candidate)).inserted {
                    result.append(candidate)
                }
                return result
            }.value
        }
    }

    private func startMultiscreen() {
        let channels = multiscreenChannels.filter { selectedMultiChannelIDs.contains(StreamLinkerAdapters.streamID($0)) }
        guard channels.count >= 2 else { return }
        pendingMultiscreenSession = PlayerMultiscreenSession(channels: Array(channels.prefix(PlaybackController.multiviewCapacity)))
        selectedMultiChannelIDs.removeAll()
        isShowingMultiscreenPicker = false
    }

    private func requestOrientation(_ orientation: PlayerOrientation) {
        #if os(iOS)
        guard #available(iOS 16.0, *) else { return }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation.interfaceOrientationMask)) { error in
            #if DEBUG
            print("Player orientation request failed: \(error.localizedDescription)")
            #endif
        }
        #endif
    }

    private func toggleChromeVisibility() {
        chromeHideTask?.cancel()
        isChromeVisible.toggle()
        if isChromeVisible {
            scheduleChromeHide()
        }
    }

    private func revealChromeTemporarily() {
        chromeHideTask?.cancel()
        isChromeVisible = true
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(prefs.playerPanelTimeoutSeconds))
            guard !Task.isCancelled else { return }
            // Never hide while paused, buffering or while a sheet/panel is open; check again later.
            if voiceOverEnabled || playback.isUserPaused || playback.showsBufferingIndicator || isAnySheetPresented {
                scheduleChromeHide()
                return
            }
            isChromeVisible = false
        }
    }

    private var isAnySheetPresented: Bool {
        showingMore || showingChannelList || showingRecents || showingGuideFromPlayer
            || showingSourceSelector || isShowingMultiscreenPicker || showingFantasySidebar || showPaywall
    }

    private func handleDoubleTap(direction: Int) {
        if prefs.playerDoubleTapSeeks { playback.seek(by: Double(direction) * 10) }
        else { zapTo(index: zapIndex + direction) }
        revealChromeTemporarily()
    }

    private func togglePlayPause() {
        playback.togglePlayPause()
    }

    private func setAspect(_ mode: PlayerAspectMode) {
        withAnimation(Theme.Motion.snappy) { aspectMode = mode }
        PlayerAspectMode.save(mode, for: activePlaybackChannel.id)
        revealChromeTemporarily()
    }

    /// Values the video chrome renders.
    private var chromeState: PlayerChromeState {
        let programme = currentProgramme(for: activePlaybackChannel)
        return PlayerChromeState(
            isPlaying: !playback.isUserPaused,
            isMuted: playback.isMuted,
            aspect: aspectMode,
            logoURL: activePlaybackChannel.logoURL,
            subtitle: programme?.title,
            programme: programme
        )
    }

    private func updateNowPlaying() {
        let programme = currentProgramme(for: activePlaybackChannel)
        nowPlaying.update(title: liveScoreMatch?.shortName ?? activePlaybackChannel.name,
                          subtitle: programme?.title ?? activePlaybackChannel.name,
                          artworkURL: activePlaybackChannel.logoURL,
                          isPlaying: !playback.isUserPaused)
    }

    // MARK: Channel zapping

    private func zapToChannel(_ ch: Channel) {
        switchChannel(to: ch)
    }

    private func zapTo(index: Int) {
        guard zapChannels.indices.contains(index), zapChannels[index].id != currentZapChannel.id else { return }
        switchChannel(to: zapChannels[index])
    }

    /// The one path for every in-player channel change (arrows, keyboard, channel list,
    /// recents, guide, fantasy). Resets stream selection, which bumps its load token so
    /// the shared player swaps to the new channel's item.
    /// - Parameter explicitCanonical: set when the guide picked a canonical channel; otherwise
    ///   the channel's canonical match is looked up so its other mirrors are available for failover.
    private func switchChannel(to newChannel: Channel, canonicalChannel explicitCanonical: CanonicalChannel? = nil) {
        if let explicitCanonical, explicitCanonical.id == canonicalChannel?.id { return }
        if explicitCanonical == nil, newChannel.id == activePlaybackChannel.id, newChannel.playlistID == activePlaybackChannel.playlistID { return }

        let canonical = explicitCanonical ?? stores?.epgRepository.canonicalChannel(forProviderChannelID: newChannel.id, playlistID: newChannel.playlistID)
        dwellTask?.cancel()
        currentPlayerItem = nil
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        activeStreamMetadata = nil
        failoverNotice = nil
        if let index = zapChannels.firstIndex(where: { $0.id == newChannel.id && $0.playlistID == newChannel.playlistID }) {
            zapIndex = index
        }
        previousChannel = currentZapChannel
        scoreFetchTask?.cancel()
        publishMatch(nil)
        matchResolutionState = .resolving
        currentZapChannel = newChannel
        // From a list the user picked this exact mirror, so start on it; from the guide, let Auto rank.
        streamSelection.reset(to: newChannel,
                              canonicalChannel: canonical,
                              preferredStreamID: explicitCanonical == nil ? newChannel.id : nil)
        loadActiveStream()
        startDwellTimer()
        revealChromeTemporarily()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: Playback lifecycle

    private func startPlayback() {
        MatchNotificationService.shared.playerIsVisible = true
        playback.setBufferProfile(prefs.playerBufferProfile)
        aspectMode = PlayerAspectMode.saved(for: activePlaybackChannel.id)
        nowPlaying.activate(controller: playback)
        updateNowPlaying()
        if let context = matchPlaybackContext, let stores,
           context.channel.id == currentZapChannel.id, context.channel.playlistID == currentZapChannel.playlistID {
            streamSelection.broadcastValidator = { [weak streamStore = stores.streamStore, weak playlistStore = stores.playlistStore, weak epg = stores.epgRepository] candidate in
                guard let streamStore, let playlistStore, let epg else { return false }
                return await streamStore.confirmsCurrentBroadcast(match: context.match, channel: candidate, channels: playlistStore.allChannels, epgRepository: epg)
            }
        }
        playback.onFailure = { reason in
            guard playback.channel == streamSelection.activeChannel else { return }
            let tokenBefore = streamSelection.loadToken
            streamSelection.handlePlaybackFailure(message: reason)
            if streamSelection.loadToken != tokenBefore {
                // Auto picked another candidate; the load-token change starts it.
                failoverNotice = "Trying another source…"
            } else {
                #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                #endif
            }
        }
        playback.onFirstFrame = { playedChannel, _ in
            guard playedChannel == streamSelection.activeChannel else { return }
            streamSelection.recordPlaybackSuccess(streamID: streamSelection.activeStream?.id ?? playedChannel.id)
            failoverNotice = nil
        }
        playback.onItemReady = { item in
            handlePlayerItemReady(item)
        }
        playback.onMetadata = { metadata in
            guard playback.channel == streamSelection.activeChannel else { return }
            activeStreamMetadata = metadata
            if let streamID = streamSelection.activeStream?.id {
                streamSelection.updateRuntimeMetadata(metadata, for: streamID)
            }
        }
        // onAppear can fire again (e.g. after a full-screen cover); only load if nothing is
        // playing — including nothing already started by CarPlay on this same shared controller.
        if playback.channel != activePlaybackChannel || playback.currentItem == nil {
            playback.notePendingTapDate(initialTapDate)
            loadActiveStream()
        }
    }

    private func loadActiveStream() {
        guard lastAppliedLoadToken != streamSelection.loadToken || playback.currentItem == nil
                || playback.channel != streamSelection.activeChannel else { return }
        lastAppliedLoadToken = streamSelection.loadToken
        currentPlayerItem = nil
        audioGroup = nil
        subtitleGroup = nil
        activeStreamMetadata = nil
        playback.load(streamSelection.activeChannel)
        Task { await streamSelection.preflightAlternates() }
    }

    private func endPlayback() {
        MatchNotificationService.shared.playerIsVisible = false
        MatchNotificationService.shared.playerMatchID = nil
        streamSelection.cancelPendingValidation()
        streamSelection.broadcastValidator = nil
        // The controller's closures capture this view; clear them so nothing leaks after dismissal.
        playback.onFailure = nil
        playback.onFirstFrame = nil
        playback.onItemReady = nil
        playback.onMetadata = nil
        #if os(iOS)
        // Keep the player (and its lock-screen controls) alive while Picture in Picture is showing it.
        if pipController?.isPictureInPictureActive == true { return }
        #endif
        #if os(macOS)
        restoreDesktopWindow()
        #endif
        nowPlaying.deactivate()
        playback.stop()
    }

    private func cycleSource(direction: Int) {
        let candidates = streamSelection.displayCandidates.filter { $0.health != .unavailable }
        guard candidates.count > 1 else { return }
        let currentID = streamSelection.activeStream?.id ?? candidates.first?.stream.id
        let currentIndex = candidates.firstIndex { $0.stream.id == currentID } ?? 0
        let nextIndex = (currentIndex + direction + candidates.count) % candidates.count
        streamSelection.selectManual(streamID: candidates[nextIndex].stream.id)
        revealChromeTemporarily()
    }

    private func startDwellTimer() {
        dwellTask?.cancel()
        let ch = currentZapChannel
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            watchStore.recordRecent(ch)
        }
    }

    // MARK: Track selection

    private func handlePlayerItemReady(_ item: AVPlayerItem) {
        currentPlayerItem = item
        Task { @MainActor in
            guard let tracks = await playback.mediaSelections(for: item, preferences: prefs),
                  currentPlayerItem === item else { return }
            audioGroup = tracks.audio
            subtitleGroup = tracks.subtitles
            selectedAudioIndex = tracks.audioIndex
            selectedSubtitleIndex = tracks.subtitleIndex
        }
    }

    private func applyAudioTrack(index: Int?) {
        playback.selectMedia(index: index, group: audioGroup, isSubtitle: false, preferences: prefs)
    }

    private func applySubtitleTrack(index: Int?) {
        playback.selectMedia(index: index, group: subtitleGroup, isSubtitle: true, preferences: prefs)
    }

    // MARK: Live score tracking

    /// Polls for live score updates when the match identity is already known (context-launched player).
    /// Unlike `findAndPollLiveMatch`, this never searches league schedules — it only refreshes the
    /// match we were explicitly handed.
    private func pollMatchUpdates(for match: Match) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await SportsRepository.shared.legacyScoreboard(for: match.league).first(where: { $0.id == match.id }) {
                let enriched = await SportsRepository.shared.enrichedLegacyMatch(updated)
                guard !Task.isCancelled else { return }
                guard updated.state == .live, abs(updated.date.timeIntervalSinceNow) < 12 * 3600 else {
                    publishMatch(nil)
                    matchResolutionState = .unavailable
                    return
                }
                publishMatch(enriched)
                matchResolutionState = .connected
            } else {
                matchResolutionState = .apiFailed
            }
        }
    }

    private func findAndPollLiveMatch(for targetChannel: Channel) async {
        let channel = targetChannel
        matchResolutionState = .resolving

        // Don't compete with the video for network: wait for the first frame, then a beat more.
        while !playback.firstFrameRendered {
            if case .failed = playback.state {
                matchResolutionState = .unavailable
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }

        let programme = currentProgramme(for: channel)
        // Only sports channels are looked up, and only in the leagues they hint at.
        let leagues = PlayerLiveMatchLeagueHint.leagues(channelName: channel.name, group: channel.group, programme: programme)
        guard !leagues.isEmpty else {
            publishMatch(nil)
            matchResolutionState = .unavailable
            return
        }
        let today = Calendar.current.startOfDay(for: Date())

        var candidates: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask {
                    let live = (try? await SportsRepository.shared.cachedLegacyScoreboard(for: league)) ?? []
                    let todaySchedule = (try? await SportsRepository.shared.cachedLegacyScoreboards(for: league, starting: today, days: 1)) ?? []
                    return live + todaySchedule
                }
            }
            for await matches in group {
                candidates.append(contentsOf: matches.filter { $0.state == .live || $0.state == .pre })
            }
        }
        guard !Task.isCancelled else { return }

        var seenIDs = Set<String>()
        let uniqueCandidates = candidates.filter { seenIDs.insert($0.id).inserted }
        var bestMatch: Match?
        var bestScore = 0
        var confirmedCount = 0
        for match in uniqueCandidates {
            let score = await matchCandidateScore(match, channel: channel, programme: programme)
            if score >= 70 { confirmedCount += 1 }
            if score > bestScore {
                bestScore = score
                bestMatch = match
            }
        }

        guard !Task.isCancelled else { return }
        guard let match = bestMatch, bestScore >= 70, confirmedCount == 1 else {
            publishMatch(nil)
            matchResolutionState = .unavailable
            return
        }

        matchResolutionState = .loadingData
        let enriched = await SportsRepository.shared.enrichedLegacyMatch(match)
        guard !Task.isCancelled else { return }
        publishMatch(enriched)
        matchResolutionState = .connected

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await SportsRepository.shared.legacyScoreboard(for: match.league).first(where: { $0.id == match.id }) {
                let enriched = await SportsRepository.shared.enrichedLegacyMatch(updated)
                guard !Task.isCancelled else { return }
                guard updated.state == .live, abs(updated.date.timeIntervalSinceNow) < 12 * 3600 else {
                    publishMatch(nil)
                    matchResolutionState = .unavailable
                    return
                }
                publishMatch(enriched)
                matchResolutionState = .connected
            } else {
                matchResolutionState = .apiFailed
            }
        }
    }

    private func currentProgramme(for channel: Channel) -> EPGProgramme? {
        guard let epgRepository = stores?.epgRepository else { return nil }
        if let canonicalChannel {
            return epgRepository.currentProgramme(for: canonicalChannel.id)
        }
        if let canonical = epgRepository.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID) {
            return epgRepository.currentProgramme(for: canonical.id)
        }
        return nil
    }

    private func matchCandidateScore(_ match: Match, channel: Channel, programme: EPGProgramme?) async -> Int {
        // The shared linker checks both teams, time windows and replay evidence.
        // A channel-name/league token bonus must never promote an unverified feed.
        guard match.state == .live, abs(match.date.timeIntervalSinceNow) < 12 * 3600,
              let stores else { return 0 }
        return await stores.streamStore.confidenceScore(
            match: match, channel: channel, channels: stores.playlistStore.allChannels,
            epgRepository: stores.epgRepository
        )
    }

    #if os(iOS)
    private func scheduleHudHide() {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Motion.snappy) {
                brightnessOverlay = nil
                volumeOverlay = nil
            }
        }
    }

    private func verticalAdjustmentGesture(height: CGFloat, side: PlayerAdjustmentSide) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                hudHideTask?.cancel()
                let delta = Float(-value.translation.height / max(height, 1))
                switch side {
                case .brightness:
                    guard let currentBrightness = brightnessController.currentBrightness else { return }
                    if brightnessDragStart == nil {
                        brightnessDragStart = currentBrightness
                    }
                    let start = Float(brightnessDragStart ?? currentBrightness)
                    let newLevel = CGFloat(min(max(start + delta, 0), 1))
                    brightnessController.setBrightness(newLevel)
                    brightnessOverlay = newLevel
                    volumeOverlay = nil
                case .volume:
                    if volumeDragStart == nil {
                        volumeDragStart = volumeController.currentVolume
                    }
                    let start = volumeDragStart ?? volumeController.currentVolume
                    let newLevel = min(max(start + delta, 0), 1)
                    volumeController.setVolume(newLevel)
                    volumeOverlay = newLevel
                    brightnessOverlay = nil
                }
                revealChromeTemporarily()
            }
            .onEnded { _ in
                brightnessDragStart = nil
                volumeDragStart = nil
                scheduleHudHide()
                revealChromeTemporarily()
            }
    }
    #endif
}

private enum PlayerOrientation {
    case portrait
    case landscape

    var toggled: PlayerOrientation {
        self == .portrait ? .landscape : .portrait
    }

    var systemImage: String {
        self == .portrait ? "iphone.landscape" : "iphone"
    }

    var buttonTitle: String {
        self == .portrait ? "Landscape" : "Portrait"
    }

    var accessibilityLabel: String {
        self == .portrait ? "Switch player to landscape" : "Switch player to portrait"
    }

    #if os(iOS)
    var interfaceOrientationMask: UIInterfaceOrientationMask {
        self == .portrait ? .portrait : .landscapeRight
    }
    #endif
}

#if os(iOS)
private enum PlayerAdjustmentSide {
    case brightness
    case volume
}

private enum PlayerDismissalGestureKind {
    case edgePop
    case pullDown
}
#endif

private enum PlayerMatchResolutionState: Equatable {
    case resolving
    case loadingData
    case connected
    case unavailable
    case apiFailed

    var isPending: Bool {
        self == .resolving || self == .loadingData
    }
}

private enum PlayerMatchTextNormalizer {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(from value: String) -> Set<String> {
        let words = normalized(value).split(separator: " ").map(String.init)
        return Set(words.filter { $0.count >= 3 })
    }
}

/// Decides whether a channel is worth a live-score lookup, and in which leagues,
/// from its name, group and current programme. Non-sports channels get no lookups.
private enum PlayerLiveMatchLeagueHint {
    static let leaguePaths = [
        "football/nfl", "football/college-football", "football/cfl", "basketball/nba", "basketball/wnba",
        "hockey/nhl", "baseball/mlb", "soccer/eng.1", "soccer/esp.1", "soccer/ger.1",
        "soccer/ita.1", "soccer/usa.1", "racing/f1"
    ]

    /// Broadcaster and sport words that mark a channel or programme as sports.
    private static let sportsWords = [
        "sport", "sports", "espn", "tsn", "sportsnet", "bein", "dazn", "eurosport", "supersport",
        "fox sports", "nbc sports", "cbs sports", "tnt sports", "sky sports", "bt sport", "bally",
        "nfl", "nba", "wnba", "nhl", "mlb", "mls", "cfl", "ncaa", "f1", "formula 1",
        "football", "soccer", "hockey", "baseball", "basketball",
        "premier league", "la liga", "laliga", "bundesliga", "serie a", "liga mx"
    ]

    /// League keywords too generic to identify a league on their own.
    private static let ambiguousKeywords: Set<String> = ["sunday", "monday night", "thursday night", "football", "soccer"]

    static func leagues(channelName: String, group: String?, programme: EPGProgramme?) -> [League] {
        let allLeagues = leaguePaths.compactMap { path in League.all.first { $0.path == path } }
        let text = padded([channelName, group, programme?.title, programme?.subtitle,
                           programme?.categories.joined(separator: " ")]
            .compactMap { $0 }
            .joined(separator: " "))
        let hasSportsCategory = programme?.categories.contains { $0.localizedCaseInsensitiveContains("sport") } ?? false
        let suggested = allLeagues.filter { league in
            terms(for: league).contains { text.contains(padded($0)) }
        }
        let looksLikeSports = hasSportsCategory || !suggested.isEmpty || sportsWords.contains { text.contains(padded($0)) }
        guard looksLikeSports else { return [] }
        return suggested.isEmpty ? allLeagues : suggested
    }

    private static func terms(for league: League) -> [String] {
        [league.shortName, league.name] + league.keywords.filter { !ambiguousKeywords.contains($0.lowercased()) }
    }

    /// Lowercased, punctuation-free, space-padded text so `contains` matches whole words.
    private static func padded(_ value: String) -> String {
        " " + PlayerMatchTextNormalizer.normalized(value) + " "
    }
}

/// Feeds fantasy games to the live tracker. Lives in its own view so FantasyStore
/// publishes re-render only this, not the whole player.
private struct PlayerFantasyTrackerBridge: View {
    @ObservedObject private var fantasyStore = FantasyStore.shared
    let liveTracker: FantasyLiveTrackerEngine
    let channels: () -> [Channel]

    var body: some View {
        Color.clear
            .task(id: fantasyStore.playerGames.count) {
                liveTracker.processLiveGames(
                    playerGames: fantasyStore.playerGames,
                    matchup: fantasyStore.matchup,
                    channels: channels()
                )
                FantasyDriveTickerEngine.shared.updateDriveData(
                    playerGames: fantasyStore.playerGames,
                    matches: fantasyStore.playerGames.compactMap(\.event)
                )
            }
    }
}

// MARK: - Sports-first Match Player

private enum BannerSport: String {
    case baseball
    case hockey
    case americanFootball
    case soccer
    case basketball
    case golf
    case tennis
    case racing
    case other

    init(league: League?) {
        switch league?.group {
        case .baseball: self = .baseball
        case .hockey: self = .hockey
        case .football: self = .americanFootball
        case .soccer: self = .soccer
        case .basketball: self = .basketball
        case .golf: self = .golf
        case .tennis: self = .tennis
        case .racing: self = .racing
        case .cycling, .wrestling, .esports, .none: self = .other
        }
    }

    var tabs: [SportPlayerTab] {
        switch self {
        case .baseball: return [.game, .plays, .boxScore, .lineups]
        case .hockey: return [.game, .plays, .stats, .lineups]
        case .americanFootball: return [.game, .plays, .stats, .drives]
        case .soccer: return [.match, .events, .stats, .lineups]
        case .basketball: return [.game, .plays, .boxScore, .teamStats]
        default: return [.game, .events, .stats]
        }
    }
}

private enum SportPlayerTab: String, CaseIterable, Identifiable {
    case game = "Game"
    case match = "Match"
    case plays = "Plays"
    case events = "Events"
    case stats = "Stats"
    case boxScore = "Box Score"
    case lineups = "Lineups"
    case drives = "Drives"
    case teamStats = "Team Stats"

    var id: String { rawValue }
}

private struct MatchPlayerScreen<VideoContent: View, ChannelPage: View>: View {
    let channel: Channel
    let canonicalChannel: CanonicalChannel?
    let match: Match?
    let scoreBugMatch: Match?
    let matchResolutionState: PlayerMatchResolutionState
    @Binding var selectedTab: SportPlayerTab
    let isChromeVisible: Bool
    @Binding var isLandscapeGameCentreVisible: Bool
    let streamSummary: String
    let canStartMultiscreen: Bool
    let hasPreviousChannel: Bool
    let hasNextChannel: Bool
    let showsLiveTVControls: Bool
    let hasMultipleSources: Bool
    let isBehindLiveEdge: Bool
    let chrome: PlayerChromeState
    let actions: PlayerChromeActions
    let onGoLive: () -> Void
    let onDismiss: () -> Void
    let onPreviousChannel: () -> Void
    let onNextChannel: () -> Void
    let onGuide: () -> Void
    let onChannels: () -> Void
    let onRecents: () -> Void
    let onMore: () -> Void
    let onSourceSelector: () -> Void
    let onCycleSource: (Int) -> Void
    let onToggleOrientation: () -> Void
    var onPiP: (() -> Void)? = nil
    let orientation: PlayerOrientation
    let videoContent: VideoContent
    /// Shown under the video in portrait when no match is connected (news, movies, entertainment).
    let channelPage: ChannelPage

    init(
        channel: Channel,
        canonicalChannel: CanonicalChannel?,
        match: Match?,
        scoreBugMatch: Match?,
        matchResolutionState: PlayerMatchResolutionState,
        selectedTab: Binding<SportPlayerTab>,
        isChromeVisible: Bool,
        isLandscapeGameCentreVisible: Binding<Bool>,
        streamSummary: String,
        canStartMultiscreen: Bool,
        hasPreviousChannel: Bool,
        hasNextChannel: Bool,
        showsLiveTVControls: Bool,
        hasMultipleSources: Bool,
        isBehindLiveEdge: Bool,
        chrome: PlayerChromeState,
        actions: PlayerChromeActions,
        onGoLive: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onPreviousChannel: @escaping () -> Void,
        onNextChannel: @escaping () -> Void,
        onGuide: @escaping () -> Void,
        onChannels: @escaping () -> Void,
        onRecents: @escaping () -> Void,
        onMore: @escaping () -> Void,
        onSourceSelector: @escaping () -> Void,
        onCycleSource: @escaping (Int) -> Void,
        onToggleOrientation: @escaping () -> Void,
        onPiP: (() -> Void)? = nil,
        orientation: PlayerOrientation,
        @ViewBuilder videoContent: () -> VideoContent,
        @ViewBuilder channelPage: () -> ChannelPage
    ) {
        self.channel = channel
        self.canonicalChannel = canonicalChannel
        self.match = match
        self.scoreBugMatch = scoreBugMatch
        self.matchResolutionState = matchResolutionState
        self._selectedTab = selectedTab
        self.isChromeVisible = isChromeVisible
        self._isLandscapeGameCentreVisible = isLandscapeGameCentreVisible
        self.streamSummary = streamSummary
        self.canStartMultiscreen = canStartMultiscreen
        self.hasPreviousChannel = hasPreviousChannel
        self.hasNextChannel = hasNextChannel
        self.showsLiveTVControls = showsLiveTVControls
        self.hasMultipleSources = hasMultipleSources
        self.isBehindLiveEdge = isBehindLiveEdge
        self.chrome = chrome
        self.actions = actions
        self.onGoLive = onGoLive
        self.onDismiss = onDismiss
        self.onPreviousChannel = onPreviousChannel
        self.onNextChannel = onNextChannel
        self.onGuide = onGuide
        self.onChannels = onChannels
        self.onRecents = onRecents
        self.onMore = onMore
        self.onSourceSelector = onSourceSelector
        self.onCycleSource = onCycleSource
        self.onToggleOrientation = onToggleOrientation
        self.onPiP = onPiP
        self.orientation = orientation
        self.videoContent = videoContent()
        self.channelPage = channelPage()
    }

    private var sport: BannerSport { BannerSport(league: match?.league) }
    private var effectiveTab: SportPlayerTab { sport.tabs.contains(selectedTab) ? selectedTab : sport.tabs.first ?? .game }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            // The video container stays at one structural position in both orientations
            // (first child of the VStack); only its frame changes. Portrait and landscape
            // extras are siblings shown conditionally, so rotating never rebuilds the video.
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    PlayerVideoContainer(
                        channel: channel,
                        match: scoreBugMatch,
                        sport: sport,
                        isChromeVisible: isChromeVisible,
                        streamSummary: streamSummary,
                        orientation: orientation,
                        isLandscape: isLandscape,
                        hasMultipleSources: hasMultipleSources,
                        isBehindLiveEdge: isBehindLiveEdge,
                        chrome: chrome,
                        actions: actions,
                        hasPreviousChannel: hasPreviousChannel,
                        hasNextChannel: hasNextChannel,
                        onPreviousChannel: onPreviousChannel,
                        onNextChannel: onNextChannel,
                        onGoLive: onGoLive,
                        onDismiss: onDismiss,
                        onMore: onMore,
                        onSourceSelector: onSourceSelector,
                        onCycleSource: onCycleSource,
                        onToggleOrientation: onToggleOrientation,
                        onPiP: onPiP,
                        topSafeArea: isLandscape ? max(proxy.safeAreaInsets.top, Theme.Spacing.xs) : proxy.safeAreaInsets.top,
                        horizontalSafeArea: isLandscape ? max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing) : 0,
                        videoContent: { videoContent }
                    )
                    .frame(height: isLandscape ? nil : max(320, proxy.size.height * 0.43))
                    .frame(maxHeight: isLandscape ? .infinity : nil)

                    if !isLandscape {
                        portraitGameCentre
                    }
                }
                .ignoresSafeArea(edges: isLandscape ? .all : .top)

                if isLandscape {
                    landscapeChrome(proxy: proxy)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: sport.rawValue) { _, _ in
            selectedTab = sport.tabs.first ?? .game
        }
    }

    private var portraitGameCentre: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if match != nil {
                    MatchMetadataHeader(match: match, channel: channel)
                    MatchTabs(tabs: sport.tabs, selection: $selectedTab)
                    SportGameCentre(match: match, state: matchResolutionState, sport: sport, selectedTab: effectiveTab)
                } else {
                    // No match (yet, or ever): the guide, channel details and what else is on.
                    // The game centre replaces this only if a match connects.
                    channelPage
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xl)
            .animation(Theme.Motion.smooth, value: match?.id)
        }
        .background(Theme.background)
    }

    /// Landscape-only extras: Live TV shortcuts and the game-information side panel.
    /// Back, previous/next and play/pause live in the shared video chrome.
    private func landscapeChrome(proxy: GeometryProxy) -> some View {
        ZStack(alignment: .trailing) {
            if isChromeVisible {
                VStack {
                    Spacer()
                    HStack(spacing: Theme.Spacing.xs) {
                        Spacer()
                        if showsLiveTVControls {
                            PlayerChromeButton(systemImage: "rectangle.grid.1x2.fill", title: "Guide", accessibilityLabel: "Open guide", action: onGuide)
                            PlayerChromeButton(systemImage: "list.bullet", accessibilityLabel: "Channel list", action: onChannels)
                            PlayerChromeButton(systemImage: "clock.arrow.circlepath", accessibilityLabel: "Recent channels", action: onRecents)
                        }
                        PlayerChromeButton(
                            systemImage: isLandscapeGameCentreVisible ? "sidebar.right" : "chart.bar.xaxis",
                            accessibilityLabel: "Toggle game information"
                        ) {
                            withAnimation(Theme.Motion.snappy) { isLandscapeGameCentreVisible.toggle() }
                        }
                    }
                    // Sits just above the bottom control bar.
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, Theme.Spacing.sm) + 72)
                    .padding(.trailing, max(proxy.safeAreaInsets.trailing, Theme.Spacing.md))
                }
                .transition(.opacity)
            }

            if isLandscapeGameCentreVisible {
                LandscapeGameCentrePanel(match: match, sport: sport)
                    .frame(maxWidth: 310)
                    .padding(.trailing, Theme.Spacing.sm)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

/// Values the video chrome renders, gathered by `PlayerView`.
struct PlayerChromeState {
    var isPlaying: Bool
    var isMuted: Bool
    var aspect: PlayerAspectMode
    var logoURL: URL?
    /// Current programme (Live TV) or match name, under the channel name.
    var subtitle: String?
    /// Current EPG programme, for the progress bar.
    var programme: EPGProgramme?
}

struct PlayerChromeActions {
    var onPlayPause: () -> Void
    var onToggleMute: () -> Void
    var onCycleAspect: () -> Void
}

private struct PlayerVideoContainer<VideoContent: View>: View {
    let channel: Channel
    let match: Match?
    let sport: BannerSport
    let isChromeVisible: Bool
    let streamSummary: String
    let orientation: PlayerOrientation
    let isLandscape: Bool
    let hasMultipleSources: Bool
    let isBehindLiveEdge: Bool
    let chrome: PlayerChromeState
    let actions: PlayerChromeActions
    let hasPreviousChannel: Bool
    let hasNextChannel: Bool
    let onPreviousChannel: () -> Void
    let onNextChannel: () -> Void
    let onGoLive: () -> Void
    let onDismiss: () -> Void
    let onMore: () -> Void
    let onSourceSelector: () -> Void
    let onCycleSource: (Int) -> Void
    let onToggleOrientation: () -> Void
    var onPiP: (() -> Void)? = nil
    let topSafeArea: CGFloat
    let horizontalSafeArea: CGFloat
    let videoContent: VideoContent

    init(
        channel: Channel,
        match: Match?,
        sport: BannerSport,
        isChromeVisible: Bool,
        streamSummary: String,
        orientation: PlayerOrientation,
        isLandscape: Bool,
        hasMultipleSources: Bool,
        isBehindLiveEdge: Bool,
        chrome: PlayerChromeState,
        actions: PlayerChromeActions,
        hasPreviousChannel: Bool,
        hasNextChannel: Bool,
        onPreviousChannel: @escaping () -> Void,
        onNextChannel: @escaping () -> Void,
        onGoLive: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onMore: @escaping () -> Void,
        onSourceSelector: @escaping () -> Void,
        onCycleSource: @escaping (Int) -> Void,
        onToggleOrientation: @escaping () -> Void,
        onPiP: (() -> Void)? = nil,
        topSafeArea: CGFloat = 0,
        horizontalSafeArea: CGFloat = 0,
        @ViewBuilder videoContent: () -> VideoContent
    ) {
        self.channel = channel
        self.match = match
        self.sport = sport
        self.isChromeVisible = isChromeVisible
        self.streamSummary = streamSummary
        self.orientation = orientation
        self.isLandscape = isLandscape
        self.hasMultipleSources = hasMultipleSources
        self.isBehindLiveEdge = isBehindLiveEdge
        self.chrome = chrome
        self.actions = actions
        self.hasPreviousChannel = hasPreviousChannel
        self.hasNextChannel = hasNextChannel
        self.onPreviousChannel = onPreviousChannel
        self.onNextChannel = onNextChannel
        self.onGoLive = onGoLive
        self.onDismiss = onDismiss
        self.onMore = onMore
        self.onSourceSelector = onSourceSelector
        self.onCycleSource = onCycleSource
        self.onToggleOrientation = onToggleOrientation
        self.onPiP = onPiP
        self.topSafeArea = topSafeArea
        self.horizontalSafeArea = horizontalSafeArea
        self.videoContent = videoContent()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                videoContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                if let match, !isChromeVisible {
                    VStack {
                        HStack {
                            Spacer()
                            LiveScoreBug(match: match, sport: sport)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, max(horizontalSafeArea, Theme.Spacing.md))
                    .padding(.top, max(topSafeArea, Theme.Spacing.md))
                    .allowsHitTesting(false)
                }

                if isChromeVisible {
                    // Scrims keep white controls legible over bright video.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140)
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 160)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)

                    VStack(spacing: 0) {
                        PlayerTopOverlay(
                            title: channel.name,
                            subtitle: match?.shortName ?? chrome.subtitle,
                            logoURL: chrome.logoURL,
                            orientation: orientation,
                            onDismiss: onDismiss,
                            onMore: onMore,
                            onToggleOrientation: onToggleOrientation,
                            onPiP: onPiP
                        )
                        .padding(.horizontal, Theme.Spacing.sm + horizontalSafeArea)
                        .padding(.top, max(topSafeArea, Theme.Spacing.xs) + Theme.Spacing.xs)

                        Spacer()

                        PlayerCenterControls(
                            isPlaying: chrome.isPlaying,
                            showsChannelArrows: isLandscape,
                            hasPreviousChannel: hasPreviousChannel,
                            hasNextChannel: hasNextChannel,
                            onPlayPause: actions.onPlayPause,
                            onPreviousChannel: onPreviousChannel,
                            onNextChannel: onNextChannel
                        )

                        Spacer()

                        PlayerBottomOverlay(
                            streamSummary: streamSummary,
                            programme: chrome.programme,
                            hasMultipleSources: hasMultipleSources,
                            isBehindLiveEdge: isBehindLiveEdge,
                            isMuted: chrome.isMuted,
                            aspect: chrome.aspect,
                            onGoLive: onGoLive,
                            onSourceSelector: onSourceSelector,
                            onCycleSource: onCycleSource,
                            onToggleMute: actions.onToggleMute,
                            onCycleAspect: actions.onCycleAspect
                        )
                        .padding(.horizontal, Theme.Spacing.sm + horizontalSafeArea)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, Theme.Spacing.xs) + Theme.Spacing.xxs)
                    }
                    .transition(.opacity)
                }
            }
        }
        .background(Color.black)
    }
}

private struct PlayerTopOverlay: View {
    let title: String
    let subtitle: String?
    let logoURL: URL?
    let orientation: PlayerOrientation
    let onDismiss: () -> Void
    let onMore: () -> Void
    let onToggleOrientation: () -> Void
    var onPiP: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            PlayerChromeButton(systemImage: "chevron.backward", accessibilityLabel: "Back", action: onDismiss)

            ChannelLogo(url: logoURL, name: title, size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            #if os(iOS)
            AirPlayButton()
                .frame(width: 44, height: 44)
                .playerChromeBackground(in: Capsule())
                .accessibilityLabel("AirPlay")

            if let onPiP, AVPictureInPictureController.isPictureInPictureSupported() {
                PlayerChromeButton(systemImage: "pip.enter", accessibilityLabel: "Picture in Picture", action: onPiP)
            }
            #endif

            PlayerChromeButton(systemImage: orientation.systemImage, accessibilityLabel: orientation.accessibilityLabel, action: onToggleOrientation)
            PlayerChromeButton(systemImage: "ellipsis", accessibilityLabel: "Options", action: onMore)
        }
    }
}

/// Large play/pause, with previous/next channel either side in landscape.
private struct PlayerCenterControls: View {
    let isPlaying: Bool
    let showsChannelArrows: Bool
    let hasPreviousChannel: Bool
    let hasNextChannel: Bool
    let onPlayPause: () -> Void
    let onPreviousChannel: () -> Void
    let onNextChannel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            if showsChannelArrows {
                arrow("chevron.left", label: "Previous channel", enabled: hasPreviousChannel, action: onPreviousChannel)
            }
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .playerChromeBackground(in: Circle())
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            if showsChannelArrows {
                arrow("chevron.right", label: "Next channel", enabled: hasNextChannel, action: onNextChannel)
            }
        }
    }

    private func arrow(_ systemImage: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        PlayerChromeButton(systemImage: systemImage, accessibilityLabel: label, action: action)
            .opacity(enabled ? 1 : 0.35)
            .disabled(!enabled)
    }
}

private struct PlayerBottomOverlay: View {
    let streamSummary: String
    let programme: EPGProgramme?
    let hasMultipleSources: Bool
    let isBehindLiveEdge: Bool
    let isMuted: Bool
    let aspect: PlayerAspectMode
    let onGoLive: () -> Void
    let onSourceSelector: () -> Void
    let onCycleSource: (Int) -> Void
    let onToggleMute: () -> Void
    let onCycleAspect: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let programme {
                ProgrammeProgressBar(programme: programme)
            }
            HStack(spacing: Theme.Spacing.xs) {
                livePill

                if hasMultipleSources {
                    Button(action: onSourceSelector) {
                        HStack(spacing: Theme.Spacing.xxs) {
                            Text(streamSummary).lineLimit(1)
                            Image(systemName: "chevron.down")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .frame(minHeight: 44)
                        .playerChromeBackground(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose stream source, \(streamSummary)")
                    .accessibilityHint("Swipe left or right on it to switch source")
                    #if os(iOS)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 18)
                            .onEnded { value in
                                guard abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 34 else { return }
                                onCycleSource(value.translation.width < 0 ? 1 : -1)
                            }
                    )
                    #endif
                }

                Spacer(minLength: Theme.Spacing.xxs)

                PlayerChromeButton(systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   accessibilityLabel: isMuted ? "Unmute" : "Mute",
                                   action: onToggleMute)
                PlayerChromeButton(systemImage: aspect.systemImage,
                                   accessibilityLabel: "Aspect: \(aspect.title)",
                                   action: onCycleAspect)
            }
        }
    }

    @ViewBuilder
    private var livePill: some View {
        if isBehindLiveEdge {
            // Behind the live point (after a stall or a long pause): tap to catch up.
            Button(action: onGoLive) {
                Label("Go Live", systemImage: "forward.end.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .frame(minHeight: 44)
                    .playerChromeBackground(in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to live")
        } else {
            LiveBadge()
        }
    }
}

/// Current programme's elapsed time, with start and end times.
private struct ProgrammeProgressBar: View {
    let programme: EPGProgramme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: Theme.Spacing.xs) {
                Text(programme.start, format: .dateTime.hour().minute())
                ProgressView(value: programme.progress(at: context.date))
                    .progressViewStyle(.linear)
                    .tint(Theme.live)
                Text(programme.end, format: .dateTime.hour().minute())
            }
            .font(Theme.Typography.captionDigits)
            .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(programme.title), \(Int(programme.progress() * 100)) percent through")
    }
}

private struct LiveScoreBug: View {
    @EnvironmentObject private var prefs: PreferencesStore
    let match: Match
    let sport: BannerSport

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                scoreTeam(match.away, alignment: .leading)
                Text(match.away.score ?? "–")
                    .font(.title3.weight(.bold).monospacedDigit())
                Text("–")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.44))
                Text(match.home.score ?? "–")
                    .font(.title3.weight(.bold).monospacedDigit())
                scoreTeam(match.home, alignment: .trailing)
            }
            .foregroundStyle(.white)

            HStack(spacing: 8) {
                Text(scoreState)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                if match.state == .live {
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        if prefs.sportsScoreDelaySeconds == 0 {
                            PulsingDot(color: Theme.live)
                            Text("LIVE")
                        } else {
                            Text("Delayed \(prefs.sportsScoreDelaySeconds)s")
                        }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.live)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(match.away.abbreviation) \(match.away.score ?? "no score"), \(match.home.abbreviation) \(match.home.score ?? "no score"), \(scoreState)")
    }

    private func scoreTeam(_ team: TeamSide, alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 6) {
            if alignment == .trailing {
                Text(team.abbreviation)
            }
            TeamLogo(url: team.logoURL, size: 22)
            if alignment == .leading {
                Text(team.abbreviation)
            }
        }
        .font(.subheadline.weight(.bold))
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .lineLimit(1)
    }

    private var scoreState: String {
        let detail = match.statusDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return match.state.label.uppercased() }
        switch sport {
        case .baseball:
            let situation = match.liveContext.baseball
            let count = [situation?.balls, situation?.strikes].compactMap { $0 }.count == 2 ? "\(situation?.balls ?? 0)-\(situation?.strikes ?? 0)" : nil
            return [situation?.inning, count.map { "Count \($0)" }, situation?.outs.map { "\($0) Out\($0 == 1 ? "" : "s")" }].compactMap { $0 }.first ?? detail.uppercased()
        case .hockey:
            let situation = match.liveContext.hockey
            return [situation?.period, situation?.clock, situation?.powerPlayTeamAbbreviation.map { "\($0) PP" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? detail.uppercased()
        case .americanFootball:
            let situation = match.liveContext.football
            let downDistance = situation.flatMap { footballDownDistance($0) }
            return [situation?.quarter, situation?.clock, downDistance, situation?.ballPosition].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? detail.uppercased()
        case .soccer:
            return (match.liveContext.soccer?.minute ?? detail).replacingOccurrences(of: "Half", with: "H")
        case .basketball:
            let situation = match.liveContext.basketball
            return [situation?.quarter, situation?.clock].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? detail.uppercased()
        default: return detail
        }
    }

    private func footballDownDistance(_ situation: FootballSituation) -> String? {
        guard let down = situation.down, let distance = situation.distance else { return nil }
        let ordinal = ["1ST", "2ND", "3RD", "4TH"].indices.contains(down - 1) ? ["1ST", "2ND", "3RD", "4TH"][down - 1] : "\(down)TH"
        return "\(ordinal) & \(distance)"
    }
}

private struct MatchMetadataHeader: View {
    let match: Match?
    let channel: Channel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(match.map { "\($0.league.shortName.uppercased()) · \($0.state.label.uppercased())" } ?? "LIVE STREAM")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(match?.state == .live ? Theme.live : Theme.textSecondary)
                if match?.state == .live {
                    PulsingDot(color: Theme.live)
                }
            }

            Text(match?.name ?? channel.name)
                .font(match == nil ? .headline.weight(.bold) : .title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Text(match == nil ? (channel.group ?? channel.playlistName) : "Watching on \(channel.name)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MatchTabs: View {
    let tabs: [SportPlayerTab]
    @Binding var selection: SportPlayerTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    Button {
                        withAnimation(Theme.Motion.snappy) { selection = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(selection == tab ? .white : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(selection == tab ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                            .overlay(Capsule().strokeBorder(selection == tab ? Color.white.opacity(0.12) : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Shared sports presentation for the remote player; reuses the phone's game-centre views.
struct PlayerSportsPanel: View {
    let match: Match
    let broadcasts: [RankedSource]
    let onSelectBroadcast: (Channel) -> Void
    let onClose: () -> Void
    @State private var selectedTab: SportPlayerTab = .game
    @State private var showsBroadcasts = false
    @State private var pendingBroadcast: Channel?
    @State private var broadcastRequest = 0
    @State private var broadcastError = false
    @EnvironmentObject private var streamStore: StreamAvailabilityStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var epgRepository: EPGRepository

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text(match.shortName).font(.headline)
                    Spacer()
                    Button("Close", systemImage: "xmark", action: onClose)
                }
                Toggle("Alternative broadcasts", isOn: $showsBroadcasts)
                if showsBroadcasts {
                    let confirmed = broadcasts.filter(\.isConfirmed)
                    if confirmed.isEmpty {
                        Text("No verified alternative broadcasts available.").foregroundStyle(Theme.textSecondary)
                    }
                    if broadcastError {
                        Text("No confirmed stream found.").foregroundStyle(Theme.textSecondary)
                        Button("Retry") {
                            broadcastError = false
                            broadcastRequest &+= 1
                        }
                    }
                    ForEach(confirmed) { source in
                        Button {
                            broadcastError = false
                            pendingBroadcast = source.channel
                            broadcastRequest &+= 1
                        } label: {
                            HStack {
                                ChannelLogo(url: source.channel.logoURL, name: source.channel.name, size: 40)
                                Text(source.channel.name)
                            }
                        }
                    }
                } else {
                    MatchTabs(tabs: BannerSport(league: match.league).tabs, selection: $selectedTab)
                    SportGameCentre(match: match, state: .connected, sport: BannerSport(league: match.league), selectedTab: selectedTab)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .task(id: broadcastRequest) {
            guard let pendingBroadcast else { return }
            let confirmed = await streamStore.confirmsCurrentBroadcast(match: match, channel: pendingBroadcast,
                channels: playlistStore.allChannels, epgRepository: epgRepository)
            guard !Task.isCancelled else { return }
            if confirmed { onSelectBroadcast(pendingBroadcast) }
            else { broadcastError = true }
        }
    }
}

private struct SportGameCentre: View {
    let match: Match?
    let state: PlayerMatchResolutionState
    let sport: BannerSport
    let selectedTab: SportPlayerTab

    var body: some View {
        VStack(spacing: 12) {
            if let match {
                switch selectedTab {
                case .game, .match:
                    sportGameContent
                case .stats, .teamStats:
                    TeamStatsPlaceholder(match: match, sport: sport)
                case .plays, .events:
                    EventsPlaceholder(match: match, state: state, sport: sport)
                case .boxScore:
                    BoxScorePlaceholder(match: match, sport: sport)
                case .lineups:
                    LineupsPlaceholder(match: match, sport: sport)
                case .drives:
                    DrivesPlaceholder(match: match)
                }
            } else {
                MatchUnavailableCard(state: state)
            }
        }
    }

    @ViewBuilder private var sportGameContent: some View {
        switch sport {
        case .baseball: BaseballGameCentre(match: match)
        case .hockey: HockeyGameCentre(match: match)
        case .americanFootball: FootballGameCentre(match: match)
        case .soccer: SoccerGameCentre(match: match)
        case .basketball: BasketballGameCentre(match: match)
        default: GenericGameCentre(match: match)
        }
    }
}

/// Portrait page for channels without a connected match: Now/Next from the guide
/// (with a reminder for Next), channel details, and more channels in the same group.
private struct PlayerChannelInfoPage: View {
    let channel: Channel
    let canonicalChannel: CanonicalChannel?
    let isResolvingMatch: Bool
    let relatedChannels: [Channel]
    let onSelectChannel: (Channel) -> Void

    @Environment(\.playerStores) private var stores
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var reminders: ProgrammeReminderStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                nowNextCard(at: context.date)
            }
            channelInfoRow
            if !relatedChannels.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    SectionHeader(title: "More in \(channel.group ?? channel.playlistName)")
                    ForEach(relatedChannels) { related in
                        Button { onSelectChannel(related) } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                ChannelLogo(url: related.logoURL, name: related.name, size: 44)
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs / 2) {
                                    Text(related.name)
                                        .font(Theme.Typography.headline)
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    if let programme = currentProgramme(for: related.id, at: Date()) {
                                        Text(programme.title)
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "play.circle")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Switches to this channel")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nowNextCard(at date: Date) -> some View {
        let now = currentProgramme(for: channel.id, at: date)
        let next = nextProgramme(after: now?.end ?? date)
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("On Now").overlineStyle().foregroundStyle(Theme.live)
                    Spacer()
                    if isResolvingMatch {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                            .accessibilityLabel("Checking for a live match")
                    }
                }
                if let now {
                    Text(now.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(timeRange(now)).font(Theme.Typography.captionDigits)
                        ProgressView(value: now.progress(at: date)).tint(Theme.live)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    if let description = now.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(4)
                    }
                } else {
                    Text("No guide information for this channel.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let next {
                    Divider().overlay(Theme.hairline)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Up Next").overlineStyle().foregroundStyle(Theme.textSecondary)
                            Text(next.title)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(timeRange(next))
                                .font(Theme.Typography.captionDigits)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if let canonicalChannel {
                            reminderButton(for: next, channel: canonicalChannel)
                        }
                    }
                }
            }
        }
    }

    private func reminderButton(for programme: EPGProgramme, channel canonical: CanonicalChannel) -> some View {
        let isSet = reminders.hasReminder(for: programme)
        return Button {
            if isSet, let id = reminders.reminderID(for: programme) {
                reminders.removeReminder(id: id)
            } else {
                Task { _ = await reminders.addReminder(for: programme, channel: canonical) }
            }
        } label: {
            Label(isSet ? "Reminder Set" : "Remind Me", systemImage: isSet ? "bell.fill" : "bell")
                .font(Theme.Typography.caption)
        }
        .buttonStyle(SecondaryButtonStyle())
        .fixedSize()
    }

    private var channelInfoRow: some View {
        Card(padding: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                ChannelLogo(url: channel.logoURL, name: channel.name, size: 48)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs / 2) {
                    Text(channel.name)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text([channel.group, channel.playlistName].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                let isFavorite = watchStore.isFavorite(channel)
                Button {
                    watchStore.toggleFavorite(channel)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? Theme.live : Theme.textSecondary)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(isFavorite ? "Remove from favourites" : "Add to favourites")
            }
        }
    }

    private func currentProgramme(for channelID: String, at date: Date) -> EPGProgramme? {
        guard let epg = stores?.epgRepository else { return nil }
        let canonicalID = channelID == channel.id
            ? (canonicalChannel?.id ?? epg.canonicalChannel(forProviderChannelID: channelID, playlistID: channel.playlistID)?.id)
            : nil
        return canonicalID.flatMap { epg.currentProgramme(for: $0, at: date) }
    }

    private func nextProgramme(after date: Date) -> EPGProgramme? {
        guard let epg = stores?.epgRepository,
              let canonicalID = canonicalChannel?.id ?? epg.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID)?.id else { return nil }
        return epg.nextProgramme(for: canonicalID, after: date)
    }

    private func timeRange(_ programme: EPGProgramme) -> String {
        let format = Date.FormatStyle.dateTime.hour().minute()
        return "\(programme.start.formatted(format)) – \(programme.end.formatted(format))"
    }
}

private struct MatchUnavailableCard: View {
    let state: PlayerMatchResolutionState

    var body: some View {
        GameCentreCard(title: title) {
            HStack(alignment: .top, spacing: 12) {
                if state.isPending {
                    ProgressView()
                        .tint(Theme.accent)
                        .controlSize(.small)
                } else {
                    Image(systemName: "link.badge.plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(message)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var title: String {
        switch state {
        case .resolving: return "Resolving Match"
        case .loadingData: return "Loading Match Data"
        case .connected: return "Match Centre"
        case .unavailable: return "Match Unavailable"
        case .apiFailed: return "Match Data Error"
        }
    }

    private var message: String {
        switch state {
        case .resolving: return "Identifying the event from this channel and guide data."
        case .loadingData: return "Loading live game state."
        case .connected: return "Match data unavailable for this broadcast."
        case .unavailable: return "Match data unavailable for this broadcast."
        case .apiFailed: return "Live sports data failed to update. Video playback is unaffected."
        }
    }
}

private struct BaseballGameCentre: View {
    let match: Match?
    var body: some View {
        GameCentreCard(title: "Current Game") {
            ScoreboardRow(match: match, stateLabel: match?.statusDetail)
            Divider().overlay(Theme.hairline)
            if let situation = match?.liveContext.baseball {
                BaseballBasesView(situation: situation)
            }
            SituationGrid(items: [
                ("Inning", match?.liveContext.baseball?.inning ?? (match?.state == .live ? match?.statusDetail : nil)),
                ("Count", baseballCount),
                ("Outs", match?.liveContext.baseball?.outs.map(String.init)),
                ("Batter", match?.liveContext.baseball?.batterName),
                ("Pitcher", match?.liveContext.baseball?.pitcherName)
            ])
        }
        EventsPlaceholder(match: match, sport: .baseball)
    }

    private var baseballCount: String? {
        guard let balls = match?.liveContext.baseball?.balls, let strikes = match?.liveContext.baseball?.strikes else { return nil }
        return "\(balls)-\(strikes)"
    }
}

private struct HockeyGameCentre: View {
    let match: Match?
    var body: some View {
        GameCentreCard(title: "Game State") {
            ScoreboardRow(match: match, stateLabel: match?.statusDetail)
            Divider().overlay(Theme.hairline)
            SituationGrid(items: [
                ("Period", match?.liveContext.hockey?.period ?? match?.liveContext.period?.displayName ?? (match?.state == .live ? match?.statusDetail : nil)),
                ("Clock", match?.liveContext.hockey?.clock ?? match?.liveContext.clock?.displayValue),
                ("Power Play", match?.liveContext.hockey?.powerPlayTeamAbbreviation),
                ("Strength", match?.liveContext.hockey?.strengthState)
            ])
        }
        TeamStatsPlaceholder(match: match, sport: .hockey)
    }
}

private struct FootballGameCentre: View {
    let match: Match?
    var body: some View {
        GameCentreCard(title: "Current Drive") {
            ScoreboardRow(match: match, stateLabel: match?.statusDetail)
            Divider().overlay(Theme.hairline)
            SituationGrid(items: [
                ("Quarter", match?.liveContext.football?.quarter ?? match?.liveContext.period?.displayName),
                ("Clock", match?.liveContext.football?.clock ?? match?.liveContext.clock?.displayValue),
                ("Down", downDistance),
                ("Ball", match?.liveContext.football?.ballPosition),
                ("Possession", match?.liveContext.football?.possessionTeamAbbreviation)
            ])
        }
        TeamStatsPlaceholder(match: match, sport: .americanFootball)
    }

    private var downDistance: String? {
        guard let down = match?.liveContext.football?.down, let distance = match?.liveContext.football?.distance else { return nil }
        return "\(down) & \(distance)"
    }
}

private struct SoccerGameCentre: View {
    let match: Match?
    var body: some View {
        GameCentreCard(title: match?.league.name.uppercased() ?? "Match") {
            ScoreboardRow(match: match, stateLabel: match?.statusDetail)
        }
        TeamStatsPlaceholder(match: match, sport: .soccer)
    }
}

private struct BasketballGameCentre: View {
    let match: Match?
    var body: some View {
        GameCentreCard(title: "Game Leaders") {
            ScoreboardRow(match: match, stateLabel: match?.statusDetail)
            Divider().overlay(Theme.hairline)
            if let leaders = match?.liveContext.leaders, !leaders.isEmpty {
                ForEach(leaders.prefix(3)) { leader in
                    LeaderSummaryRow(leader: leader)
                }
            } else {
                SituationGrid(items: [
                    ("Quarter", match?.liveContext.basketball?.quarter ?? (match?.state == .live ? match?.statusDetail : nil)),
                    ("Clock", match?.liveContext.basketball?.clock ?? match?.liveContext.clock?.displayValue)
                ])
            }
        }
        TeamStatsPlaceholder(match: match, sport: .basketball)
    }
}

private struct GenericGameCentre: View {
    let match: Match?
    var body: some View {
        GameCentreCard(title: "Live") {
            ScoreboardRow(match: match, stateLabel: match?.statusDetail)
        }
    }
}

private struct GameCentreCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct ScoreboardRow: View {
    let match: Match?
    let stateLabel: String?

    var body: some View {
        HStack(spacing: 14) {
            team(match?.away, alignment: .leading)
            VStack(spacing: 4) {
                Text(scoreText)
                    .font(.system(.title, design: .rounded, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if let stateLabel, !stateLabel.isEmpty {
                    Text(stateLabel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(match?.state == .live ? Theme.live : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            team(match?.home, alignment: .trailing)
        }
    }

    private var scoreText: String {
        guard let match else { return "0 - 0" }
        return "\(match.away.score ?? "0") - \(match.home.score ?? "0")"
    }

    private func team(_ side: TeamSide?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            TeamLogo(url: side?.logoURL, size: 34)
            Text(side?.abbreviation ?? "TBD")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct SituationGrid: View {
    let items: [(String, String?)]
    private var visibleItems: [(String, String)] {
        items.compactMap { label, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (label, value)
        }
    }

    var body: some View {
        if !visibleItems.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(visibleItems, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.0)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(.uppercase)
                        Text(item.1)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }
            }
        }
    }
}

private struct TeamStatsPlaceholder: View {
    let match: Match?
    let sport: BannerSport

    var body: some View {
        GameCentreCard(title: statsTitle) {
            if let teamStats = match?.liveContext.teamStats, !teamStats.isEmpty {
                VStack(spacing: 10) {
                    ForEach(statLabels, id: \.self) { label in
                        if let row = comparisonRow(label: label, teamStats: teamStats) {
                            HStack {
                                Text(row.away)
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 54, alignment: .leading)
                                Text(label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                Text(row.home)
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 54, alignment: .trailing)
                            }
                        }
                    }
                }
            } else {
                Text("Team stats will appear here when the provider exposes them.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var statsTitle: String { sport == .soccer ? "Match Stats" : "Team Stats" }
    private var statLabels: [String] {
        switch sport {
        case .baseball: return ["Hits", "Errors", "Runners", "Bullpen"]
        case .hockey: return ["Shots", "Faceoff %", "Power Play", "Hits"]
        case .americanFootball: return ["Total Yards", "Passing", "Rushing", "Turnovers"]
        case .soccer: return ["Possession", "Shots", "Shots on Target", "Corners"]
        case .basketball: return ["FG", "3PT", "Rebounds", "Assists"]
        default: return ["Live stats"]
        }
    }

    private func comparisonRow(label: String, teamStats: [MatchTeamStats]) -> (away: String, home: String)? {
        let normalized = label.lowercased()
        func value(for side: MatchTeamSide) -> String? {
            teamStats.first(where: { $0.side == side })?.stats.first {
                $0.displayName.lowercased() == normalized || $0.key.lowercased().contains(normalized.replacingOccurrences(of: " ", with: "_"))
            }?.value
        }
        guard let away = value(for: .away), let home = value(for: .home) else { return nil }
        return (away, home)
    }
}

private struct EventsPlaceholder: View {
    let match: Match?
    var state: PlayerMatchResolutionState = .connected
    let sport: BannerSport

    var body: some View {
        GameCentreCard(title: sport == .soccer ? "Recent Events" : "Recent") {
            if let plays = match?.liveContext.playByPlay, !plays.isEmpty {
                VStack(spacing: 0) {
                    ForEach(plays.suffix(8).reversed()) { play in
                        PlayTimelineRow(play: play)
                        if play.id != plays.suffix(8).first?.id {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            } else if let match {
                Text(match.state == .live ? "Live event feed will appear here as provider data arrives." : match.statusDetail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Match data is still loading.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct BoxScorePlaceholder: View {
    let match: Match?
    let sport: BannerSport
    var body: some View {
        GameCentreCard(title: sport == .basketball ? "Box Score" : "Line Score") {
            if let boxScore = match?.liveContext.boxScore, !boxScore.playerStats.isEmpty {
                VStack(spacing: 8) {
                    ForEach(boxScore.playerStats.prefix(8)) { player in
                        HStack {
                            Text(player.displayName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(player.stats.prefix(3).map { "\($0.displayName) \($0.value)" }.joined(separator: " · "))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                ScoreboardRow(match: match, stateLabel: match?.statusDetail)
            }
        }
    }
}

private struct LineupsPlaceholder: View {
    let match: Match?
    let sport: BannerSport
    var body: some View {
        GameCentreCard(title: sport == .hockey ? "Lineups" : "Lineups") {
            if let formations = match?.liveContext.formations, !formations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(formations) { formation in
                        Text([formation.teamAbbreviation, formation.formationName].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        ForEach(formation.groups) { group in
                            Text(group.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(group.players.map(\.displayName).joined(separator: "  "))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            } else {
                Text(lineupCopy)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var lineupCopy: String {
        switch sport {
        case .hockey: return "Forward lines, defensive pairings, and goalies will render here when lineup groups are available."
        case .soccer: return "Formation view will render here when provider formation data is available."
        default: return "Team lineups will render here when provider roster data is available."
        }
    }
}

private struct DrivesPlaceholder: View {
    let match: Match?
    var body: some View {
        GameCentreCard(title: "Drives") {
            if let drives = match?.liveContext.drives, !drives.isEmpty {
                VStack(spacing: 10) {
                    ForEach(drives) { drive in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(drive.teamAbbreviation ?? "Drive")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                if drive.isCurrent {
                                    Text("LIVE")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Theme.live)
                                }
                                Spacer()
                                if let result = drive.result {
                                    Text(result)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            if let summary = drive.summary {
                                Text(summary)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(10)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    }
                }
            } else {
                Text(match?.state == .live ? "Current and completed drives will appear here when play-by-play is available." : "Drive chart unavailable before kickoff.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct LandscapeGameCentrePanel: View {
    let match: Match?
    let sport: BannerSport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(panelTitle)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
            if let match {
                ScoreboardRow(match: match, stateLabel: match.statusDetail)
                Divider().overlay(Theme.hairline)
                compactSituation
            } else {
                Text("Match data unavailable for this broadcast.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }

    private var panelTitle: String {
        switch sport {
        case .americanFootball: return "Drive"
        case .soccer: return "Match"
        default: return "Game"
        }
    }

    @ViewBuilder private var compactSituation: some View {
        switch sport {
        case .baseball:
            SituationGrid(items: [("Inning", match?.statusDetail), ("Count", nil), ("Outs", nil)])
        case .hockey:
            SituationGrid(items: [("Clock", match?.statusDetail), ("Shots", nil), ("Power Play", nil)])
        case .americanFootball:
            let football = match?.liveContext.football
            SituationGrid(items: [
                ("Clock", football?.clock ?? match?.liveContext.clock?.displayValue ?? match?.statusDetail),
                ("Down", football.flatMap { footballDownDistance($0) }),
                ("Ball", football?.ballPosition),
                ("Possession", football?.possessionTeamAbbreviation)
            ])
        case .soccer:
            SituationGrid(items: [("Minute", match?.statusDetail), ("Possession", nil), ("Shots", nil)])
        case .basketball:
            SituationGrid(items: [("Clock", match?.statusDetail), ("FG", nil), ("Last", nil)])
        default:
            SituationGrid(items: [("Status", match?.statusDetail)])
        }
    }

    private func footballDownDistance(_ situation: FootballSituation) -> String? {
        guard let down = situation.down, let distance = situation.distance else { return nil }
        let ordinal = ["1ST", "2ND", "3RD", "4TH"].indices.contains(down - 1) ? ["1ST", "2ND", "3RD", "4TH"][down - 1] : "\(down)TH"
        return "\(ordinal) & \(distance)"
    }
}

private struct BaseballBasesView: View {
    let situation: BaseballSituation

    var body: some View {
        HStack(spacing: 18) {
            base(isOccupied: situation.runnerOnThird)
            VStack(spacing: 5) {
                base(isOccupied: situation.runnerOnSecond)
                base(isOccupied: situation.runnerOnFirst)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func base(isOccupied: Bool?) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill((isOccupied == true ? Theme.live : Theme.surfaceElevated).opacity(isOccupied == nil ? 0.35 : 1))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(45))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18))
                    .rotationEffect(.degrees(45))
            )
    }
}

private struct LeaderSummaryRow: View {
    let leader: MatchLeader

    var body: some View {
        if let first = leader.players.first {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(leader.displayName)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                    Text(first.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Text(first.stats.first?.value ?? "")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

private struct PlayTimelineRow: View {
    let play: MatchPlay

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(play.clock?.displayValue ?? play.period?.displayName ?? "")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(play.isScoringPlay ? Theme.live : Theme.textTertiary)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(play.text)
                    .font(.subheadline.weight(play.isScoringPlay ? .heavy : .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let score = scoreText {
                    Text(score)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
    }

    private var scoreText: String? {
        guard let awayScore = play.awayScore, let homeScore = play.homeScore else { return nil }
        return "\(awayScore)-\(homeScore)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private struct StreamFailurePanel: View {
    let message: String
    let tryAgain: () -> Void
    /// Nil when there is no other source to choose.
    let chooseAnother: (() -> Void)?
    let switchToAuto: () -> Void
    let returnToGuide: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Theme.live)
            Text(message)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Try Again", action: tryAgain)
                if let chooseAnother {
                    Button("Choose Another Broadcast", action: chooseAnother)
                    Button("Auto", action: switchToAuto)
                }
            }
            .font(.subheadline.weight(.bold))
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Button("Return to Guide", action: returnToGuide)
                .foregroundStyle(.white)
        }
        .padding(18)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
    }
}

#if os(iOS)
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

private struct PlayerMultiscreenSession: Identifiable {
    let id = UUID()
    let channels: [Channel]
    var savedLayout: String? = nil
    var audioChannelID: String? = nil
}

/// Layout style for MultiScreen player.
private enum MultiScreenLayout: String, CaseIterable, Identifiable {
    case twoVertical
    case twoHorizontal
    case pipInset
    case three
    case four

    var id: String { rawValue }

    var capacity: Int {
        switch self {
        case .twoVertical, .twoHorizontal, .pipInset:
            return 2
        case .three:
            return 3
        case .four:
            return 4
        }
    }

    var title: String {
        switch self {
        case .twoVertical:
            return "Up/down"
        case .twoHorizontal:
            return "Left/right"
        case .pipInset:
            return "Picture in Picture"
        case .three:
            return "3-up"
        case .four:
            return "4-up"
        }
    }

    var systemImage: String {
        switch self {
        case .twoVertical:
            return "rectangle.split.2x1"
        case .twoHorizontal:
            return "rectangle.split.1x2"
        case .pipInset:
            return "rectangle.inset.filled"
        case .three:
            return "rectangle.split.1x2"
        case .four:
            return "rectangle.grid.2x2"
        }
    }

    static func defaultLayout(for channelCount: Int) -> MultiScreenLayout {
        channelCount >= 4 ? .four : (channelCount == 3 ? .three : .twoHorizontal)
    }

    static func options(for channelCount: Int) -> [MultiScreenLayout] {
        channelCount >= 4 ? [.twoHorizontal, .three, .four, .pipInset] : (channelCount == 3 ? [.twoHorizontal, .three, .pipInset] : [.twoHorizontal, .twoVertical, .pipInset])
    }
}

/// Alignment position for the PiP overlay inset tile.
private enum PiPAlignment: String, CaseIterable, Identifiable {
    case bottomTrailing
    case bottomLeading
    case topLeading
    case topTrailing

    var id: String { rawValue }

    var alignment: Alignment {
        switch self {
        case .bottomTrailing: return .bottomTrailing
        case .bottomLeading: return .bottomLeading
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        }
    }

    var next: PiPAlignment {
        switch self {
        case .bottomTrailing: return .bottomLeading
        case .bottomLeading: return .topLeading
        case .topLeading: return .topTrailing
        case .topTrailing: return .bottomTrailing
        }
    }
}

/// Plays up to four channels at once with interactive PiP and multi-stream grid layouts.
struct MultiScreenPlayerView: View {
    let channels: [Channel]
    var initialLayout: String? = nil
    var initialAudioChannelID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @State private var replacingChannel: Channel?
    @State private var maximizedChannel: Channel?
    @State private var activeChannels: [Channel] = []
    @State private var controllers: [String: PlaybackController] = [:]
    @State private var layout: MultiScreenLayout = .pipInset
    @State private var primaryChannelID: String?
    @State private var resourceCapacity = PlaybackController.multiviewCapacity
    @State private var pipAlignment: PiPAlignment = .bottomTrailing

    private var visibleChannels: [Channel] {
        Array(activeChannels.prefix(min(layout.capacity, min(resourceCapacity, prefs.playerMaximumStreams))))
    }

    private var activePrimaryID: String? {
        if let maximizedChannel { return StreamLinkerAdapters.streamID(maximizedChannel) }
        if let primaryChannelID, visibleChannels.contains(where: { StreamLinkerAdapters.streamID($0) == primaryChannelID }) {
            return primaryChannelID
        }
        return visibleChannels.first.map(StreamLinkerAdapters.streamID)
    }

    private var layoutOptions: [MultiScreenLayout] {
        MultiScreenLayout.options(for: min(activeChannels.count, min(resourceCapacity, prefs.playerMaximumStreams)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            screenGrid
                .ignoresSafeArea()
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
        }
        .onAppear {
            guard controllers.isEmpty else { return }
            activeChannels = Array(channels.prefix(min(resourceCapacity, prefs.playerMaximumStreams)))
            let saved = initialLayout.flatMap(MultiScreenLayout.init(rawValue:))
            layout = saved.flatMap { layoutOptions.contains($0) ? $0 : nil } ?? MultiScreenLayout.defaultLayout(for: activeChannels.count)
            primaryChannelID = initialAudioChannelID ?? activeChannels.first.map(StreamLinkerAdapters.streamID)
            synchronizeSessions()
            for channel in activeChannels {
                watchStore.recordWatch(channel)
            }
        }
        .sheet(item: $replacingChannel) { previous in
            PlayerChannelListSheet(channels: playlistStore.allChannels.filter { !activeChannels.contains($0) }, currentChannelID: StreamLinkerAdapters.streamID(previous)) { replacement, _ in
                replace(previous, with: replacement)
            }
        }
        .onDisappear {
            guard replacingChannel == nil else { return }
            controllers.values.forEach { $0.stop() }
            controllers.removeAll()
        }
        .onChange(of: primaryChannelID) { _, _ in updateAudio() }
        .onChange(of: layout) { _, _ in synchronizeSessions() }
        .onChange(of: maximizedChannel) { _, _ in synchronizeSessions() }
        .onChange(of: prefs.playerMaximumStreams) { _, _ in synchronizeSessions() }
        .task {
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                resourceCapacity = PlaybackController.multiviewCapacity
                synchronizeSessions()
            }
        }
        #if os(iOS)
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                resourceCapacity = 2
                synchronizeSessions()
            }
        }
        #endif
        .onChange(of: activeChannels.count) { _, newCount in
            if !MultiScreenLayout.options(for: newCount).contains(layout) {
                layout = MultiScreenLayout.defaultLayout(for: newCount)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PlayerCloseButton { dismiss() }

            Text("Multiscreen")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)

            Spacer()
            Menu {
                Menu("Save layout") {
                    ForEach(1...4, id: \.self) { slot in
                        Button("Slot \(slot)") {
                            prefs.saveMultiview(channelIDs: activeChannels.map(StreamLinkerAdapters.streamID), layout: layout.rawValue, slot: slot, audioChannelID: activePrimaryID)
                        }
                    }
                }
                Menu("Restore layout") {
                    ForEach(1...4, id: \.self) { slot in
                        Button("Slot \(slot)") { restoreSavedLayout(slot: slot) }
                            .disabled(prefs.savedMultiview(slot: slot) == nil)
                            #if !os(tvOS)
                            .keyboardShortcut(KeyEquivalent(Character(String(slot))), modifiers: .command)
                            #endif
                    }
                }
                if maximizedChannel != nil {
                    Button("Return to grid") { maximizedChannel = nil }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .accessibilityLabel("Multiview options")

            if layout == .pipInset {
                Button {
                    withAnimation(Theme.Motion.snappy) {
                        pipAlignment = pipAlignment.next
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.subheadline)
                        Text("Position")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cycle PiP inset position")
            }

            // Layout buttons — icon-only for quick switching
            HStack(spacing: 4) {
                ForEach(layoutOptions) { option in
                    Button {
                        withAnimation(Theme.Motion.snappy) { layout = option }
                        #if os(iOS)
                        UISelectionFeedbackGenerator().selectionChanged()
                        #endif
                    } label: {
                        Image(systemName: option.systemImage)
                            .font(.headline)
                            .foregroundStyle(layout == option ? .white : .white.opacity(0.4))
                            .frame(width: 36, height: 36)
                            .background(layout == option ? Theme.accent : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                }
            }
            .padding(4)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .padding(10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private var screenGrid: some View {
        if let maximizedChannel { tile(for: maximizedChannel) }
        else { gridContent }
    }

    @ViewBuilder private var gridContent: some View {
        switch layout {
        case .twoVertical:
            VStack(spacing: 0) {
                ForEach(visibleChannels, id: \.self) { channel in
                    tile(for: channel)
                }
            }
        case .twoHorizontal:
            HStack(spacing: 0) {
                ForEach(visibleChannels, id: \.self) { channel in
                    tile(for: channel)
                }
            }
        case .pipInset:
            GeometryReader { proxy in
                ZStack(alignment: pipAlignment.alignment) {
                    if let primary = visibleChannels.first {
                        tile(for: primary, isPiPInset: false)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    if visibleChannels.count > 1 {
                        let secondary = visibleChannels[1]
                        let pipWidth = min(proxy.size.width * 0.38, 280)
                        let pipHeight = pipWidth * (9.0 / 16.0)
                        tile(for: secondary, isPiPInset: true)
                            .frame(width: pipWidth, height: pipHeight)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                    .strokeBorder(StreamLinkerAdapters.streamID(secondary) == activePrimaryID ? Theme.accent : .white.opacity(0.3), lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 4)
                            .padding(16)
                            .padding(.top, 50)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        case .three:
            HStack(spacing: 2) {
                gridSlot(at: 0)
                VStack(spacing: 2) {
                    gridSlot(at: 1)
                    gridSlot(at: 2)
                }
            }
        case .four:
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    gridSlot(at: 0)
                    gridSlot(at: 1)
                }
                HStack(spacing: 0) {
                    gridSlot(at: 2)
                    gridSlot(at: 3)
                }
            }
        }
    }

    @ViewBuilder private func gridSlot(at index: Int) -> some View {
        if visibleChannels.indices.contains(index) {
            tile(for: visibleChannels[index])
        } else {
            emptyTile(title: "Source slot")
        }
    }

    @ViewBuilder private func tile(for channel: Channel, isPiPInset: Bool = false) -> some View {
        let isPrimary = StreamLinkerAdapters.streamID(channel) == activePrimaryID
        if let controller = controllers[StreamLinkerAdapters.streamID(channel)] {
        StreamTile(
            playback: controller,
            channel: channel,
            isPrimary: isPrimary,
            showsChrome: true,
            onToggleAudio: {
                primaryChannelID = StreamLinkerAdapters.streamID(channel)
            },
            onSwap: {
                swapWithPrimary(channel: channel)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contextMenu {
            Button("Maximize") {
                maximizedChannel = channel
                primaryChannelID = StreamLinkerAdapters.streamID(channel)
            }
            Button("Replace channel") { replacingChannel = channel }
            Button("Remove stream") {
                controllers.removeValue(forKey: StreamLinkerAdapters.streamID(channel))?.stop()
                activeChannels.removeAll { $0 == channel }
                if maximizedChannel == channel { maximizedChannel = nil }
                synchronizeSessions()
            }
        }
        .overlay(
            Group {
                if !isPiPInset {
                    Rectangle()
                        .strokeBorder(isPrimary ? Theme.accent : Theme.hairline, lineWidth: isPrimary ? 2 : 1)
                }
            }
        )
        }
    }

    private func replace(_ previous: Channel, with replacement: Channel) {
        guard let index = activeChannels.firstIndex(of: previous) else { return }
        controllers.removeValue(forKey: StreamLinkerAdapters.streamID(previous))?.stop()
        activeChannels[index] = replacement
        if primaryChannelID == StreamLinkerAdapters.streamID(previous) {
            primaryChannelID = StreamLinkerAdapters.streamID(replacement)
        }
        if maximizedChannel == previous { maximizedChannel = replacement }
        synchronizeSessions()
        watchStore.recordWatch(replacement)
    }

    private func restoreSavedLayout(slot: Int) {
        guard let configuration = prefs.savedMultiview(slot: slot) else { return }
        let available = playlistStore.allChannels
        let restored = configuration.channelIDs.compactMap { id in
            available.first { StreamLinkerAdapters.streamID($0) == id }
        }
        guard !restored.isEmpty else { return }
        controllers.values.forEach { $0.stop() }
        controllers.removeAll()
        activeChannels = Array(restored.prefix(min(resourceCapacity, prefs.playerMaximumStreams)))
        let saved = MultiScreenLayout(rawValue: configuration.layout)
        layout = saved.flatMap { layoutOptions.contains($0) ? $0 : nil } ?? MultiScreenLayout.defaultLayout(for: activeChannels.count)
        maximizedChannel = nil
        primaryChannelID = configuration.audioChannelID ?? activeChannels.first.map(StreamLinkerAdapters.streamID)
        synchronizeSessions()
    }

    /// Only visible tiles own decoders. Reopening a tile rebuilds that tile alone.
    private func synchronizeSessions() {
        let visible = maximizedChannel.map { [$0] } ?? visibleChannels
        let wanted = Set(visible.map(StreamLinkerAdapters.streamID))
        for id in Array(controllers.keys) where !wanted.contains(id) {
            controllers.removeValue(forKey: id)?.stop()
        }
        for channel in visible {
            let id = StreamLinkerAdapters.streamID(channel)
            guard controllers[id] == nil else { continue }
            let controller = PlaybackController()
            controller.setMuted(true)
            controllers[id] = controller
            controller.load(channel)
        }
        updateAudio()
    }

    private func updateAudio() {
        // Mute every session before enabling one; layout changes cannot leave hidden audio playing.
        controllers.values.forEach { $0.setMuted(true) }
        if let id = activePrimaryID { controllers[id]?.setMuted(false) }
    }

    private func swapWithPrimary(channel: Channel) {
        guard let index = activeChannels.firstIndex(where: { $0 == channel }), index != 0 else { return }
        withAnimation(Theme.Motion.snappy) {
            activeChannels.swapAt(0, index)
            primaryChannelID = activeChannels.first.map(StreamLinkerAdapters.streamID)
        }
    }

    private func emptyTile(title: String) -> some View {
        Rectangle()
            .fill(Theme.surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.title2)
                    Text(title)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .overlay(Rectangle().strokeBorder(Theme.hairline))
    }
}

/// Holds an AVPictureInPictureController so StreamTile can check PiP state from stop().
#if os(iOS)
private final class PiPHolder: ObservableObject {
    @Published var controller: AVPictureInPictureController?
    var isActive: Bool { controller?.isPictureInPictureActive == true }
}
#endif

private struct StreamTile: View {
    @ObservedObject var playback: PlaybackController
    let channel: Channel
    let isPrimary: Bool
    let showsChrome: Bool
    var onToggleAudio: (() -> Void)? = nil
    var onSwap: (() -> Void)? = nil

    private var player: AVPlayer { playback.player }
    #if os(iOS)
    @StateObject private var pipHolder = PiPHolder()
    #endif

    var body: some View {
        ZStack {
            Color.black

            VideoSurface(player: player, showsPlaybackControls: false, allowsPictureInPicture: false) { _ in }
            if case let .failed(message) = playback.state {
                VStack(spacing: 10) {
                    Text(message).font(.caption).multilineTextAlignment(.center)
                    Button("Retry") { playback.load(channel) }
                }
                .foregroundStyle(.white)
            } else if !playback.firstFrameRendered || playback.showsBufferingIndicator {
                ProgressView().tint(Theme.accent)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsChrome {
                HStack(spacing: 6) {
                    Button {
                        onToggleAudio?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isPrimary ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.caption2)
                            Text(isPrimary ? "AUDIO LIVE" : "MUTED")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(isPrimary ? Theme.accent : .black.opacity(0.62), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if let onSwap {
                        Button(action: onSwap) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.62), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Swap position with main screen")
                    }
                }
                .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showsChrome {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(channel.group ?? channel.playlistName)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.74)], startPoint: .top, endPoint: .bottom)
                )
            }
        }
    }
}

/// Renders an AVPlayer through AVPlayerLayer. SwiftUI's `VideoPlayer` and
/// AVPlayerViewController can show placeholder chrome when several live HLS
/// streams are attached at once, so tiles host the layer directly.
#if canImport(UIKit)
private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
}

private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let showsPlaybackControls: Bool
    let allowsPictureInPicture: Bool
    var onPiPControllerReady: ((AVPictureInPictureController) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        #if os(iOS)
        if allowsPictureInPicture, AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pipController = pip
            onPiPControllerReady?(pip)
        }
        #endif
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    final class Coordinator: NSObject {
        var pipController: AVPictureInPictureController?
    }
}

/// Hosts the `PlaybackController`'s shared AVPlayer. The surface only attaches the player
/// to its layer and reports the first displayable frame; it never creates or stops players,
/// so it can be rebuilt (rotation, layout changes) without interrupting playback.
private struct PlayerSurface: UIViewRepresentable {
    let controller: PlaybackController
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var onPiPControllerReady: ((AVPictureInPictureController) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = controller.player
        view.playerLayer.videoGravity = videoGravity
        context.coordinator.observeReadyForDisplay(of: view.playerLayer, controller: controller)
        #if os(iOS)
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pipController = pip
            onPiPControllerReady?(pip)
        }
        #endif
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.player !== controller.player {
            view.player = controller.player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.readyObservation?.invalidate()
    }

    final class Coordinator: NSObject {
        var pipController: AVPictureInPictureController?
        var readyObservation: NSKeyValueObservation?

        func observeReadyForDisplay(of layer: AVPlayerLayer, controller: PlaybackController) {
            readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { @Sendable [weak controller] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor [weak controller] in controller?.surfaceReadyForDisplay() }
            }
        }
    }
}
#elseif os(macOS)
private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }
}

private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let showsPlaybackControls: Bool
    let allowsPictureInPicture: Bool
    var onPiPControllerReady: ((AVPictureInPictureController) -> Void)? = nil

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// Hosts the `PlaybackController`'s shared AVPlayer. The surface only attaches the player
/// to its layer and reports the first displayable frame; it never creates or stops players,
/// so it can be rebuilt (window resizes, layout changes) without interrupting playback.
private struct PlayerSurface: NSViewRepresentable {
    let controller: PlaybackController
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var onPiPControllerReady: ((AVPictureInPictureController) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = controller.player
        view.playerLayer.videoGravity = videoGravity
        context.coordinator.observeReadyForDisplay(of: view.playerLayer, controller: controller)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.player !== controller.player {
            view.player = controller.player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.readyObservation?.invalidate()
    }

    final class Coordinator: NSObject {
        var readyObservation: NSKeyValueObservation?

        func observeReadyForDisplay(of layer: AVPlayerLayer, controller: PlaybackController) {
            readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { @Sendable [weak controller] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor [weak controller] in controller?.surfaceReadyForDisplay() }
            }
        }
    }
}
#endif

/// Start-up, buffering and recovery states drawn over the video.
private struct PlaybackStatusOverlay: View {
    @ObservedObject var controller: PlaybackController
    let channel: Channel
    let failoverNotice: String?

    var body: some View {
        ZStack {
            if isStarting {
                // Until the first frame, show which channel is coming instead of a black box.
                ZStack {
                    Color.black.opacity(0.55)
                    VStack(spacing: 12) {
                        CachedImage(url: channel.logoURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Image(systemName: "play.tv.fill")
                                    .font(.title)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .frame(width: 64, height: 64)
                        Text(channel.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        ProgressView()
                            .tint(.white)
                    }
                    .padding(.horizontal, 24)
                }
                .transition(.opacity)
            } else if controller.showsBufferingIndicator {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                    .padding(14)
                    .background(.black.opacity(0.5), in: Circle())
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let pill = statusPill {
                Text(pill)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 72)
                    .transition(.opacity)
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if let summary = controller.metricsSummary {
                Text(summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        #endif
        .animation(Theme.Motion.snappy, value: isStarting)
        .animation(Theme.Motion.snappy, value: controller.showsBufferingIndicator)
        .allowsHitTesting(false)
    }

    private var isStarting: Bool {
        guard !controller.firstFrameRendered else { return false }
        switch controller.state {
        case .loading, .preparing, .connecting, .recovering, .buffering, .playing, .paused: return true
        case .idle, .failed, .ended: return false
        }
    }

    private var statusPill: String? {
        if controller.reconnectAttempt > 0 {
            return "Reconnecting (\(controller.reconnectAttempt)/\(PlaybackController.maxReconnectAttempts))…"
        }
        return failoverNotice
    }
}

private struct PlayerSourceBar: View {
    let channel: Channel
    let streamSummary: String?
    let canStartMultiscreen: Bool
    let multiscreenAction: () -> Void
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var entitlements: EntitlementStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.tv.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(channel.group ?? channel.playlistName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if let streamSummary {
                    Text("Stream: \(streamSummary)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            #if os(iOS)
            AirPlayButton()
                .frame(width: 34, height: 34)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .accessibilityLabel("AirPlay")
            #endif
            Button(action: multiscreenAction) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(canStartMultiscreen ? .white : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    if !entitlements.isPremium {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Theme.actionFill, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canStartMultiscreen)
            .accessibilityLabel("Select multiscreen sources")

            Button {
                watchStore.toggleFavorite(channel)
            } label: {
                Image(systemName: watchStore.isFavorite(channel) ? "heart.fill" : "heart")
                    .font(.headline)
                    .foregroundStyle(watchStore.isFavorite(channel) ? Theme.live : .white)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(watchStore.isFavorite(channel) ? "Remove from favourites" : "Add to favourites")
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.liveFill, in: Capsule())
        }
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct LiveMatchEntry: Identifiable {
    let match: Match
    let sources: [RankedSource]
    var id: String { match.id }
}

private struct PlayerMultiscreenPicker: View {
    let currentChannel: Channel
    let allChannels: [Channel]
    @Binding var selectedChannelIDs: Set<String>
    let startAction: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @EnvironmentObject private var streamStore: StreamAvailabilityStore

    @State private var liveEntries: [LiveMatchEntry] = []
    @State private var isLoadingLive = true
    @State private var showAllSports = false
    @State private var selectedSport: SportGroup? = nil
    @State private var query = ""

    private var canStart: Bool { selectedChannelIDs.count >= 2 }
    private var isAtCapacity: Bool { selectedChannelIDs.count >= min(PlaybackController.multiviewCapacity, prefs.playerMaximumStreams) }

    private var filteredEntries: [LiveMatchEntry] {
        guard let sport = selectedSport else { return liveEntries }
        return liveEntries.filter { $0.match.league.group == sport }
    }

    private func pickerSportChip(title: String, systemImage: String, sport: SportGroup?) -> some View {
        let isSelected = selectedSport == sport
        return Button {
            withAnimation(Theme.Motion.snappy) { selectedSport = sport }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private static let highlightPaths: Set<String> = [
        "football/nfl", "basketball/nba", "hockey/nhl", "baseball/mlb",
        "soccer/eng.1", "soccer/esp.1", "soccer/ger.1", "soccer/ita.1",
        "soccer/fra.1", "soccer/usa.1", "soccer/uefa.champions",
        "racing/f1", "basketball/wnba"
    ]

    private var leaguesToCheck: [League] {
        showAllSports ? League.all : prefs.followedLeagues
    }

    private var filteredChannels: [Channel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allChannels }
        return allChannels.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            ($0.group ?? $0.playlistName).localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Live games section
                Section {
                    if isLoadingLive && liveEntries.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().tint(Theme.accent)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else if liveEntries.isEmpty {
                        Text("No live games right now")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                    } else if filteredEntries.isEmpty {
                        Text("No live games for this sport right now.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredEntries) { entry in
                            LiveMatchPickerRow(
                                match: entry.match,
                                sources: entry.sources,
                                selectedIDs: $selectedChannelIDs,
                                isAtCapacity: isAtCapacity
                            )
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.live).frame(width: 7, height: 7)
                            Text("Live Now")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.live)
                            Spacer()
                            if !liveEntries.isEmpty {
                                Text("\(filteredEntries.count)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Picker("Sport filter", selection: $showAllSports) {
                            Text("My Favorites").tag(false)
                            Text("All Sports").tag(true)
                        }
                        .pickerStyle(.segmented)
                        // Sport chips
                        let sports = SportGroup.allCases.filter { sport in
                            liveEntries.contains { $0.match.league.group == sport }
                        }
                        if sports.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    pickerSportChip(title: "All", systemImage: "sportscourt", sport: nil)
                                    ForEach(sports) { sport in
                                        pickerSportChip(title: sport.rawValue, systemImage: sport.systemImage, sport: sport)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .textCase(nil)
                }

                // Browse all channels
                Section {
                    ForEach(filteredChannels, id: \.self) { channel in
                        channelRow(for: channel)
                    }
                } header: {
                    Text("All Sources")
                        .font(.footnote.weight(.bold))
                }
            }
            .navigationTitle("Add to Multiscreen")
            .inlineNavigationTitle()
            .searchable(text: $query, prompt: "Search channels")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { startAction() }.disabled(!canStart)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Text(canStart
                         ? "\(selectedChannelIDs.count) sources selected · tap Start"
                         : "Pick a game source to add · select 2–4 total")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(canStart ? Theme.accent : Theme.textSecondary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(Theme.background)
            }
        }
        .task(id: showAllSports) {
            selectedSport = nil
            await loadLiveGames()
        }
    }

    @ViewBuilder
    private func channelRow(for channel: Channel) -> some View {
        Button {
            if selectedChannelIDs.contains(StreamLinkerAdapters.streamID(channel)) {
                selectedChannelIDs.remove(StreamLinkerAdapters.streamID(channel))
            } else if !isAtCapacity {
                selectedChannelIDs.insert(StreamLinkerAdapters.streamID(channel))
            }
            #if os(iOS)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedChannelIDs.contains(StreamLinkerAdapters.streamID(channel)) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedChannelIDs.contains(StreamLinkerAdapters.streamID(channel)) ? Theme.accent : Theme.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(StreamLinkerAdapters.streamID(channel) == StreamLinkerAdapters.streamID(currentChannel) ? "Current source" : (channel.group ?? channel.playlistName))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(!selectedChannelIDs.contains(StreamLinkerAdapters.streamID(channel)) && isAtCapacity)
    }

    private func loadLiveGames() async {
        isLoadingLive = true
        let leagues = leaguesToCheck
        let channels = allChannels
        liveEntries = []

        var liveMatches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask {
                    let matches = (try? await SportsRepository.shared.legacyScoreboard(for: league)) ?? []
                    return matches.filter { $0.state == .live }
                }
            }
            for await matches in group { liveMatches.append(contentsOf: matches) }
        }

        // One batched link pass for every live match, instead of scoring each one
        // independently — the linker builds its playlist index once and reuses it.
        guard !Task.isCancelled else { return }
        await streamStore.scan(matches: liveMatches, channels: channels, epgRepository: epgRepository)
        guard !Task.isCancelled else { return }
        liveEntries = liveMatches.map { match in
            LiveMatchEntry(match: match, sources: streamStore.topRanked(for: match.id, limit: 4).filter(\.isConfirmed))
        }
        liveEntries.sort(by: liveEntrySort)
        isLoadingLive = false
    }

    private func liveEntrySort(_ lhs: LiveMatchEntry, _ rhs: LiveMatchEntry) -> Bool {
        if prefs.isFavoriteMatch(lhs.match) != prefs.isFavoriteMatch(rhs.match) {
            return prefs.isFavoriteMatch(lhs.match)
        }
        if lhs.match.league.group.rawValue != rhs.match.league.group.rawValue {
            return lhs.match.league.group.rawValue < rhs.match.league.group.rawValue
        }
        return lhs.match.league.name < rhs.match.league.name
    }
}

private struct LiveMatchPickerRow: View {
    @EnvironmentObject private var prefs: PreferencesStore
    let match: Match
    let sources: [RankedSource]
    @Binding var selectedIDs: Set<String>
    let isAtCapacity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // League + live status badge
            HStack(spacing: 6) {
                Text(match.league.shortName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                Label(prefs.spoilerFreeMode ? "Live" : match.statusDetail, systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.liveFill, in: Capsule())
            }

            // Teams with logos and scores
            VStack(spacing: 8) {
                teamRow(match.away)
                teamRow(match.home)
            }

            // Source chips
            if sources.isEmpty {
                Text("No sources matched in your playlists")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sources.prefix(3)) { ranked in
                            let ch = ranked.channel
                            let isSelected = selectedIDs.contains(StreamLinkerAdapters.streamID(ch))
                            Button {
                                if isSelected { selectedIDs.remove(StreamLinkerAdapters.streamID(ch)) }
                                else if !isAtCapacity { selectedIDs.insert(StreamLinkerAdapters.streamID(ch)) }
                            } label: {
                                HStack(spacing: 4) {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                    }
                                    Text(ch.name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(isSelected ? Theme.actionFill : Theme.surfaceElevated, in: Capsule())
                                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .disabled(!isSelected && isAtCapacity)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func teamRow(_ team: TeamSide) -> some View {
        HStack(spacing: 10) {
            TeamLogo(url: team.logoURL, size: 28)
            Text(team.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            if !prefs.spoilerFreeMode, let score = team.score {
                Text(score)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(team.isWinner ? Theme.textPrimary : Theme.textSecondary)
            }
        }
    }
}

#if os(iOS)
private final class ScreenBrightnessController {
    weak var screen: UIScreen?

    var currentBrightness: CGFloat? {
        screen?.brightness
    }

    func setBrightness(_ value: CGFloat) {
        screen?.brightness = min(max(value, 0), 1)
    }
}

private final class BrightnessHostView: UIView {
    var onScreenChange: ((UIScreen?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onScreenChange?(window?.windowScene?.screen)
    }
}

private struct ScreenBrightnessHost: UIViewRepresentable {
    let controller: ScreenBrightnessController

    func makeUIView(context: Context) -> BrightnessHostView {
        let view = BrightnessHostView(frame: .zero)
        view.onScreenChange = { [weak controller] screen in
            controller?.screen = screen
        }
        return view
    }

    func updateUIView(_ view: BrightnessHostView, context: Context) {
        controller.screen = view.window?.windowScene?.screen
    }
}

private final class SystemVolumeController {
    weak var slider: UISlider?

    var currentVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    func setVolume(_ value: Float) {
        let clampedValue = min(max(value, 0), 1)
        DispatchQueue.main.async { [weak self] in
            self?.slider?.setValue(clampedValue, animated: false)
            self?.slider?.sendActions(for: .touchUpInside)
        }
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        DispatchQueue.main.async {
            controller.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        DispatchQueue.main.async {
            controller.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}
#endif

private struct PlayerChromeButton: View {
    let systemImage: String
    var title: String?
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(Theme.Typography.headline)
                if let title {
                    Text(title)
                        .font(Theme.Typography.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, title == nil ? 0 : Theme.Spacing.sm)
            .playerChromeBackground(in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension View {
    /// Player chrome material: ultra-thin material over a light black tint, with a hairline.
    func playerChromeBackground<S: InsettableShape>(in shape: S) -> some View {
        background(Theme.Materials.playerChromeTint, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
    }
}

private struct PlayerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Close", systemImage: "xmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(.black.opacity(0.72), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close player")
    }
}

private struct PulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(pulsing ? 0.4 : 1)
            .animation(Theme.Motion.respecting(reduceMotion, .easeInOut(duration: 0.85).repeatForever(autoreverses: true)), value: pulsing)
            .onAppear { if !reduceMotion { pulsing = true } }
    }
}

// MARK: - Player More Sheet

private struct PlayerDiagnosticsView: View {
    @ObservedObject var playback: PlaybackController
    let requestedChannel: Channel
    let metadata: StreamRuntimeMetadata?

    var body: some View {
        List {
            LabeledContent("Engine", value: "AVPlayer")
            LabeledContent("Requested channel", value: requestedChannel.name)
            LabeledContent("Active channel", value: playback.channel?.name ?? "None")
            LabeledContent("Channel ID", value: requestedChannel.id.contains("://") ? "Redacted" : requestedChannel.id)
            LabeledContent("State", value: String(describing: playback.state))
            LabeledContent("Recovery attempt", value: "\(playback.reconnectAttempt) / \(PlaybackController.maxReconnectAttempts)")
            if let metadata {
                if let codec = metadata.codec { LabeledContent("Video codec", value: codec) }
                if let height = metadata.height { LabeledContent("Resolution", value: "\(metadata.width ?? 0) × \(height)") }
                if let fps = metadata.frameRate { LabeledContent("Frame rate", value: String(format: "%.2f fps", fps)) }
                if let bitrate = metadata.bitrate { LabeledContent("Bitrate estimate", value: String(format: "%.2f Mbps", bitrate / 1_000_000)) }
            }
            if let summary = playback.metricsSummary { Text(summary).font(.caption.monospaced()) }
            Text("Unknown metrics are omitted. Provider URLs and authorization headers are not displayed.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .navigationTitle("Diagnostics")
    }
}

struct PlayerMoreSheet: View {
    let channel: Channel
    @ObservedObject var streamSelection: StreamSelectionState
    @ObservedObject var playback: PlaybackController
    @Binding var bufferProfile: PlayerBufferProfile
    @Binding var aspect: PlayerAspectMode
    let audioGroup: AVMediaSelectionGroup?
    @Binding var selectedAudioIndex: Int?
    let subtitleGroup: AVMediaSelectionGroup?
    @Binding var selectedSubtitleIndex: Int?
    let streamMetadata: StreamRuntimeMetadata?
    let canStartMultiscreen: Bool
    let multiscreenAction: () -> Void
    let lockAction: () -> Void
    let compactAction: (() -> Void)?
    var recommendationAction: ((Channel) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    optionsHeader

                    PlayerOptionSection(title: "Playback") {
                        if let compactAction {
                            Button("Compact player / Restore window", systemImage: "pip", action: compactAction)
                        }
                        #if os(iOS)
                        HStack {
                            PlayerOptionLabel(systemImage: "airplayvideo", title: "AirPlay", subtitle: "Cast to nearby screens")
                            Spacer()
                            AirPlayButton().frame(width: 44, height: 44)
                        }
                        #endif

                        Button(action: multiscreenAction) {
                            OptionRowContent(
                                systemImage: "rectangle.grid.2x2",
                                title: "Multiscreen",
                                subtitle: entitlements.isPremium ? "Watch multiple sources" : "Premium",
                                value: canStartMultiscreen ? nil : "Unavailable",
                                showsChevron: false
                            )
                        }
                        .disabled(!canStartMultiscreen)

                        Button {
                            watchStore.toggleFavorite(channel)
                        } label: {
                            OptionRowContent(
                                systemImage: watchStore.isFavorite(channel) ? "heart.fill" : "heart",
                                title: watchStore.isFavorite(channel) ? "Remove Favourite" : "Add to Favourites",
                                subtitle: nil,
                                value: nil,
                                showsChevron: false
                            )
                        }
                    }

                    PlayerOptionSection(title: "Stream") {
                        if streamSelection.hasSelectableStreams {
                            NavigationLink {
                                StreamSourceSelectionView(selection: streamSelection)
                            } label: {
                                OptionRowContent(systemImage: "dot.radiowaves.left.and.right", title: "Source", subtitle: nil, value: streamSelection.currentSummary, showsChevron: true)
                            }
                        }

                        NavigationLink {
                            StreamQualitySelectionView(playback: playback, metadata: streamMetadata)
                        } label: {
                            OptionRowContent(systemImage: "sparkles.tv", title: "Quality", subtitle: nil, value: qualitySummary, showsChevron: true)
                        }

                        NavigationLink {
                            BufferSelectionView(selection: $bufferProfile)
                        } label: {
                            OptionRowContent(systemImage: "gauge.with.dots.needle.33percent", title: "Buffer", subtitle: nil, value: bufferProfile.rawValue, showsChevron: true)
                        }

                        if let audioGroup, audioGroup.options.count > 1 {
                            NavigationLink {
                                MediaSelectionView(
                                    title: "Audio Track",
                                    options: audioGroup.options.map(\.displayName),
                                    selectedIndex: $selectedAudioIndex,
                                    includesOff: false
                                )
                            } label: {
                                OptionRowContent(systemImage: "waveform", title: "Audio Track", subtitle: nil, value: selectedMediaTitle(in: audioGroup, selectedIndex: selectedAudioIndex) ?? "Auto", showsChevron: true)
                            }
                        }

                        if let subtitleGroup {
                            NavigationLink {
                                MediaSelectionView(
                                    title: "Subtitles",
                                    options: subtitleGroup.options.map(\.displayName),
                                    selectedIndex: $selectedSubtitleIndex,
                                    includesOff: true
                                )
                            } label: {
                                OptionRowContent(systemImage: "captions.bubble", title: "Subtitles", subtitle: nil, value: selectedMediaTitle(in: subtitleGroup, selectedIndex: selectedSubtitleIndex) ?? "Off", showsChevron: true)
                            }
                        }
                    }

                    PlayerOptionSection(title: "Player preferences") {
                        Button("Lock controls", systemImage: "lock.fill", action: lockAction)
                        Toggle("Hide sports scores", isOn: Binding(get: { prefs.hidesSportsScores }, set: prefs.setSpoilerFreeMode))
                        Picker("Score delay", selection: Binding(get: { prefs.sportsScoreDelaySeconds }, set: prefs.setSportsScoreDelaySeconds)) {
                            Text("Real-time").tag(0)
                            ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) seconds").tag($0) }
                        }
                        Text("Delayed scores use received snapshots, not exact video synchronization. Other score surfaces stay hidden while a delay is active.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        Toggle("Double-tap to seek when available", isOn: Binding(get: { prefs.playerDoubleTapSeeks }, set: prefs.setPlayerDoubleTapSeeks))
                        Text("When disabled, double-tap changes channels. Seeking requires a seekable stream.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        Picker("Hide controls after", selection: Binding(get: { prefs.playerPanelTimeoutSeconds }, set: prefs.setPlayerPanelTimeoutSeconds)) {
                            ForEach(2...30, id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(seconds)
                            }
                        }
                        Toggle("Favourite-team score updates", isOn: Binding(get: { prefs.scoreChangeAlertsEnabled }, set: prefs.setScoreChangeAlertsEnabled))
                        Toggle("Verified broadcast alerts", isOn: Binding(get: { prefs.broadcastAlertsEnabled }, set: prefs.setBroadcastAlertsEnabled))
                        Text("Alerts require notification permission and enabled match notifications. Score alerts are suppressed by spoiler protection.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        Picker("Maximum simultaneous streams", selection: Binding(get: { prefs.playerMaximumStreams }, set: prefs.setPlayerMaximumStreams)) {
                            ForEach(2...4, id: \.self) { Text("\($0) streams").tag($0) }
                        }
                        Text("The device may reduce this limit under resource pressure.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        TextField("Default channel category", text: Binding(get: { prefs.playerDefaultCategory }, set: prefs.setPlayerDefaultCategory))
                        Toggle("Commercial Break Mode", isOn: Binding(get: { prefs.commercialBreakMode }, set: prefs.setCommercialBreakMode))
                        Text("Automatic detection unavailable: this source has no verified commercial-break integration. Audio will not be muted automatically.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }

                    PlayerOptionSection(title: "Picture") {
                        NavigationLink {
                            AspectSelectionView(selection: $aspect)
                        } label: {
                            OptionRowContent(systemImage: aspect.systemImage, title: "Aspect", subtitle: aspect.subtitle, value: aspect.title, showsChevron: true)
                        }
                    }

                    if let recommendationAction {
                        NavigationLink("Recommended games") {
                            PlayerRecommendationsView(onWatch: recommendationAction)
                        }
                    }
                    NavigationLink("Advanced diagnostics") {
                        PlayerDiagnosticsView(playback: playback, requestedChannel: channel, metadata: streamMetadata)
                    }
                    if let diagnostics = diagnosticsSummary {
                        PlayerOptionSection(title: "Stream Summary") {
                            Text(diagnostics)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Theme.Spacing.sm)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Options")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private var optionsHeader: some View {
        Card(padding: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                ChannelLogo(url: channel.logoURL, name: channel.name, size: 48)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(channel.name)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(channel.group ?? channel.playlistName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                LiveBadge()
            }
        }
    }

    private var qualitySummary: String {
        if playback.qualityCap != .auto { return playback.qualityCap.title }
        guard let streamMetadata, let height = streamMetadata.height, height > 0 else { return "Auto" }
        return "Auto · \(height)p"
    }

    private var diagnosticsSummary: String? {
        guard let streamMetadata else { return nil }
        var parts: [String] = []
        if let width = streamMetadata.width, let height = streamMetadata.height, width > 0, height > 0 {
            parts.append("Resolution \(width)x\(height)")
        }
        if let codec = streamMetadata.codec, !codec.isEmpty {
            parts.append(codec)
        }
        if let frameRate = streamMetadata.frameRate, frameRate > 0 {
            parts.append(String(format: "%.0f fps", frameRate))
        }
        if let bitrate = streamMetadata.bitrate, bitrate > 0 {
            parts.append(formatBitrate(bitrate))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func selectedMediaTitle(in group: AVMediaSelectionGroup, selectedIndex: Int?) -> String? {
        guard let selectedIndex, group.options.indices.contains(selectedIndex) else { return nil }
        return group.options[selectedIndex].displayName
    }

    private func formatBitrate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f Kbps", bps / 1_000) }
        return String(format: "%.0f bps", bps)
    }
}

private struct PlayerOptionSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .overlineStyle()
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.xxs)
                .accessibilityAddTraits(.isHeader)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    content
                }
                .padding(.horizontal, Theme.Spacing.sm)
            }
        }
    }
}

private struct PlayerOptionLabel: View {
    let systemImage: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs / 2) {
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
    }
}

private struct OptionRowContent: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    let value: String?
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            PlayerOptionLabel(systemImage: systemImage, title: title, subtitle: subtitle)
            Spacer(minLength: Theme.Spacing.xs)
            if let value, !value.isEmpty {
                Text(value)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct BufferSelectionView: View {
    @Binding var selection: PlayerBufferProfile

    var body: some View {
        SelectionList(title: "Buffer") {
            ForEach(PlayerBufferProfile.allCases) { profile in
                Button {
                    selection = profile
                } label: {
                    SelectionRow(
                        title: profile.rawValue,
                        subtitle: profile.description,
                        isSelected: selection == profile
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AspectSelectionView: View {
    @Binding var selection: PlayerAspectMode

    var body: some View {
        SelectionList(title: "Aspect") {
            ForEach(PlayerAspectMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    SelectionRow(title: mode.title, subtitle: mode.subtitle, isSelected: selection == mode)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct StreamSourceSelectionView: View {
    @ObservedObject var selection: StreamSelectionState

    var body: some View {
        SelectionList(title: "Source") {
            Button {
                selection.selectAuto()
            } label: {
                SelectionRow(title: "Auto", subtitle: selection.autoSummary, isSelected: selection.mode == .auto)
            }
            .buttonStyle(.plain)

            ForEach(selection.displayCandidates) { candidate in
                Button {
                    selection.selectManual(streamID: candidate.stream.id)
                } label: {
                    SelectionRow(
                        title: candidate.primaryLabel,
                        subtitle: streamDetail(for: candidate),
                        isSelected: selection.mode == .manual(candidate.stream.id)
                    )
                }
                .buttonStyle(.plain)
                .disabled(candidate.health == .unavailable)
            }
        }
    }

    private func streamDetail(for candidate: RankedStreamCandidate) -> String? {
        var parts: [String] = []
        if let detail = candidate.detailLabel { parts.append(detail) }
        if candidate.health != .unknown { parts.append(candidate.health.rawValue) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Auto plus 1080p / 720p / 480p caps, listing only heights the stream actually offers.
private struct StreamQualitySelectionView: View {
    @ObservedObject var playback: PlaybackController
    let metadata: StreamRuntimeMetadata?

    var body: some View {
        SelectionList(title: "Quality") {
            Button {
                playback.setQualityCap(.auto)
            } label: {
                SelectionRow(title: "Auto", subtitle: currentDetail ?? "Adapts to your connection", isSelected: playback.qualityCap == .auto)
            }
            .buttonStyle(.plain)

            ForEach(offeredHeights, id: \.self) { height in
                Button {
                    playback.setQualityCap(.height(height))
                } label: {
                    SelectionRow(title: "\(height)p", subtitle: "Up to \(height)p", isSelected: playback.qualityCap == .height(height))
                }
                .buttonStyle(.plain)
            }

            if offeredHeights.isEmpty {
                Text("No selectable representations are currently advertised by this stream.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xxs)
            }
        }
    }

    /// Only offer resolution caps backed by representations advertised by this asset.
    private var offeredHeights: [Int] {
        guard playback.availableHeights.count > 1 else { return [] }
        return playback.availableHeights.filter { $0 > 0 }.sorted(by: >)
    }

    private var currentDetail: String? {
        guard let metadata else { return nil }
        var parts: [String] = []
        if let width = metadata.width, let height = metadata.height, width > 0, height > 0 {
            parts.append("Now \(width)x\(height)")
        }
        if let frameRate = metadata.frameRate, frameRate > 0 {
            parts.append(String(format: "%.0f fps", frameRate))
        }
        if let codec = metadata.codec, !codec.isEmpty {
            parts.append(codec)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct MediaSelectionView: View {
    let title: String
    let options: [String]
    @Binding var selectedIndex: Int?
    let includesOff: Bool

    var body: some View {
        SelectionList(title: title) {
            if includesOff {
                Button {
                    selectedIndex = nil
                } label: {
                    SelectionRow(title: "Off", subtitle: nil, isSelected: selectedIndex == nil)
                }
                .buttonStyle(.plain)
            }

            ForEach(options.indices, id: \.self) { index in
                Button {
                    selectedIndex = index
                } label: {
                    SelectionRow(title: options[index], subtitle: nil, isSelected: selectedIndex == index)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SelectionList<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xs) {
                content
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .inlineNavigationTitle()
    }
}

private struct SelectionRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs / 2) {
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent.opacity(0.38) : Theme.hairline))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Player Channel List Sheet

struct PlayerChannelListSheet: View {
    let channels: [Channel]
    let currentChannelID: String
    let onSelect: (Channel, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @SceneStorage("player.drawer.query") private var query = ""
    @SceneStorage("player.drawer.favorites") private var favoritesOnly = false
    @SceneStorage("player.drawer.category") private var selectedCategory = ""
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var filteredChannels: [Channel] = []
    @State private var categories: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Favourites only", isOn: $favoritesOnly)
                    Picker("Category", selection: $selectedCategory) {
                        Text("All channels").tag("")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                }
                ForEach(filteredChannels, id: \.self) { channel in
                    Button {
                        onSelect(channel, channels.firstIndex(of: channel) ?? 0)
                        dismiss()
                    } label: {
                        PlayerChannelGuideRow(channel: channel, isActive: StreamLinkerAdapters.streamID(channel) == currentChannelID)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(watchStore.isFavorite(channel) ? "Remove Favourite" : "Add to Favourites") {
                            watchStore.toggleFavorite(channel)
                            updateFilter()
                        }
                    }
                    .listRowBackground(StreamLinkerAdapters.streamID(channel) == currentChannelID ? Theme.accent.opacity(0.12) : Theme.surface)
                }
            }
            .listStyle(.plain)
            .hidesScrollContentBackground()
            .searchable(text: $query, prompt: "Search channels")
            .navigationTitle("Channels & Guide")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                categories = Array(Set(channels.compactMap(\.group))).sorted()
                if selectedCategory.isEmpty, categories.contains(prefs.playerDefaultCategory) { selectedCategory = prefs.playerDefaultCategory }
                if !selectedCategory.isEmpty, !categories.contains(selectedCategory) { selectedCategory = "" }
                updateFilter()
            }
            .onChange(of: query) { _, _ in updateFilter() }
            .onChange(of: watchStore.favoriteChannelIDs) { _, _ in updateFilter() }
            .onChange(of: favoritesOnly) { _, _ in updateFilter() }
            .onChange(of: selectedCategory) { _, _ in updateFilter() }
        }
        .tint(Theme.accent)
    }

    private func updateFilter() {
        filteredChannels = channels.filter {
            (selectedCategory.isEmpty || $0.group == selectedCategory)
                && (!favoritesOnly || watchStore.isFavorite($0))
                && (query.isEmpty || $0.name.localizedStandardContains(query))
        }
    }
}

/// EPG lookups are limited to visible list rows, using the existing in-memory index.
private struct PlayerChannelGuideRow: View {
    let channel: Channel
    let isActive: Bool
    @EnvironmentObject private var repository: EPGRepository
    @EnvironmentObject private var watchStore: WatchStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let canonicalID = repository.canonicalChannel(forProviderChannelID: channel.id, playlistID: channel.playlistID)?.id
            let current = canonicalID.flatMap { repository.currentProgramme(for: $0) }
            let next = canonicalID.flatMap { repository.nextProgramme(for: $0) }
            HStack(spacing: Theme.Spacing.sm) {
                ChannelLogo(url: channel.logoURL, name: channel.name, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).font(Theme.Typography.headline).lineLimit(1)
                    if let current {
                        Text(current.title).font(.subheadline).lineLimit(1)
                        Text("\(current.start.formatted(date: .omitted, time: .shortened)) – \(current.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        let duration = current.end.timeIntervalSince(current.start)
                        if duration > 0 {
                            ProgressView(value: min(1, max(0, context.date.timeIntervalSince(current.start) / duration)))
                                .tint(Theme.accent)
                        }
                    } else {
                        Text("Programme information unavailable").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if let next {
                        Text("Next: \(next.title)").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if let category = channel.group {
                        Text(category).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer()
                if watchStore.isFavorite(channel) {
                    Image(systemName: "heart.fill").foregroundStyle(Theme.accent).accessibilityLabel("Favourite")
                }
                if isActive {
                    Image(systemName: "play.fill").foregroundStyle(Theme.accent).accessibilityLabel("Now playing")
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Player Recents Sheet

struct PlayerRecentsSheet: View {
    let currentChannelID: String
    let onSelect: (Channel) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var playlistStore: PlaylistStore

    var body: some View {
        NavigationStack {
            Group {
                if watchStore.recents.isEmpty {
                    EmptyStateView(systemImage: "clock.arrow.circlepath", title: "No Recent Channels",
                                   message: "Channels you watch for a little while show up here.")
                        .background(Theme.background)
                } else {
                    List {
                        ForEach(watchStore.recents) { entry in
                            if let ch = playlistStore.channel(for: entry.saved) {
                                Button {
                                    onSelect(ch)
                                    dismiss()
                                } label: {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        ChannelLogo(url: ch.logoURL, name: ch.name, size: 40)
                                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs / 2) {
                                            Text(ch.name).font(Theme.Typography.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                            Text(relativeTime(entry.watchedAt)).font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                                        }
                                        Spacer()
                                        if StreamLinkerAdapters.streamID(ch) == currentChannelID {
                                            Image(systemName: "play.fill").foregroundStyle(Theme.accent).font(Theme.Typography.caption)
                                                .accessibilityLabel("Now playing")
                                        }
                                    }
                                    .frame(minHeight: 52)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(StreamLinkerAdapters.streamID(ch) == currentChannelID ? Theme.accent.opacity(0.12) : Theme.surface)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .hidesScrollContentBackground()
                }
            }
            .navigationTitle("Recent Channels")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }
}

// MARK: - Gesture onboarding hint

#if os(iOS)
private struct PlayerGestureHint: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 44) {
                VStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.Palette.gold)
                    Text("Left side")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Brightness")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                VStack(spacing: 8) {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                    Text("Right side")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Volume")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Text("Swipe up or down to adjust")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Button("Got it", action: dismiss)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Theme.actionFill, in: Capsule())
        }
        .padding(24)
        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 24)
    }
}
#endif

#if os(iOS)
private struct PlayerAdjustmentHUD: View {
    let icon: String
    let level: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)

            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint)
                        .frame(height: proxy.size.height * max(0, min(level, 1)))
                }
            }
            .frame(width: 5, height: 100)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        )
        .transition(.opacity.combined(with: .scale(scale: 0.88)))
    }
}
#endif


/// Uses the existing schedule cache and broadcast matcher; browsing never owns a player.
struct PlayerRecommendationsView: View {
    let onWatch: (Channel) -> Void
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var repository: EPGRepository
    @EnvironmentObject private var streams: StreamAvailabilityStore
    @State private var matches: [Match] = []
    @State private var loading = true
    @State private var selection: Channel?
    @State private var selectedMatch: Match?
    @State private var refreshID = UUID()
    @State private var failure: String?

    var body: some View {
        List {
            if loading { ProgressView("Finding games…") }
            if let failure { Text(failure).foregroundStyle(Theme.textSecondary) }
            ForEach(matches) { match in
                let sources = streams.topRanked(for: match.id, limit: 4).filter(\.isConfirmed)
                Section {
                    if match.state == .pre {
                        Text("Upcoming · \(match.date.formatted(date: .abbreviated, time: .shortened))")
                        Button("Remind me") {
                            Task {
                                if !(await MatchNotificationService.shared.scheduleReminder(for: match, leadTime: prefs.matchReminderLeadTime)) {
                                    failure = "Reminder unavailable. Check notification permissions."
                                }
                            }
                        }
                        #if os(tvOS)
                        .disabled(true)
                        #endif
                    } else if sources.isEmpty {
                        Text("Unavailable through current IPTV sources")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(sources) { source in
                            Button("Watch now · \(source.channel.name)") {
                                failure = nil
                                selectedMatch = match
                                selection = source.channel
                            }
                        }
                    }
                } header: {
                    Text("\(match.league.shortName) · \(match.away.shortName) vs \(match.home.shortName)")
                }
            }
            if !loading && matches.isEmpty && failure == nil {
                Text("No live or upcoming games in your followed leagues.")
            }
        }
        .navigationTitle("Recommended games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .disabled(loading)
            }
        }
        .task(id: prefs.followedLeagues.map(\.path) + [refreshID.uuidString]) {
            loading = true
            failure = nil
            selection = nil
            selectedMatch = nil
            var result: [Match] = []
            var failedLeagues = 0
            await withTaskGroup(of: [Match]?.self) { group in
                for league in prefs.followedLeagues {
                    group.addTask { try? await SportsRepository.shared.legacyScoreboard(for: league) }
                }
                for await batch in group {
                    if let batch { result.append(contentsOf: batch) }
                    else { failedLeagues += 1 }
                }
            }
            guard !Task.isCancelled else { return }
            if failedLeagues > 0 {
                failure = "Some schedules could not be loaded. Refresh to try again."
            }
            let now = Date()
            var seen = Set<String>()
            matches = result.filter { seen.insert($0.id).inserted }.filter {
                ($0.state == .live && abs($0.date.timeIntervalSince(now)) < 12 * 3600)
                    || ($0.state == .pre && $0.date >= now && $0.date < now.addingTimeInterval(86400))
            }.sorted {
                if prefs.isFavoriteMatch($0) != prefs.isFavoriteMatch($1) { return prefs.isFavoriteMatch($0) }
                if $0.state != $1.state { return $0.state == .live }
                return $0.date < $1.date
            }
            await streams.scan(matches: matches, channels: playlistStore.allChannels, epgRepository: repository)
            guard !Task.isCancelled else { return }
            loading = false
        }
        .task(id: [selectedMatch?.id ?? "", selection.map(StreamLinkerAdapters.streamID) ?? ""]) {
            guard let selection, let selectedMatch else { return }
            let confirmed = await streams.confirmsCurrentBroadcast(match: selectedMatch, channel: selection,
                channels: playlistStore.allChannels, epgRepository: repository)
            guard !Task.isCancelled else { return }
            if confirmed { onWatch(selection) }
            else { failure = "No confirmed stream found."; self.selection = nil }
        }
    }
}


/// Shown only for notifications delivered through the existing system delegate.
struct PlayerSportsAlertBanner: View {
    @State private var alert: PlannedNotification?
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        Group {
            if let alert, prefs.matchNotificationsEnabled, prefs.allowsMatchNotification(alert.userInfo) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        if let link = DeepLink(notificationUserInfo: alert.userInfo) {
                            DeepLinkRouter.shared.handle(link)
                        }
                        self.alert = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alert.title).font(.subheadline.bold()).lineLimit(2)
                            Text(alert.body).font(.caption).lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                    Button { self.alert = nil } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Dismiss sports alert")
                }
                .padding(12).frame(maxWidth: 340)
                .foregroundStyle(.white)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .task {
            for await value in NotificationCenter.default.notifications(named: .bannerPlayerSportsAlert)
                .compactMap({ $0.userInfo?["alert"] as? PlannedNotification }) {
                guard !Task.isCancelled else { return }
                alert = value
            }
        }
        .task(id: alert?.identifier) {
            guard alert != nil else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            alert = nil
        }
        .onChange(of: prefs.spoilerFreeMode) { _, _ in alert = nil }
    }
}
