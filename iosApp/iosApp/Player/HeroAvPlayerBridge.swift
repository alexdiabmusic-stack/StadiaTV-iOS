import AVFoundation
import ComposeApp
import UIKit

/// Hosts an AVPlayerLayer that fills its superview.
private final class HeroAvPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerLayer.videoGravity = .resizeAspectFill
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

/// The trailer player: AVPlayer (VideoToolbox hardware decode) instead of the full libmpv engine.
///
/// Muted and silent until the first frame is on screen, so a clip's audio can never play over the poster. A separate audio URL
/// (YouTube's adaptive streams) runs in a second AVPlayer that follows the video's clock and is re-synced when it drifts.
/// googlevideo.com URLs are fetched in 10 MB pieces by `YouTubeChunkedResourceLoader`, which avoids the CDN's throttling of
/// long single requests.
final class HeroAvPlayerBridgeImpl: NSObject, HeroPlayerBridge {
    private let videoItem: AVPlayerItem
    private let videoPlayer: AVPlayer
    private let audioItem: AVPlayerItem?
    private let audioPlayer: AVPlayer?
    private let view = HeroAvPlayerView()
    private var chunkedLoaders: [YouTubeChunkedResourceLoader] = []
    private var endObserver: Any?
    private var syncTimer: Timer?

    private var desiredMute = true
    private var wantsPlaying = true
    private var ready = false
    private var failed = false
    private var ended = false
    private var audioStarted = false
    private var advancingSince: CFAbsoluteTime = 0

    init(videoUrl: String, audioUrl: String?) {
        var loaders: [YouTubeChunkedResourceLoader] = []
        func makeItem(_ string: String) -> AVPlayerItem? {
            if let (asset, loader) = YouTubeChunkedResourceLoader.makeAsset(for: string) {
                loaders.append(loader)
                return AVPlayerItem(asset: asset)
            }
            guard let url = URL(string: string) else { return nil }
            return AVPlayerItem(url: url)
        }
        let video = makeItem(videoUrl)
        let audio = audioUrl.flatMap { $0.isEmpty ? nil : makeItem($0) }
        videoItem = video ?? AVPlayerItem(url: URL(string: "about:blank")!)
        videoPlayer = AVPlayer(playerItem: videoItem)
        audioItem = audio
        audioPlayer = audio.map { AVPlayer(playerItem: $0) }
        super.init()
        chunkedLoaders = loaders
        failed = (video == nil)

        for player in [videoPlayer, audioPlayer].compactMap({ $0 }) {
            player.isMuted = true
            player.volume = 0
            // A muted background clip should start fast; a brief stall is better than waiting for an ideal buffer.
            player.automaticallyWaitsToMinimizeStalling = false
        }
        videoItem.allowedAudioSpatializationFormats = []
        audioItem?.allowedAudioSpatializationFormats = []
        view.playerLayer.player = videoPlayer

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: videoItem, queue: .main) { [weak self] _ in
            self?.ended = true
        }
        if !failed { videoPlayer.play() }
        if audioPlayer != nil { startSyncTimer() }
    }

    deinit { teardown() }

    // MARK: audio follows video

    private func startSyncTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tickAudio() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    private func tickAudio() {
        guard let audioPlayer, let audioItem, videoItem.status == .readyToPlay, audioItem.status == .readyToPlay else { return }
        if !audioStarted {
            audioPlayer.isMuted = desiredMute
            audioPlayer.volume = desiredMute ? 0 : 1
            audioPlayer.seek(to: videoPlayer.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self, self.wantsPlaying else { return }
                audioPlayer.play()
                self.audioStarted = true
            }
            return
        }
        guard videoPlayer.rate > 0 else { return }
        let video = CMTimeGetSeconds(videoPlayer.currentTime()), audio = CMTimeGetSeconds(audioPlayer.currentTime())
        guard video.isFinite, audio.isFinite, abs(audio - video) > 0.3 else { return }
        audioPlayer.seek(to: videoPlayer.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: HeroPlayerBridge

    func createView() -> UIView { view }

    func releasePlayer() { teardown() }

    private func teardown() {
        syncTimer?.invalidate(); syncTimer = nil
        videoPlayer.pause(); videoPlayer.replaceCurrentItem(with: nil)
        audioPlayer?.pause(); audioPlayer?.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
    }

    func isReady() -> Bool {
        if ready { return true }
        guard videoItem.status == .readyToPlay else { return false }
        let advancing = CMTimeGetSeconds(videoPlayer.currentTime()) > 0.05
        let laidOut = view.bounds.width > 0 || (view.superview?.bounds.width ?? 0) > 0
        guard advancing, laidOut else { return false }
        // isReadyForDisplay can lag the first frame on some streams: after 1.5 s of advancing time the decoder is clearly working.
        if view.playerLayer.isReadyForDisplay { markReady(); return true }
        let now = CFAbsoluteTimeGetCurrent()
        if advancingSince == 0 { advancingSince = now } else if now - advancingSince > 1.5 { markReady(); return true }
        return false
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        applyMute()
    }

    private func applyMute() {
        if audioPlayer != nil {
            if audioStarted { audioPlayer?.isMuted = desiredMute; audioPlayer?.volume = desiredMute ? 0 : 1 }
            videoPlayer.isMuted = true; videoPlayer.volume = 0
        } else if ready {
            videoPlayer.isMuted = desiredMute; videoPlayer.volume = desiredMute ? 0 : 1
        }
    }

    func isFailed() -> Bool {
        if failed { return true }
        failed = videoItem.status == .failed || videoPlayer.status == .failed
        return failed
    }

    func isEnded() -> Bool { ended }

    #if DEBUG
    var debugError: String { "item=\(String(describing: videoItem.error)) player=\(String(describing: videoPlayer.error)) status=\(videoItem.status.rawValue)" }
    #endif

    func setMuted(muted: Bool) {
        desiredMute = muted
        if !muted {
            // Sound for a trailer plays like any media; a muted clip never touches the audio session.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true, options: [])
        }
        applyMute()
    }

    func setPlaying(playing: Bool) {
        wantsPlaying = playing
        guard !failed else { return }
        if playing {
            videoPlayer.play()
            if audioStarted { audioPlayer?.play() }
        } else {
            videoPlayer.pause()
            audioPlayer?.pause()
        }
    }

    func getPositionMs() -> Int64 {
        let seconds = CMTimeGetSeconds(videoPlayer.currentTime())
        return seconds.isFinite ? Int64(max(0, seconds) * 1000) : 0
    }

    func seekToMs(positionMs: Int64) {
        let target = CMTime(seconds: Double(positionMs) / 1000, preferredTimescale: 600)
        videoPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        audioPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

final class HeroAvPlayerBridgeCreator: NSObject, HeroPlayerBridgeCreator {
    func create(videoUrl: String, audioUrl: String?) -> any HeroPlayerBridge {
        HeroAvPlayerBridgeImpl(videoUrl: videoUrl, audioUrl: audioUrl)
    }
}
