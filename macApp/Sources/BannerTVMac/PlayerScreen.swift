import AppKit
import BannerCore
import BannerPlayer
import SwiftUI

/// The full-window player: video, a back button, and controls that fade after a few seconds of stillness.
struct PlayerScreen: View {
    let request: PlaybackRequest
    @EnvironmentObject private var router: Router
    @StateObject private var player = MPVPlayer()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var addedSubtitles = false
    @State private var lastSaved: Double = 0

    var body: some View {
        ZStack {
            Color.black
            MPVVideoSurface(player: player)
            if case .failed(let message) = player.phase {
                VStack(spacing: 12) {
                    Text("This source could not be played").font(.jb(20, .bold))
                    Text(message).foregroundStyle(Theme.textSecondary)
                    Button("Choose Another Source") { close() }.buttonStyle(PillButtonStyle(kind: .primary, height: 44))
                }
                .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else if player.phase == .loading || player.phase == .buffering {
                ProgressView().controlSize(.large)
            }
            VStack {
                if controlsVisible { topBar }
                Spacer()
                if controlsVisible { controls }
            }
            .transition(.opacity)
        }
        .ignoresSafeArea()
        .onContinuousHover { _ in wake() }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onTapGesture { player.togglePause(); wake() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { player.togglePause(); wake(); return .handled }
        .onKeyPress(.leftArrow) { player.seek(by: -10); wake(); return .handled }
        .onKeyPress(.rightArrow) { player.seek(by: 10); wake(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress("f") { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        .onAppear {
            let prefs = PlaybackPreferences.current
            player.applyPreferences(audioLanguages: prefs.audio, subtitleLanguages: prefs.subtitle, subtitleScale: prefs.subtitleScale)
            guard let url = request.source.url, url.scheme == "http" || url.scheme == "https" else { close(); return }
            player.load(url, headers: request.source.headers, startAt: request.startAt)
            wake()
            if CommandLine.arguments.contains("--debug-player") { debugLoop() }
        }
        .onDisappear { saveProgress(final: true); serializdStopped(); player.stop() }
        .onChange(of: player.phase) { _, phase in
            if phase == .ended, !request.isLive, !request.upcoming.isEmpty { playNext() }
            if phase == .playing, !addedSubtitles {
                addedSubtitles = true
                for sub in request.source.subtitles.prefix(8) { player.addExternalSubtitle(sub.url, title: sub.name, language: sub.language) }
            }
        }
        .onChange(of: player.position) { _, position in
            if abs(position - lastSaved) >= 15 { saveProgress(final: false) }
            serializdSample(position: position)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { close() } label: { Image(systemName: "chevron.left") }.buttonStyle(GlassCircleButtonStyle(size: 46))
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.jb(20, .bold))
                if let s = request.subtitle { Text(s).font(.jb(14)).foregroundStyle(.white.opacity(0.7)) }
            }
            Spacer()
        }
        .padding(.leading, 92).padding(.trailing, 24).padding(.top, 18).padding(.bottom, 36)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if !request.isLive {
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                    .tint(.white)
            }
            HStack(spacing: 18) {
                Button { player.togglePause() } label: { Image(systemName: player.isPaused ? "play.fill" : "pause.fill").frame(width: 24) }
                if request.isLive {
                    Label("LIVE", systemImage: "circle.fill").font(.jb(12, .bold)).foregroundStyle(.red)
                } else {
                    Button { player.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                    Button { player.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                    Text("\(format(player.position)) / \(format(player.duration))").monospacedDigit().font(.jb(14))
                }
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in Button("\(s, specifier: "%g")x") { player.setSpeed(s) } }
                } label: { Image(systemName: "speedometer") }.fixedSize()
                Menu {
                    ForEach(player.tracks.filter { $0.kind == .audio }) { track in Button(track.title + (track.isSelected ? "  ✓" : "")) { player.selectTrack(track) } }
                } label: { Image(systemName: "waveform") }.fixedSize()
                Menu {
                    Button("Off") { player.disableSubtitles() }
                    ForEach(player.tracks.filter { $0.kind == .sub }) { track in Button(track.title + (track.isSelected ? "  ✓" : "")) { player.selectTrack(track) } }
                } label: { Image(systemName: "captions.bubble") }.fixedSize()
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...100).frame(width: 90).tint(.white)
                if !request.upcoming.isEmpty && !request.isLive {
                    Button { playNext() } label: { Label("Next Episode", systemImage: "forward.end.fill").font(.jb(14)) }
                }
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            }
            .buttonStyle(.plain).font(.title3)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 32).padding(.bottom, 26)
    }

    private func close() { router.closePlayer() }

    /// Moves on to the next episode, picking the same add-on's source automatically.
    private func playNext() {
        guard let next = request.upcoming.first else { return }
        saveProgress(final: true)
        let rest = Array(request.upcoming.dropFirst())
        router.closePlayer()
        router.sourceTarget = SourceTarget(ref: request.ref, videoId: next.id, title: request.title,
                                           subtitle: "S\(next.season) E\(next.number)  \(next.title)", next: rest.first, upcoming: rest,
                                           season: next.season, episode: next.number, startAt: nil, autoPickAddon: request.source.addonId)
    }

    /// An episode of a series reports to Serializd about once a second (the shared core decides what counts as finished). Movies and live TV never do.
    private func serializdSample(position: Double) {
        // A movie reports to Letterboxd the same way (the shared core decides what counts as finished).
        if !request.isLive, request.ref.type == "movie", player.duration > 0 {
            MacLetterboxd.shared.onPlayback(
                metaId: request.ref.id, title: request.ref.name, poster: request.ref.poster?.absoluteString,
                positionSeconds: position, durationSeconds: player.duration, isPlaying: !player.isPaused && player.phase == .playing, isEnded: player.phase == .ended
            )
        }
        guard !request.isLive, request.ref.type == "series", let season = request.season, let episode = request.episode, player.duration > 0 else { return }
        MacSerializd.shared.onPlayback(
            metaId: request.ref.id, season: Int32(season), episode: Int32(episode), showName: request.ref.name, episodeTitle: request.subtitle,
            poster: request.ref.poster?.absoluteString, positionSeconds: position, durationSeconds: player.duration,
            isPlaying: !player.isPaused && player.phase == .playing, isEnded: player.phase == .ended
        )
    }

    private func serializdStopped() {
        if !request.isLive, request.ref.type == "movie" { MacLetterboxd.shared.onPlaybackStopped(metaId: request.ref.id) }
        guard !request.isLive, request.ref.type == "series", let season = request.season, let episode = request.episode else { return }
        MacSerializd.shared.onPlaybackStopped(metaId: request.ref.id, season: Int32(season), episode: Int32(episode))
    }

    private func saveProgress(final: Bool) {
        guard !request.isLive, player.duration > 0, player.position > 1 else { return }
        lastSaved = player.position
        PlaybackRecorder.record(request: request, position: player.position, duration: player.duration, final: final)
    }

    private func wake() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, !player.isPaused { withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false } }
        }
    }

    private func debugLoop() {
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                FileHandle.standardError.write(Data(("[player] " + player.diagnosticSnapshot() + "\n").utf8))
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Where playback progress goes. The account's watch progress hooks in here (slice: Continue Watching).
enum PlaybackRecorder {
    static var sink: ((PlaybackRequest, Double, Double, Bool) -> Void)?
    static func record(request: PlaybackRequest, position: Double, duration: Double, final: Bool) {
        sink?(request, position, duration, final)
    }
}
