import SwiftUI
import AVKit
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import MediaPlayer
#endif

/// Presents a channel's stream full screen.
struct PlayerView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var prefs: PreferencesStore
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
    @State private var showPaywall = false
    @State private var preferredQuality: PlaybackQuality = .auto

    // Sorting and deduping a big playlist is expensive, so it runs once off
    // the main thread instead of inside every body evaluation.
    @State private var multiscreenChannels: [Channel] = []

    private var canStartMultiscreen: Bool {
        playlistStore.channelsByPlaylist.values.contains { channels in
            channels.contains { $0.id != channel.id }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            StreamTile(channel: channel, isPrimary: true, showsChrome: false, preferredQuality: preferredQuality)
                .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        #if os(iOS)
        .overlay { playerGestureZones }
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
            if let match = liveScoreMatch, prefs.showLiveScoreBadge, !isScoreDismissed {
                LiveScoreBadge(match: match, isExpanded: $isScoreExpanded) {
                    withAnimation(.spring(duration: 0.28)) { isScoreDismissed = true }
                }
                .padding(.top, isChromeVisible ? 68 : 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: liveScoreMatch?.id)
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
            if isChromeVisible {
                PlayerChromeButton(systemImage: "chevron.backward", title: "Back", accessibilityLabel: "Back") {
                    dismiss()
                }
                .padding(.top, 16)
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isChromeVisible {
                HStack(spacing: 8) {
                    #if os(iOS)
                    Menu {
                        ForEach(PlaybackQuality.allCases) { quality in
                            Button {
                                preferredQuality = quality
                                revealChromeTemporarily()
                            } label: {
                                if preferredQuality == quality {
                                    Label(quality.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(quality.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.headline.weight(.bold))
                            Text(preferredQuality.rawValue)
                                .font(.subheadline.weight(.bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .frame(height: 42)
                        .padding(.horizontal, 13)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                    }
                    .accessibilityLabel("Stream quality: \(preferredQuality.rawValue)")
                    #endif
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
        .overlay(alignment: .bottom) {
            if isChromeVisible {
                PlayerSourceBar(channel: channel,
                                canStartMultiscreen: canStartMultiscreen,
                                multiscreenAction: showMultiscreenPicker)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $isShowingMultiscreenPicker) {
            PlayerMultiscreenPicker(currentChannel: channel,
                                    allChannels: multiscreenChannels,
                                    selectedChannelIDs: $selectedMultiChannelIDs,
                                    startAction: startMultiscreen)
        }
        .fullScreenCover(item: $multiscreenSession) { session in
            MultiScreenPlayerView(channels: session.channels)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .animation(.easeInOut(duration: 0.22), value: isChromeVisible)
        .onAppear {
            watchStore.recordWatch(channel)
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
            chromeHideTask?.cancel()
            scoreFetchTask?.cancel()
            #if os(iOS)
            brightnessDragStart = nil
            volumeDragStart = nil
            #endif
            requestOrientation(.portrait)
        }
        .task(id: channel.id) {
            isScoreDismissed = false
            isScoreExpanded = false
            scoreFetchTask?.cancel()
            scoreFetchTask = Task { await findAndPollLiveMatch() }
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
    #endif

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
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            isChromeVisible = false
        }
    }

    // MARK: Live score tracking

    private func findAndPollLiveMatch() async {
        let service = ESPNService()
        let channel = self.channel
        let leaguePaths = [
            "football/nfl", "basketball/nba", "hockey/nhl", "baseball/mlb",
            "soccer/eng.1", "soccer/esp.1", "soccer/ger.1", "soccer/ita.1",
            "soccer/usa.1", "soccer/mex.1", "racing/f1"
        ]
        let leagues = leaguePaths.compactMap { path in League.all.first { $0.path == path } }

        var liveMatches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask {
                    (try? await service.scoreboard(for: league)) ?? []
                }
            }
            for await matches in group {
                liveMatches.append(contentsOf: matches.filter { $0.state == .live })
            }
        }
        guard !Task.isCancelled, !liveMatches.isEmpty else { return }

        // Pick the live match with the highest SourceMatcher score for our channel
        var bestMatch: Match? = nil
        var bestScore = 0
        for match in liveMatches {
            let score = SourceMatcher.rank(match: match, channels: [channel], preferredLanguages: []).first?.score ?? 0
            if score > bestScore { bestScore = score; bestMatch = match }
        }

        guard !Task.isCancelled, let match = bestMatch, bestScore >= 35 else { return }
        liveScoreMatch = match

        // Poll for score updates every 30 seconds
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            if let updated = try? await service.scoreboard(for: match.league).first(where: { $0.id == match.id }) {
                liveScoreMatch = updated
                if updated.state == .final { break }
            }
        }
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
#endif

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

    @State private var player: AVPlayer?
    @State private var failed = false

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
                }
            } catch {
                failed = true
            }
        }
    }

    private func stop() {
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
                    let matches = (try? await ESPNService().scoreboard(for: league)) ?? []
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
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
