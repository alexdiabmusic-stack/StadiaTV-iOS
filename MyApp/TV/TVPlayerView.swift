#if os(tvOS)
import SwiftUI
import AVKit
import UIKit

struct TVPlayerView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var prefs: PreferencesStore

    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var isChromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showMultiscreen = false
    @State private var multiscreenChannelsList: [Channel] = []
    @State private var showPaywall = false

    // Live score
    @State private var liveScoreMatch: Match?
    @State private var isScoreExpanded = false
    @State private var isScoreDismissed = false
    @State private var scoreFetchTask: Task<Void, Never>?

    private var canStartMultiscreen: Bool {
        playlistStore.channelsByPlaylist.values.contains { channels in
            channels.contains { $0.id != channel.id }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                TVVideoSurface(player: player)
                    .ignoresSafeArea()
            }
            if let match = liveScoreMatch, prefs.showLiveScoreBadge, !isScoreDismissed {
                VStack {
                    HStack(spacing: 10) {
                        TVLiveBadge()
                        Text("\(match.away.abbreviation) \(match.away.score ?? "0") – \(match.home.score ?? "0") \(match.home.abbreviation)")
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
            setupPlayer()
            watchStore.recordWatch(channel)
            revealChromeTemporarily()
        }
        .onDisappear {
            player?.pause()
            player = nil
            chromeHideTask?.cancel()
            scoreFetchTask?.cancel()
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
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()

                Button { togglePlayback() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.72), in: Circle())
                }
                .buttonStyle(.card)
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
                if canStartMultiscreen {
                    Button { startMultiscreen() } label: {
                        Label("Multiscreen", systemImage: "rectangle.split.2x1.fill")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 44)
        }
    }

    // MARK: - Helpers

    private func setupPlayer() {
        let avPlayer = AVPlayer(url: channel.streamURL)
        avPlayer.play()
        isPlaying = true
        player = avPlayer
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
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

    private func findAndPollLiveMatch() async {
        let channel = self.channel
        let leagues = ["football/nfl", "basketball/nba", "hockey/nhl", "baseball/mlb",
                       "soccer/eng.1", "soccer/esp.1", "soccer/ger.1", "soccer/ita.1",
                       "soccer/usa.1", "soccer/mex.1", "racing/f1"]
            .compactMap { path in League.all.first { $0.path == path } }

        var live: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask { (try? await SportsRepository.shared.legacyScoreboard(for: league)) ?? [] }
            }
            for await matches in group { live.append(contentsOf: matches.filter { $0.state == .live }) }
        }
        guard !Task.isCancelled, !live.isEmpty else { return }

        var best: Match?; var bestScore = 0
        for match in live {
            let s = SourceMatcher.rank(match: match, channels: [channel], preferredLanguages: []).first?.score ?? 0
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

private struct TVVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TVPlayerUIView {
        let view = TVPlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: TVPlayerUIView, context: Context) {
        view.playerLayer.player = player
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
