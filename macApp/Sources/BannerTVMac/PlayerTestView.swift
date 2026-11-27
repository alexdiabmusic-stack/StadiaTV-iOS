import BannerPlayer
import SwiftUI

/// Player bring-up: enter or pass a stream URL, play it, and exercise the controls.
struct PlayerTestView: View {
    @StateObject private var player = MPVPlayer()
    @State private var urlText: String
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    init(initialURL: URL?) {
        _urlText = State(initialValue: initialURL?.absoluteString
            ?? "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Stream URL", text: $urlText).textFieldStyle(.roundedBorder)
                Button("Play") { start() }.keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)

            ZStack {
                MPVVideoSurface(player: player).background(Color.black)
                if case .failed(let message) = player.phase {
                    Text(message).padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
                } else if player.phase == .loading || player.phase == .buffering {
                    ProgressView()
                }
                VStack { Spacer(); if controlsVisible { controls } }
            }
            .onContinuousHover { _ in wake() }
            .onTapGesture { player.togglePause() }
        }
        .onAppear {
            if urlText.contains("://") { start() }
            // Bring-up aid: with --play the app reports mpv's state to stderr every two seconds.
            if CommandLine.arguments.contains("--play") {
                Task { @MainActor in
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .seconds(2))
                        FileHandle.standardError.write(Data(("[player] " + player.diagnosticSnapshot() + "\n").utf8))
                    }
                }
            }
        }
        .focusable()
        .onKeyPress(.space) { player.togglePause(); return .handled }
        .onKeyPress(.leftArrow) { player.seek(by: -10); return .handled }
        .onKeyPress(.rightArrow) { player.seek(by: 10); return .handled }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
            HStack(spacing: 16) {
                Button { player.togglePause() } label: { Image(systemName: player.isPaused ? "play.fill" : "pause.fill") }
                Text("\(format(player.position)) / \(format(player.duration))").monospacedDigit()
                Spacer()
                Menu("Audio") {
                    ForEach(player.tracks.filter { $0.kind == .audio }) { track in
                        Button(track.title) { player.selectTrack(track) }
                    }
                }.fixedSize()
                Menu("Subtitles") {
                    Button("Off") { player.disableSubtitles() }
                    ForEach(player.tracks.filter { $0.kind == .sub }) { track in
                        Button(track.title) { player.selectTrack(track) }
                    }
                }.fixedSize()
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...100).frame(width: 90)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .transition(.opacity)
    }

    private func start() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return }
        player.load(url)
        wake()
    }

    /// Shows the controls on any mouse movement and hides them (and the cursor) after a few seconds of stillness.
    private func wake() {
        withAnimation { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, !player.isPaused { withAnimation { controlsVisible = false } }
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
