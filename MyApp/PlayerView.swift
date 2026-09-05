import SwiftUI
import AVKit
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

    var body: some View {
        #if !os(tvOS)
        ZStack {
            keyButton("chUp",    shortcut: .init(.upArrow,   modifiers: []), action: onChannelUp)
            keyButton("chDown",  shortcut: .init(.downArrow, modifiers: []), action: onChannelDown)
            keyButton("chrome",  shortcut: .init(.space,     modifiers: []), action: onToggleChrome)
            keyButton("guide",   shortcut: .init("g",        modifiers: []), action: onOpenGuide)
            keyButton("chList",  shortcut: .init("l",        modifiers: []), action: onOpenChannelList)
            keyButton("recents", shortcut: .init("r",        modifiers: []), action: onOpenRecents)
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

private struct PlayerFantasyOverlay: View {
    let games: [FantasyPlayerGame]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fantasy", systemImage: "star.fill")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.accent)
            ForEach(games.prefix(4)) { game in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(game.fantasyPlayer.fullName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text([game.lineupPosition, game.isFantasyStarter ? "Starter" : game.isFantasyBench ? "Bench" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(game.fantasyPoints.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                        .font(.caption.weight(.black).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fantasy overlay, \(games.count) players in this game")
    }
}

// MARK: - Player

/// Presents a channel's stream full screen.
struct PlayerView: View {
    let channel: Channel
    let canonicalChannel: CanonicalChannel?
    let zapChannels: [Channel]
    /// When false, hides the Guide button (and other IPTV-only controls) from the control bar.
    /// Set to false when opening from a sports match context where EPG navigation is irrelevant.
    let showsLiveTVControls: Bool
    @StateObject private var streamSelection: StreamSelectionState
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var nativeFantasyStore: StadiaFantasyStore

    // Zap / channel navigation state
    @State private var currentZapChannel: Channel
    @State private var zapIndex: Int
    @State private var dwellTask: Task<Void, Never>?

    // Playback options
    @State private var bufferProfile: PlayerBufferProfile = .normal
    @State private var activeStreamMetadata: StreamRuntimeMetadata?
    @State private var currentPlayerItem: AVPlayerItem?
    @State private var audioGroup: AVMediaSelectionGroup?
    @State private var subtitleGroup: AVMediaSelectionGroup?
    @State private var selectedAudioIndex: Int?
    @State private var selectedSubtitleIndex: Int?

    // Player chrome panels
    @State private var showingMore = false
    @State private var showingChannelList = false
    @State private var showingRecents = false
    @State private var showingGuideFromPlayer = false

    @State private var isChromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var preferredOrientation: PlayerOrientation = .portrait
    @State private var isShowingMultiscreenPicker = false
    @State private var selectedMultiChannelIDs: Set<String> = []
    @State private var multiscreenSession: PlayerMultiscreenSession?
    #if os(iOS)
    @State private var brightnessDragStart: CGFloat?
    @State private var volumeDragStart: Float?
    @State private var brightnessController = ScreenBrightnessController()
    @State private var volumeController = SystemVolumeController()
    @State private var brightnessOverlay: CGFloat?
    @State private var volumeOverlay: Float?
    @State private var hudHideTask: Task<Void, Never>?
    @State private var showGestureHint = false
    private static let gestureOnboardingKey = "stadiatv.player.gestureOnboarding.v1"
    #endif

    // Live score overlay
    @State private var liveScoreMatch: Match?
    @State private var isScoreExpanded = false
    @State private var isScoreDismissed = false
    @State private var scoreFetchTask: Task<Void, Never>?
    @State private var matchResolutionState: PlayerMatchResolutionState = .resolving
    @State private var selectedPlayerTab: SportPlayerTab = .game
    @State private var isLandscapeGameCentreVisible = false
    @State private var showPaywall = false
    @State private var showingSourceSelector = false
    #if os(iOS)
    @State private var dismissalDragOffset: CGSize = .zero
    @State private var activeDismissalGesture: PlayerDismissalGestureKind?
    #endif

    init(channel: Channel, zapChannels: [Channel] = [], currentIndex: Int = 0, showsLiveTVControls: Bool = true) {
        self.channel = channel
        self.canonicalChannel = nil
        self.showsLiveTVControls = showsLiveTVControls
        let zap = zapChannels.isEmpty ? [channel] : zapChannels
        self.zapChannels = zap
        let idx = zap.indices.contains(currentIndex) ? currentIndex : 0
        _currentZapChannel = State(initialValue: zap[idx])
        _zapIndex = State(initialValue: idx)
        _streamSelection = StateObject(wrappedValue: StreamSelectionState(channel: zap[idx]))
    }

    init(canonicalChannel: CanonicalChannel) {
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
        self.canonicalChannel = canonicalChannel
        self.showsLiveTVControls = true
        self.zapChannels = [channel]
        _currentZapChannel = State(initialValue: channel)
        _zapIndex = State(initialValue: 0)
        _streamSelection = StateObject(wrappedValue: StreamSelectionState(channel: channel, canonicalChannel: canonicalChannel))
    }

    // Sorting and deduping a big playlist is expensive, so it runs once off
    // the main thread instead of inside every body evaluation.
    @State private var multiscreenChannels: [Channel] = []

    private var canStartMultiscreen: Bool {
        playlistStore.channelsByPlaylist.values.contains { channels in
            channels.contains { $0.id != currentZapChannel.id }
        }
    }

    private var currentChannelFantasyGames: [FantasyPlayerGame] {
        var ids = [currentZapChannel.id]
        if let canonicalChannel {
            ids.append(canonicalChannel.id)
            ids.append(contentsOf: canonicalChannel.allStreams.map(\.providerChannelId))
        }
        var seen = Set<String>()
        return ids.flatMap { fantasyStore.fantasyGames(for: $0) + nativeFantasyStore.fantasyGames(for: $0) }
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.isFantasyStarter != rhs.isFantasyStarter { return lhs.isFantasyStarter }
                return lhs.fantasyPlayer.fullName < rhs.fantasyPlayer.fullName
            }
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

    var body: some View {
        MatchPlayerScreen(
            channel: activePlaybackChannel,
            canonicalChannel: canonicalChannel,
            match: liveScoreMatch,
            scoreBugMatch: prefs.showLiveScoreBadge && !isScoreDismissed ? liveScoreMatch : nil,
            matchResolutionState: matchResolutionState,
            selectedTab: $selectedPlayerTab,
            isChromeVisible: isChromeVisible,
            isLandscapeGameCentreVisible: $isLandscapeGameCentreVisible,
            streamSummary: streamSelection.currentSummary,
            canStartMultiscreen: canStartMultiscreen,
            hasPreviousChannel: zapIndex > 0,
            hasNextChannel: zapIndex < zapChannels.count - 1,
            showsLiveTVControls: showsLiveTVControls,
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
            orientation: preferredOrientation
        ) {
            StreamTile(
                channel: activePlaybackChannel,
                isPrimary: true,
                showsChrome: false,
                bufferProfile: bufferProfile,
                onFailure: {
                    guard activePlaybackChannel.id == streamSelection.activeChannel.id else { return }
                    streamSelection.handlePlaybackFailure()
                },
                onMetadata: { metadata in
                    activeStreamMetadata = metadata
                    if let streamID = streamSelection.activeStream?.id {
                        streamSelection.updateRuntimeMetadata(metadata, for: streamID)
                    }
                },
                onPlayerItemReady: { item in
                    handlePlayerItemReady(item)
                }
            )
            .id(activePlaybackChannel.id)
        }
        #if os(iOS)
        .offset(x: dismissalDragOffset.width, y: max(0, dismissalDragOffset.height))
        .scaleEffect(playerScaleForDismissal)
        .opacity(playerDimForDismissal)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: dismissalDragOffset)
        #endif
        .contentShape(Rectangle())
        #if os(iOS)
        .simultaneousGesture(playerDismissalGesture)
        .simultaneousGesture(TapGesture().onEnded { toggleChromeVisibility() })
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
                        tint: Color(hex: 0xFFD700)
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
            .animation(.easeInOut(duration: 0.18), value: brightnessOverlay != nil || volumeOverlay != nil)
            .allowsHitTesting(false)
        }
        #endif
        // Live score badge — always visible while a matched live game is tracked
        .overlay(alignment: .top) {
            if false, let match = liveScoreMatch, prefs.showLiveScoreBadge, !isScoreDismissed {
                LiveScoreBadge(match: match, isExpanded: $isScoreExpanded) {
                    withAnimation(.spring(duration: 0.28)) { isScoreDismissed = true }
                }
                .padding(.top, isChromeVisible ? 68 : 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: liveScoreMatch?.id)
        .overlay(alignment: .center) {
            if currentZapChannel.id == channel.id, case let .failed(message) = streamSelection.switchState {
                StreamFailurePanel(
                    message: message,
                    tryAgain: { streamSelection.retryActiveStream(); revealChromeTemporarily() },
                    chooseAnother: { revealChromeTemporarily() },
                    switchToAuto: { streamSelection.selectAuto(); revealChromeTemporarily() }
                )
                .padding(24)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .overlay(alignment: .center) {
            if currentZapChannel.id == channel.id, streamSelection.switchState == .switching {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(18)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        // Gesture onboarding hint
        #if os(iOS)
        .overlay(alignment: .center) {
            if showGestureHint {
                PlayerGestureHint {
                    withAnimation(.easeOut(duration: 0.2)) { showGestureHint = false }
                    UserDefaults.standard.set(true, forKey: Self.gestureOnboardingKey)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showGestureHint)
        #endif
        .overlay(alignment: .topLeading) {
            if false, isChromeVisible {
                PlayerChromeButton(systemImage: "chevron.backward", title: "Back", accessibilityLabel: "Back") {
                    dismiss()
                }
                .padding(.top, 16)
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if false, isChromeVisible {
                HStack(spacing: 8) {
                    if streamSelection.hasSelectableStreams && currentZapChannel.id == channel.id {
                        StreamQualityMenu(selection: streamSelection) {
                            revealChromeTemporarily()
                        }
                    }
                    PlayerChromeButton(systemImage: preferredOrientation.systemImage,
                                       title: preferredOrientation.buttonTitle,
                                       accessibilityLabel: preferredOrientation.accessibilityLabel) {
                        toggleOrientation()
                    }
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if false, isChromeVisible, let canonicalChannel, let programme = epgRepository.currentProgramme(for: canonicalChannel.id) {
                PlayerNowOnOverlay(
                    channelName: canonicalChannel.name,
                    currentProgramme: programme,
                    nextProgramme: epgRepository.nextProgramme(for: canonicalChannel.id)
                )
                .padding(.leading, 16)
                .padding(.bottom, 84)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if false, isChromeVisible, fantasyStore.settings.showFantasyPlayerOverlay, !currentChannelFantasyGames.isEmpty {
                PlayerFantasyOverlay(games: currentChannelFantasyGames)
                    .padding(.trailing, 16)
                    .padding(.bottom, 84)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if false, isChromeVisible {
                PlayerControlBar(
                    hasPrev: zapIndex > 0,
                    hasNext: zapIndex < zapChannels.count - 1,
                    onPrev: { zapTo(index: zapIndex - 1) },
                    onNext: { zapTo(index: zapIndex + 1) },
                    onGuide: showsLiveTVControls ? { showingGuideFromPlayer = true } : nil,
                    onChannels: zapChannels.count > 1 ? { showingChannelList = true } : nil,
                    onRecent: showsLiveTVControls ? { showingRecents = true } : nil,
                    onMore: { showingMore = true }
                )
                .padding(16)
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $isShowingMultiscreenPicker) {
            PlayerMultiscreenPicker(currentChannel: currentZapChannel,
                                    allChannels: multiscreenChannels,
                                    selectedChannelIDs: $selectedMultiChannelIDs,
                                    startAction: startMultiscreen)
        }
        .sheet(isPresented: $showingSourceSelector) {
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
        .sheet(isPresented: $showingMore) {
            PlayerMoreSheet(
                channel: activePlaybackChannel,
                streamSelection: streamSelection,
                bufferProfile: $bufferProfile,
                audioGroup: audioGroup,
                selectedAudioIndex: $selectedAudioIndex,
                subtitleGroup: subtitleGroup,
                selectedSubtitleIndex: $selectedSubtitleIndex,
                streamMetadata: activeStreamMetadata,
                canStartMultiscreen: canStartMultiscreen,
                multiscreenAction: { showingMore = false; showMultiscreenPicker() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingChannelList) {
            PlayerChannelListSheet(
                channels: zapChannels,
                currentChannelID: currentZapChannel.id,
                onSelect: { _, index in zapTo(index: index) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingRecents) {
            PlayerRecentsSheet(
                currentChannelID: currentZapChannel.id,
                onSelect: { ch in
                    let idx = zapChannels.firstIndex(where: { $0.id == ch.id })
                    if let idx {
                        zapTo(index: idx)
                    } else {
                        currentZapChannel = ch
                        startDwellTimer()
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingGuideFromPlayer) {
            TVGuideView(onChannelSelected: { canonicalChannel in
                if let ch = canonicalChannel.playableChannel {
                    let idx = zapChannels.firstIndex(where: { $0.id == ch.id })
                    if let idx { zapTo(index: idx) } else { currentZapChannel = ch; startDwellTimer() }
                }
                showingGuideFromPlayer = false
            })
        }
        .fullScreenCover(item: $multiscreenSession) { session in
            MultiScreenPlayerView(channels: session.channels)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .overlay { keyboardCommandHandler }
        .animation(.easeInOut(duration: 0.22), value: isChromeVisible)
        .onAppear {
            watchStore.recordWatch(channel)
            startDwellTimer()
            revealChromeTemporarily()
            #if os(iOS)
            if !UserDefaults.standard.bool(forKey: Self.gestureOnboardingKey) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeIn(duration: 0.2)) { showGestureHint = true }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { showGestureHint = false }
                    UserDefaults.standard.set(true, forKey: Self.gestureOnboardingKey)
                }
            }
            #endif
        }
        .onDisappear {
            dwellTask?.cancel()
            chromeHideTask?.cancel()
            scoreFetchTask?.cancel()
            #if os(iOS)
            brightnessDragStart = nil
            volumeDragStart = nil
            #endif
            requestOrientation(.portrait)
        }
        .onChange(of: selectedAudioIndex) { _, idx in applyAudioTrack(index: idx) }
        .onChange(of: selectedSubtitleIndex) { _, idx in applySubtitleTrack(index: idx) }
        .task(id: currentZapChannel.id) {
            isScoreDismissed = false
            isScoreExpanded = false
            scoreFetchTask?.cancel()
            let zapChannel = currentZapChannel
            scoreFetchTask = Task { await findAndPollLiveMatch(for: zapChannel) }
        }
        .task(id: playlistStore.allChannels.count) {
            let channels = playlistStore.allChannels
            let current = channel
            multiscreenChannels = await Task.detached(priority: .utility) {
                var seenIDs: Set<String> = [current.id]
                var result = [current]
                let sorted = channels.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                for candidate in sorted where seenIDs.insert(candidate.id).inserted {
                    result.append(candidate)
                }
                return result
            }.value
        }
    }

    #if os(iOS)
    private var playerGestureZones: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(verticalAdjustmentGesture(height: proxy.size.height, side: .brightness))
                    .simultaneousGesture(TapGesture().onEnded { toggleChromeVisibility() })
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(verticalAdjustmentGesture(height: proxy.size.height, side: .volume))
                    .simultaneousGesture(TapGesture().onEnded { toggleChromeVisibility() })
            }
            .ignoresSafeArea()
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
        let horizontal = value.translation.width
        let vertical = value.translation.height
        if value.startLocation.x <= 24, horizontal > 18, abs(horizontal) > abs(vertical) * 1.25 {
            return .edgePop
        }
        let upperPlayerLimit = UIScreen.main.bounds.height * 0.46
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
    #endif

    private var keyboardCommandHandler: some View {
        LiveCommandKeyboardHandler(
            onChannelUp:       { zapTo(index: zapIndex - 1) },
            onChannelDown:     { zapTo(index: zapIndex + 1) },
            onToggleChrome:    { toggleChromeVisibility() },
            onOpenGuide:       { showingGuideFromPlayer = true; revealChromeTemporarily() },
            onOpenChannelList: { showingChannelList = true; revealChromeTemporarily() },
            onOpenRecents:     { showingRecents = true; revealChromeTemporarily() },
            onExit:            { dismiss() }
        )
    }

    private func toggleOrientation() {
        preferredOrientation = preferredOrientation.toggled
        requestOrientation(preferredOrientation)
        revealChromeTemporarily()
    }

    private func showMultiscreenPicker() {
        guard entitlements.isPremium else {
            showPaywall = true
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            return
        }
        selectedMultiChannelIDs = [channel.id]
        isShowingMultiscreenPicker = true
        revealChromeTemporarily()
    }

    private func startMultiscreen() {
        let channels = multiscreenChannels.filter { selectedMultiChannelIDs.contains($0.id) }
        guard channels.count >= 2 else { return }
        let session = PlayerMultiscreenSession(channels: Array(channels.prefix(4)))
        isShowingMultiscreenPicker = false
        selectedMultiChannelIDs.removeAll()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            multiscreenSession = session
        }
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
        chromeHideTask = Task { @MainActor in
            let ns = UInt64(prefs.playerPanelTimeoutSeconds) * 1_000_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            isChromeVisible = false
        }
    }

    // MARK: Channel zapping

    private func zapTo(index: Int) {
        guard zapChannels.indices.contains(index), zapChannels[index].id != currentZapChannel.id else { return }
        dwellTask?.cancel()
        currentPlayerItem = nil
        audioGroup = nil
        subtitleGroup = nil
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        zapIndex = index
        currentZapChannel = zapChannels[index]
        startDwellTimer()
        revealChromeTemporarily()
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
        let asset = item.asset
        Task { @MainActor in
            if let audio = try? await asset.loadMediaSelectionGroup(for: .audible),
               audio.options.count > 1 {
                audioGroup = audio
            }
            if let subs = try? await asset.loadMediaSelectionGroup(for: .legible),
               !subs.options.isEmpty {
                subtitleGroup = subs
            }
        }
    }

    private func applyAudioTrack(index: Int?) {
        guard let item = currentPlayerItem, let group = audioGroup, let idx = index,
              group.options.indices.contains(idx) else { return }
        item.select(group.options[idx], in: group)
    }

    private func applySubtitleTrack(index: Int?) {
        guard let item = currentPlayerItem, let group = subtitleGroup else { return }
        if let idx = index, group.options.indices.contains(idx) {
            item.select(group.options[idx], in: group)
        } else {
            item.select(nil, in: group)
        }
    }

    // MARK: Live score tracking

    private func findAndPollLiveMatch(for targetChannel: Channel) async {
        let channel = targetChannel
        matchResolutionState = .resolving
        let programme = currentProgramme(for: channel)
        let leaguePaths = [
            "football/nfl", "football/college-football", "football/cfl", "basketball/nba", "basketball/wnba",
            "hockey/nhl", "baseball/mlb", "soccer/eng.1", "soccer/esp.1", "soccer/ger.1",
            "soccer/ita.1", "soccer/usa.1", "soccer/mex.1", "racing/f1"
        ]
        let leagues = leaguePaths.compactMap { path in League.all.first { $0.path == path } }
        let today = Calendar.current.startOfDay(for: Date())

        var candidates: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask {
                    let live = (try? await SportsRepository.shared.legacyScoreboard(for: league)) ?? []
                    let todaySchedule = (try? await SportsRepository.shared.legacyScoreboards(for: league, starting: today, days: 1)) ?? []
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
        for match in uniqueCandidates {
            let score = matchCandidateScore(match, channel: channel, programme: programme)
            if score > bestScore {
                bestScore = score
                bestMatch = match
            }
        }

        guard let match = bestMatch, bestScore >= 48 else {
            liveScoreMatch = nil
            matchResolutionState = .unavailable
            return
        }

        matchResolutionState = .loadingData
        let enriched = await SportsRepository.shared.enrichedLegacyMatch(match)
        guard !Task.isCancelled else { return }
        liveScoreMatch = enriched
        matchResolutionState = .connected

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await SportsRepository.shared.legacyScoreboard(for: match.league).first(where: { $0.id == match.id }) {
                liveScoreMatch = await SportsRepository.shared.enrichedLegacyMatch(updated)
                matchResolutionState = .connected
                if updated.state == .final { break }
            } else {
                matchResolutionState = .apiFailed
            }
        }
    }

    private func currentProgramme(for channel: Channel) -> EPGProgramme? {
        if let canonicalChannel {
            return epgRepository.currentProgramme(for: canonicalChannel.id)
        }
        if let canonical = epgRepository.canonicalChannels.first(where: { candidate in
            candidate.id == channel.id || candidate.allStreams.contains { $0.providerChannelId == channel.id }
        }) {
            return epgRepository.currentProgramme(for: canonical.id)
        }
        return nil
    }

    private func matchCandidateScore(_ match: Match, channel: Channel, programme: EPGProgramme?) -> Int {
        var score = SourceMatcher.rank(match: match, channels: [channel], preferredLanguages: prefs.preferredStreamLanguages).first?.score ?? 0
        let programmeText = [programme?.title, programme?.subtitle, programme?.description, programme?.categories.joined(separator: " ")]
            .compactMap { $0 }
            .joined(separator: " ")
        if !programmeText.isEmpty {
            score += metadataMatchScore(match: match, text: programmeText)
        }
        if let programme, programme.isOnNow() {
            score += 8
        }
        return score
    }

    private func metadataMatchScore(match: Match, text: String) -> Int {
        let normalizedText = PlayerMatchTextNormalizer.normalized(text)
        guard !normalizedText.isEmpty else { return 0 }
        var score = 0
        let titleTokens = PlayerMatchTextNormalizer.tokens(from: [match.name, match.shortName].joined(separator: " "))
        let teamTokens = PlayerMatchTextNormalizer.tokens(from: [
            match.away.displayName, match.away.shortName, match.away.abbreviation,
            match.home.displayName, match.home.shortName, match.home.abbreviation
        ].joined(separator: " "))
        let leagueTokens = PlayerMatchTextNormalizer.tokens(from: ([match.league.name, match.league.shortName] + match.league.keywords).joined(separator: " "))
        score += titleTokens.filter { normalizedText.contains($0) }.count * 12
        score += teamTokens.filter { normalizedText.contains($0) }.count * 10
        score += leagueTokens.filter { normalizedText.contains($0) }.count * 4
        return score
    }

    #if os(iOS)
    private func scheduleHudHide() {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
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

// MARK: - Sports-first Match Player

private enum StadiaSport: String {
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

private struct MatchPlayerScreen<VideoContent: View>: View {
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
    let orientation: PlayerOrientation
    let videoContent: VideoContent

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
        orientation: PlayerOrientation,
        @ViewBuilder videoContent: () -> VideoContent
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
        self.orientation = orientation
        self.videoContent = videoContent()
    }

    private var sport: StadiaSport { StadiaSport(league: match?.league) }
    private var effectiveTab: SportPlayerTab { sport.tabs.contains(selectedTab) ? selectedTab : sport.tabs.first ?? .game }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscapeLayout
            } else {
                portraitLayout(height: proxy.size.height)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: sport.rawValue) { _, _ in
            selectedTab = sport.tabs.first ?? .game
        }
    }

    private func portraitLayout(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            PlayerVideoContainer(
                channel: channel,
                match: scoreBugMatch,
                sport: sport,
                isChromeVisible: isChromeVisible,
                streamSummary: streamSummary,
                orientation: orientation,
                onDismiss: onDismiss,
                onMore: onMore,
                onSourceSelector: onSourceSelector,
                onCycleSource: onCycleSource,
                onToggleOrientation: onToggleOrientation,
                videoContent: { videoContent }
            )
            .frame(height: max(320, height * 0.43))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MatchMetadataHeader(match: match, channel: channel)
                    MatchTabs(tabs: sport.tabs, selection: $selectedTab)
                    SportGameCentre(match: match, state: matchResolutionState, sport: sport, selectedTab: effectiveTab)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 34)
            }
            .background(Theme.background)
        }
        .ignoresSafeArea(edges: .top)
    }

    private var landscapeLayout: some View {
        ZStack(alignment: .trailing) {
            PlayerVideoContainer(
                channel: channel,
                match: scoreBugMatch,
                sport: sport,
                isChromeVisible: isChromeVisible,
                streamSummary: streamSummary,
                orientation: orientation,
                onDismiss: onDismiss,
                onMore: onMore,
                onSourceSelector: onSourceSelector,
                onCycleSource: onCycleSource,
                onToggleOrientation: onToggleOrientation,
                videoContent: { videoContent }
            )
            .ignoresSafeArea()

            if isChromeVisible {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        if hasPreviousChannel {
                            PlayerChromeButton(systemImage: "chevron.left", accessibilityLabel: "Previous channel", action: onPreviousChannel)
                        }
                        if hasNextChannel {
                            PlayerChromeButton(systemImage: "chevron.right", accessibilityLabel: "Next channel", action: onNextChannel)
                        }
                        if showsLiveTVControls {
                            PlayerChromeButton(systemImage: "rectangle.grid.1x2.fill", title: "Guide", accessibilityLabel: "Open guide", action: onGuide)
                            PlayerChromeButton(systemImage: "clock.arrow.circlepath", accessibilityLabel: "Recent channels", action: onRecents)
                        }
                        PlayerChromeButton(
                            systemImage: isLandscapeGameCentreVisible ? "sidebar.right" : "chart.bar.xaxis",
                            accessibilityLabel: "Toggle game information"
                        ) {
                            withAnimation(.snappy) { isLandscapeGameCentreVisible.toggle() }
                        }
                    }
                    .padding(.bottom, 26)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if isLandscapeGameCentreVisible {
                LandscapeGameCentrePanel(match: match, sport: sport)
                    .frame(maxWidth: 310)
                    .padding(.trailing, 14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

private struct PlayerVideoContainer<VideoContent: View>: View {
    let channel: Channel
    let match: Match?
    let sport: StadiaSport
    let isChromeVisible: Bool
    let streamSummary: String
    let orientation: PlayerOrientation
    let onDismiss: () -> Void
    let onMore: () -> Void
    let onSourceSelector: () -> Void
    let onCycleSource: (Int) -> Void
    let onToggleOrientation: () -> Void
    let videoContent: VideoContent

    init(
        channel: Channel,
        match: Match?,
        sport: StadiaSport,
        isChromeVisible: Bool,
        streamSummary: String,
        orientation: PlayerOrientation,
        onDismiss: @escaping () -> Void,
        onMore: @escaping () -> Void,
        onSourceSelector: @escaping () -> Void,
        onCycleSource: @escaping (Int) -> Void,
        onToggleOrientation: @escaping () -> Void,
        @ViewBuilder videoContent: () -> VideoContent
    ) {
        self.channel = channel
        self.match = match
        self.sport = sport
        self.isChromeVisible = isChromeVisible
        self.streamSummary = streamSummary
        self.orientation = orientation
        self.onDismiss = onDismiss
        self.onMore = onMore
        self.onSourceSelector = onSourceSelector
        self.onCycleSource = onCycleSource
        self.onToggleOrientation = onToggleOrientation
        self.videoContent = videoContent()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                videoContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.66), .clear, .black.opacity(0.55)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    if isChromeVisible {
                        PlayerTopOverlay(
                            title: match?.shortName ?? channel.name,
                            subtitle: streamSummary,
                            orientation: orientation,
                            onDismiss: onDismiss,
                            onMore: onMore,
                            onToggleOrientation: onToggleOrientation
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, max(proxy.safeAreaInsets.top, 8) + 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer()

                    VStack(spacing: 8) {
                        if let match {
                            LiveScoreBug(match: match, sport: sport)
                                .padding(.horizontal, 18)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }

                        if isChromeVisible {
                            PlayerBottomOverlay(
                                channel: channel,
                                streamSummary: streamSummary,
                                onSourceSelector: onSourceSelector,
                                onCycleSource: onCycleSource,
                                onMore: onMore
                            )
                            .padding(.horizontal, 14)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 8) + 4)
                }
            }
        }
        .background(Color.black)
    }
}

private struct PlayerTopOverlay: View {
    let title: String
    let subtitle: String
    let orientation: PlayerOrientation
    let onDismiss: () -> Void
    let onMore: () -> Void
    let onToggleOrientation: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PlayerChromeButton(systemImage: "chevron.backward", accessibilityLabel: "Back", action: onDismiss)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            #if os(iOS)
            AirPlayButton()
                .frame(width: 42, height: 38)
                .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
            #endif

            PlayerChromeButton(systemImage: orientation.systemImage, accessibilityLabel: orientation.accessibilityLabel, action: onToggleOrientation)
            PlayerChromeButton(systemImage: "ellipsis", accessibilityLabel: "More options", action: onMore)
        }
    }
}

private struct PlayerBottomOverlay: View {
    let channel: Channel
    let streamSummary: String
    let onSourceSelector: () -> Void
    let onCycleSource: (Int) -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 6) {
                PulsingDot(color: Theme.live)
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(Theme.live.opacity(0.82), in: Capsule())

            Text(compactChannelName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)

            Button(action: onSourceSelector) {
                HStack(spacing: 5) {
                    Text(streamSummary)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.heavy))
                }
                .foregroundStyle(.white)
                .frame(height: 32)
                .padding(.horizontal, 9)
                .background(.white.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose stream source, \(streamSummary)")
            #if os(iOS)
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 34 else { return }
                        onCycleSource(value.translation.width < 0 ? 1 : -1)
                    }
            )
            #endif

            Spacer(minLength: 4)

            Button(action: onMore) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 32)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Player options")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private var compactChannelName: String {
        channel.name
            .replacingOccurrences(of: #"^[A-Z]{2,4}\s*[★*⭐]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(HD|FHD|UHD|4K)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct LiveScoreBug: View {
    let match: Match
    let sport: StadiaSport

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                scoreTeam(match.away, alignment: .leading)
                Text(match.away.score ?? "0")
                    .font(.title3.weight(.black).monospacedDigit())
                Text("–")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.44))
                Text(match.home.score ?? "0")
                    .font(.title3.weight(.black).monospacedDigit())
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
                        PulsingDot(color: Theme.live)
                        Text("LIVE")
                    }
                    .font(.caption2.weight(.heavy))
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
        .accessibilityLabel("\(match.away.abbreviation) \(match.away.score ?? "0"), \(match.home.abbreviation) \(match.home.score ?? "0"), \(scoreState)")
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
        .font(.subheadline.weight(.black))
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
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(match?.state == .live ? Theme.live : Theme.textSecondary)
                if match?.state == .live {
                    PulsingDot(color: Theme.live)
                }
            }

            Text(match?.name ?? channel.name)
                .font(match == nil ? .headline.weight(.heavy) : .title3.weight(.heavy))
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
                        withAnimation(.snappy) { selection = tab }
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

private struct SportGameCentre: View {
    let match: Match?
    let state: PlayerMatchResolutionState
    let sport: StadiaSport
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if !state.isPending {
                        Button("Find match") {}
                            .font(.caption.weight(.bold))
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                            .disabled(true)
                    }
                }
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
                ("Inning", match?.liveContext.baseball?.inning ?? match?.statusDetail),
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
                ("Period", match?.liveContext.hockey?.period ?? match?.liveContext.period?.displayName ?? match?.statusDetail),
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
                    ("Quarter", match?.liveContext.basketball?.quarter ?? match?.statusDetail),
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
                .font(.caption.weight(.heavy))
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
                    .font(.system(.title, design: .rounded, weight: .black).monospacedDigit())
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
                .font(.subheadline.weight(.heavy))
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
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(.uppercase)
                        Text(item.1)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

private struct TeamStatsPlaceholder: View {
    let match: Match?
    let sport: StadiaSport

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
    let sport: StadiaSport

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
    let sport: StadiaSport
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
    let sport: StadiaSport
    var body: some View {
        GameCentreCard(title: sport == .hockey ? "Lineups" : "Lineups") {
            if let formations = match?.liveContext.formations, !formations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(formations) { formation in
                        Text([formation.teamAbbreviation, formation.formationName].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Theme.textPrimary)
                        ForEach(formation.groups) { group in
                            Text(group.title)
                                .font(.caption.weight(.heavy))
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
                                    .font(.subheadline.weight(.heavy))
                                    .foregroundStyle(Theme.textPrimary)
                                if drive.isCurrent {
                                    Text("LIVE")
                                        .font(.caption2.weight(.heavy))
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
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    let sport: StadiaSport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(panelTitle)
                .font(.caption.weight(.heavy))
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))
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
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                    Text(first.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Text(first.stats.first?.value ?? "")
                    .font(.title3.weight(.black).monospacedDigit())
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
                .font(.caption.weight(.heavy).monospacedDigit())
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

private enum PlaybackQuality: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var id: String { rawValue }

    var peakBitRate: Double {
        switch self {
        case .auto: return 0
        case .high: return 8_000_000
        case .medium: return 3_000_000
        case .low: return 1_000_000
        }
    }
}

private struct StreamQualityMenu: View {
    @ObservedObject var selection: StreamSelectionState
    let onSelect: () -> Void

    var body: some View {
        Menu {
            Section("Stream Quality") {
                Button {
                    selection.selectAuto()
                    onSelect()
                } label: {
                    menuLabel(title: "Auto", detail: selection.autoSummary, isSelected: selection.mode == .auto)
                }
            }

            Section("Available Streams") {
                ForEach(selection.displayCandidates) { candidate in
                    Button {
                        selection.selectManual(streamID: candidate.stream.id)
                        onSelect()
                    } label: {
                        let selected = selection.mode == .manual(candidate.stream.id)
                        menuLabel(title: candidate.primaryLabel,
                                  detail: streamDetail(for: candidate),
                                  isSelected: selected)
                    }
                    .disabled(candidate.health == .unavailable)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline.weight(.bold))
                Text(streamButtonTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(height: 42)
            .padding(.horizontal, 13)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .accessibilityLabel("Stream quality: \(streamButtonTitle)")
    }

    private var streamButtonTitle: String {
        switch selection.mode {
        case .auto:
            return "Auto"
        case .manual(let streamID):
            guard let candidate = selection.displayCandidates.first(where: { $0.stream.id == streamID }) else { return "Stream" }
            return candidate.primaryLabel
        }
    }

    @ViewBuilder
    private func menuLabel(title: String, detail: String?, isSelected: Bool) -> some View {
        if isSelected {
            Label(detail.map { "\(title) — \($0)" } ?? title, systemImage: "checkmark")
        } else if let detail {
            Text("\(title) — \(detail)")
        } else {
            Text(title)
        }
    }

    private func streamDetail(for candidate: RankedStreamCandidate) -> String? {
        var parts: [String] = []
        if let detail = candidate.detailLabel { parts.append(detail) }
        if candidate.health != .unknown { parts.append(candidate.health.rawValue) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

private struct StreamFailurePanel: View {
    let message: String
    let tryAgain: () -> Void
    let chooseAnother: () -> Void
    let switchToAuto: () -> Void

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
                Button("Choose Another", action: chooseAnother)
                Button("Auto", action: switchToAuto)
            }
            .font(.subheadline.weight(.bold))
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(18)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
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
}

/// Plays up to four channels at once with one primary audio source.
struct MultiScreenPlayerView: View {
    let channels: [Channel]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @State private var layout: MultiScreenLayout = .twoVertical
    @State private var primaryChannelID: String?

    private var visibleChannels: [Channel] {
        Array(channels.prefix(layout.capacity))
    }

    private var activePrimaryID: String? {
        if let primaryChannelID, visibleChannels.contains(where: { $0.id == primaryChannelID }) {
            return primaryChannelID
        }
        return visibleChannels.first?.id
    }

    private var layoutOptions: [MultiScreenLayout] {
        MultiScreenLayout.options(for: channels.count)
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
            layout = MultiScreenLayout.defaultLayout(for: channels.count)
            primaryChannelID = channels.first?.id
            for channel in channels {
                watchStore.recordWatch(channel)
            }
        }
        .onChange(of: channels.count) { _, newCount in
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

            // Layout buttons — icon-only for quick switching
            HStack(spacing: 4) {
                ForEach(layoutOptions) { option in
                    Button {
                        withAnimation(.snappy) { layout = option }
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private var screenGrid: some View {
        switch layout {
        case .twoVertical:
            VStack(spacing: 0) {
                ForEach(visibleChannels) { channel in
                    tile(for: channel)
                }
            }
        case .twoHorizontal:
            HStack(spacing: 0) {
                ForEach(visibleChannels) { channel in
                    tile(for: channel)
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

    private func tile(for channel: Channel) -> some View {
        let isPrimary = channel.id == activePrimaryID
        return Button {
            primaryChannelID = channel.id
        } label: {
            StreamTile(channel: channel, isPrimary: isPrimary, showsChrome: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(
                    Rectangle()
                        .strokeBorder(isPrimary ? Theme.accent : Theme.hairline, lineWidth: isPrimary ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
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

private enum MultiScreenLayout: String, CaseIterable, Identifiable {
    case twoVertical
    case twoHorizontal
    case four

    var id: String { rawValue }

    var capacity: Int {
        switch self {
        case .twoVertical, .twoHorizontal:
            return 2
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
        case .four:
            return "rectangle.grid.2x2"
        }
    }

    static func defaultLayout(for channelCount: Int) -> MultiScreenLayout {
        channelCount > 2 ? .four : .twoVertical
    }

    static func options(for channelCount: Int) -> [MultiScreenLayout] {
        channelCount > 2 ? [.twoVertical, .twoHorizontal, .four] : [.twoVertical, .twoHorizontal]
    }
}

private struct StreamTile: View {
    let channel: Channel
    let isPrimary: Bool
    let showsChrome: Bool
    var preferredQuality: PlaybackQuality = .auto
    var bufferProfile: PlayerBufferProfile = .normal
    var onFailure: (() -> Void)? = nil
    var onMetadata: ((StreamRuntimeMetadata) -> Void)? = nil
    var onPlayerItemReady: ((AVPlayerItem) -> Void)? = nil

    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var metadataTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoSurface(player: player, showsPlaybackControls: false, allowsPictureInPicture: !showsChrome)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("Source unavailable")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsChrome {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isPrimary ? Theme.accent : Theme.textSecondary)
                        .frame(width: 7, height: 7)
                    Text(isPrimary ? "PRIMARY" : "MUTED")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.62), in: Capsule())
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
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: isPrimary) { _, newValue in
            player?.isMuted = !newValue
        }
        .onChange(of: preferredQuality) { _, quality in
            player?.currentItem?.preferredPeakBitRate = quality.peakBitRate
        }
    }

    private func start() {
        guard player == nil else { return }
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let asset = AVURLAsset(url: channel.streamURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredPeakBitRate = preferredQuality.peakBitRate
        item.preferredForwardBufferDuration = bufferProfile.forwardBufferDuration
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        player.isMuted = !isPrimary
        self.player = player
        // Start immediately; live HLS assets can be slow to report isPlayable.
        player.play()

        Task { @MainActor in
            do {
                let playable = try await asset.load(.isPlayable)
                if !playable {
                    failed = true
                    onFailure?()
                }
            } catch {
                failed = true
                onFailure?()
            }
        }

        metadataTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let item = player.currentItem else { return }
            onPlayerItemReady?(item)
            if let metadata = await StreamMetadataReader.metadata(from: item) {
                onMetadata?(metadata)
            }
        }
    }

    private func stop() {
        metadataTask?.cancel()
        player?.pause()
        player = nil
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

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
#endif

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
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("AirPlay")
            #endif
            Button(action: multiscreenAction) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(canStartMultiscreen ? .white : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if !entitlements.isPremium {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Theme.accent, in: Circle())
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
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.live, in: Capsule())
        }
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
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

    @State private var liveEntries: [LiveMatchEntry] = []
    @State private var isLoadingLive = true
    @State private var showAllSports = false
    @State private var selectedSport: SportGroup? = nil
    @State private var query = ""

    private var canStart: Bool { selectedChannelIDs.count >= 2 }
    private var isAtCapacity: Bool { selectedChannelIDs.count >= 4 }

    private var filteredEntries: [LiveMatchEntry] {
        guard let sport = selectedSport else { return liveEntries }
        return liveEntries.filter { $0.match.league.group == sport }
    }

    private func pickerSportChip(title: String, systemImage: String, sport: SportGroup?) -> some View {
        let isSelected = selectedSport == sport
        return Button {
            withAnimation(.snappy) { selectedSport = sport }
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
        "soccer/fra.1", "soccer/usa.1", "soccer/mex.1", "soccer/uefa.champions",
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
                                .font(.footnote.weight(.heavy))
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
                    ForEach(filteredChannels) { channel in
                        channelRow(for: channel)
                    }
                } header: {
                    Text("All Sources")
                        .font(.footnote.weight(.heavy))
                }
            }
            .navigationTitle("Add to Multiscreen")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        .task { await loadLiveGames() }
        .onChange(of: showAllSports) { _, _ in
            liveEntries = []
            selectedSport = nil
            isLoadingLive = true
            Task { await loadLiveGames() }
        }
    }

    @ViewBuilder
    private func channelRow(for channel: Channel) -> some View {
        Button {
            if selectedChannelIDs.contains(channel.id) {
                selectedChannelIDs.remove(channel.id)
            } else if !isAtCapacity {
                selectedChannelIDs.insert(channel.id)
            }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedChannelIDs.contains(channel.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedChannelIDs.contains(channel.id) ? Theme.accent : Theme.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(channel.id == currentChannel.id ? "Current source" : (channel.group ?? channel.playlistName))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(!selectedChannelIDs.contains(channel.id) && isAtCapacity)
    }

    private func loadLiveGames() async {
        isLoadingLive = true
        let leagues = leaguesToCheck
        let channels = allChannels
        liveEntries = []

        await withTaskGroup(of: [LiveMatchEntry].self) { group in
            for league in leagues {
                group.addTask {
                    let matches = (try? await SportsRepository.shared.legacyScoreboard(for: league)) ?? []
                    return matches.compactMap { match in
                        guard match.state == .live else { return nil }
                        let sources = Array(SourceMatcher.rank(match: match, channels: channels).prefix(4))
                        return LiveMatchEntry(match: match, sources: sources)
                    }
                }
            }

            for await entries in group where !entries.isEmpty {
                liveEntries.append(contentsOf: entries)
                liveEntries.sort(by: liveEntrySort)
            }
        }
        isLoadingLive = false
    }

    private func liveEntrySort(_ lhs: LiveMatchEntry, _ rhs: LiveMatchEntry) -> Bool {
        if lhs.match.league.group.rawValue != rhs.match.league.group.rawValue {
            return lhs.match.league.group.rawValue < rhs.match.league.group.rawValue
        }
        return lhs.match.league.name < rhs.match.league.name
    }
}

private struct LiveMatchPickerRow: View {
    let match: Match
    let sources: [RankedSource]
    @Binding var selectedIDs: Set<String>
    let isAtCapacity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // League + live status badge
            HStack(spacing: 6) {
                Text(match.league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                Label(match.statusDetail, systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.live, in: Capsule())
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
                            let isSelected = selectedIDs.contains(ch.id)
                            Button {
                                if isSelected { selectedIDs.remove(ch.id) }
                                else if !isAtCapacity { selectedIDs.insert(ch.id) }
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
                                .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline))
                            }
                            .buttonStyle(.plain)
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
            if let score = team.score {
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
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.bold))
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .frame(height: 42)
            .padding(.horizontal, title == nil ? 0 : 13)
            .frame(width: title == nil ? 42 : nil)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .playerChromeButtonStyle()
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension View {
    @ViewBuilder
    func playerChromeButtonStyle() -> some View {
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.plain)
        }
    }
}

private struct PlayerNowOnOverlay: View {
    let channelName: String
    let currentProgramme: EPGProgramme
    let nextProgramme: EPGProgramme?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(channelName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            Text("Now On: \(currentProgramme.title)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let nextProgramme {
                Text("Next: \(nextProgramme.title)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .accessibilityElement(children: .combine)
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

// MARK: - Live score badge

private struct LiveScoreBadge: View {
    let match: Match
    @Binding var isExpanded: Bool
    let onDismiss: () -> Void

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.28)) { isExpanded.toggle() }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            if isExpanded {
                expandedBadge
            } else {
                collapsedBadge
            }
        }
        .buttonStyle(.plain)
    }

    private var collapsedBadge: some View {
        HStack(spacing: 6) {
            PulsingDot(color: Theme.live)
            Text("\(match.away.abbreviation) \(match.away.score ?? "0") – \(match.home.score ?? "0") \(match.home.abbreviation)")
                .font(.caption.weight(.heavy).monospacedDigit())
                .foregroundStyle(.white)
            if !match.statusDetail.isEmpty {
                Text("·").foregroundStyle(.white.opacity(0.45))
                Text(match.statusDetail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.74), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }

    private var expandedBadge: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                PulsingDot(color: Theme.live)
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.live)
                Spacer()
                Text(match.statusDetail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Button {
                    onDismiss()
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 0) {
                scoreTeam(match.away)
                Text("–")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                scoreTeam(match.home)
            }
        }
        .padding(14)
        .frame(minWidth: 210)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }

    private func scoreTeam(_ team: TeamSide) -> some View {
        VStack(spacing: 3) {
            TeamLogo(url: team.logoURL, size: 32)
            Text(team.abbreviation)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.65))
            Text(team.score ?? "0")
                .font(.title.weight(.black).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(pulsing ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Buffer Profile

enum PlayerBufferProfile: String, CaseIterable, Identifiable {
    case small = "Small"
    case normal = "Normal"
    case large = "Large"

    var id: String { rawValue }

    var forwardBufferDuration: TimeInterval {
        switch self {
        case .small: return 2
        case .normal: return 10
        case .large: return 30
        }
    }

    var description: String {
        switch self {
        case .small: return "Fastest channel switching"
        case .normal: return "Balanced (default)"
        case .large: return "Most stable playback"
        }
    }
}

// MARK: - Player Control Bar

private struct PlayerControlBar: View {
    let hasPrev: Bool
    let hasNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void
    let onGuide: (() -> Void)?
    let onChannels: (() -> Void)?
    let onRecent: (() -> Void)?
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if hasPrev {
                PlayerChromeButton(systemImage: "chevron.up", accessibilityLabel: "Previous channel", action: onPrev)
            }
            if hasNext {
                PlayerChromeButton(systemImage: "chevron.down", accessibilityLabel: "Next channel", action: onNext)
            }
            if (hasPrev || hasNext) && (onGuide != nil || onChannels != nil || onRecent != nil) {
                Divider().frame(height: 28).overlay(Theme.hairline)
            }
            if let onGuide {
                PlayerChromeButton(systemImage: "rectangle.grid.1x2.fill", title: "Guide", accessibilityLabel: "Open guide", action: onGuide)
            }
            if let onChannels {
                PlayerChromeButton(systemImage: "list.bullet", title: "Channels", accessibilityLabel: "Channel list", action: onChannels)
            }
            if let onRecent {
                PlayerChromeButton(systemImage: "clock.arrow.circlepath", title: "Recent", accessibilityLabel: "Recent channels", action: onRecent)
            }
            Spacer()
            PlayerChromeButton(systemImage: "ellipsis", title: "More", accessibilityLabel: "More options", action: onMore)
        }
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Player More Sheet

private struct PlayerMoreSheet: View {
    let channel: Channel
    @ObservedObject var streamSelection: StreamSelectionState
    @Binding var bufferProfile: PlayerBufferProfile
    let audioGroup: AVMediaSelectionGroup?
    @Binding var selectedAudioIndex: Int?
    let subtitleGroup: AVMediaSelectionGroup?
    @Binding var selectedSubtitleIndex: Int?
    let streamMetadata: StreamRuntimeMetadata?
    let canStartMultiscreen: Bool
    let multiscreenAction: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var entitlements: EntitlementStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    optionsHeader

                    PlayerOptionSection(title: "Playback") {
                        #if os(iOS)
                        HStack {
                            PlayerOptionLabel(systemImage: "airplayvideo", title: "AirPlay", subtitle: "Cast to nearby screens")
                            Spacer()
                            AirPlayButton().frame(width: 46, height: 34)
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
                        NavigationLink {
                            StreamSourceSelectionView(selection: streamSelection)
                        } label: {
                            OptionRowContent(systemImage: "dot.radiowaves.left.and.right", title: "Source", subtitle: nil, value: streamSelection.currentSummary, showsChevron: true)
                        }

                        NavigationLink {
                            StreamQualitySelectionView(metadata: streamMetadata)
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

                    PlayerOptionSection(title: "Picture") {
                        OptionRowContent(systemImage: "rectangle.arrowtriangle.2.inward", title: "Fit", subtitle: "Preserve stream aspect ratio", value: "Aspect", showsChevron: false)
                    }

                    if let diagnostics = diagnosticsSummary {
                        PlayerOptionSection(title: "Stream Summary") {
                            Text(diagnostics)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Options")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private var optionsHeader: some View {
        HStack(spacing: 12) {
            AsyncImage(url: channel.logoURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFit()
                } else {
                    Image(systemName: "play.tv.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 48, height: 48)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(channel.group ?? channel.playlistName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("LIVE")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.live, in: Capsule())
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var qualitySummary: String {
        guard let streamMetadata else { return "Auto" }
        var parts: [String] = []
        if let width = streamMetadata.width, let height = streamMetadata.height, width > 0, height > 0 {
            parts.append("\(height)p")
        }
        if let frameRate = streamMetadata.frameRate, frameRate > 0 {
            parts.append(String(format: "%.0f fps", frameRate))
        }
        return parts.isEmpty ? "Auto" : parts.joined(separator: " · ")
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

private struct PlayerOptionLabel: View {
    let systemImage: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

private struct OptionRowContent: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    let value: String?
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 12) {
            PlayerOptionLabel(systemImage: systemImage, title: title, subtitle: subtitle)
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
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

private struct StreamQualitySelectionView: View {
    let metadata: StreamRuntimeMetadata?

    var body: some View {
        SelectionList(title: "Quality") {
            SelectionRow(title: "Auto", subtitle: currentDetail ?? "Use the best available stream", isSelected: true)
        }
    }

    private var currentDetail: String? {
        guard let metadata else { return nil }
        var parts: [String] = []
        if let width = metadata.width, let height = metadata.height, width > 0, height > 0 {
            parts.append("\(width)x\(height)")
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
            VStack(spacing: 10) {
                content
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct SelectionRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isSelected ? Theme.accent.opacity(0.38) : Theme.hairline))
    }
}

// MARK: - Player Channel List Sheet

private struct PlayerChannelListSheet: View {
    let channels: [Channel]
    let currentChannelID: String
    let onSelect: (Channel, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(channels.enumerated()), id: \.element.id) { index, ch in
                    Button {
                        onSelect(ch, index)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: ch.logoURL) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFit() }
                                else { Image(systemName: "play.tv.fill").font(.title3).foregroundStyle(Theme.accent) }
                            }
                            .frame(width: 38, height: 38)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 6))
                            Text(ch.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer()
                            if ch.id == currentChannelID {
                                Image(systemName: "play.fill").foregroundStyle(Theme.accent).font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(ch.id == currentChannelID ? Theme.accent.opacity(0.12) : Theme.surface)
                }
            }
            .listStyle(.plain)
            .hidesScrollContentBackground()
            .navigationTitle("Channels")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
    }
}

// MARK: - Player Recents Sheet

private struct PlayerRecentsSheet: View {
    let currentChannelID: String
    let onSelect: (Channel) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore

    var body: some View {
        NavigationStack {
            Group {
                if watchStore.recents.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(Theme.textSecondary)
                        Text("No recent channels yet").font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                } else {
                    List {
                        ForEach(watchStore.recents) { entry in
                            if let ch = entry.saved.channel {
                                Button {
                                    onSelect(ch)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        AsyncImage(url: ch.logoURL) { phase in
                                            if case .success(let img) = phase { img.resizable().scaledToFit() }
                                            else { Image(systemName: "play.tv.fill").font(.title3).foregroundStyle(Theme.accent) }
                                        }
                                        .frame(width: 38, height: 38)
                                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 6))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ch.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                            Text(relativeTime(entry.watchedAt)).font(.caption).foregroundStyle(Theme.textSecondary)
                                        }
                                        Spacer()
                                        if ch.id == currentChannelID {
                                            Image(systemName: "play.fill").foregroundStyle(Theme.accent).font(.caption)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(ch.id == currentChannelID ? Theme.accent.opacity(0.12) : Theme.surface)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .hidesScrollContentBackground()
                }
            }
            .navigationTitle("Recent Channels")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                        .foregroundStyle(Color(hex: 0xFFD700))
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
                .background(Theme.accent, in: Capsule())
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
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        )
        .transition(.opacity.combined(with: .scale(scale: 0.88)))
    }
}
#endif
