#if DEBUG
import Foundation
import UIKit

/// Debug aid: `-BannerHybridSelfTest <video url>` creates the hybrid bridge outside the Kotlin UI, plays the URL, pauses,
/// seeks and then forces a failure, logging each step with the prefix "HybridSelfTest". Not compiled into release builds.
@MainActor
enum HybridPlayerSelfTest {
    static func runIfRequested() {
        guard let url = UserDefaults.standard.string(forKey: "BannerHybridSelfTest"), !url.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Task { @MainActor in await run(url) } }
    }

    private static func log(_ text: String) { NSLog("HybridSelfTest %@", text) }

    private static func describe(_ bridge: HybridPlayerBridgeImpl) -> String {
        let info = (try? JSONSerialization.jsonObject(with: Data(bridge.getMediaInfoJson().utf8))) as? [String: Any] ?? [:]
        func v(_ k: String) -> String { "\(info[k] ?? "-")" }
        return "pos=\(bridge.getPositionMs())ms dur=\(bridge.getDurationMs())ms playing=\(bridge.getIsPlaying()) loading=\(bridge.getIsLoading()) ended=\(bridge.getIsEnded()) err='\(bridge.getErrorMessage())' | engine=\(v("engine")) requested=\(v("requestedEngine")) why='\(v("selectionReason"))' route=\(v("route")) rendering='\(v("rendering"))' codec=\(v("videoCodec")) \(v("videoWidth"))x\(v("videoHeight")) hdr=\(v("hdrFormat")) audio=\(v("audioCodec")) firstFrameMs=\(v("firstFrameMs")) rebuffers=\(v("rebufferCount")) fallback='\(v("fallbackReason"))' thermal=\(v("thermalState")) pipSupported=\(bridge.isPictureInPictureSupported())"
    }

    private static func mount(_ bridge: HybridPlayerBridgeImpl) {
        guard let root = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.rootViewController else { return }
        let vc = bridge.createPlayerViewController()
        root.addChild(vc)
        vc.view.frame = CGRect(x: 0, y: 120, width: 360, height: 220)
        root.view.addSubview(vc.view)
        vc.didMove(toParent: root)
    }

    static func run(_ url: String) async {
        log("start url=\(url) available=\(BannerPlaybackKitLoader.isAvailable) choice=\(PlaybackEngineChoice.stored().rawValue)")
        let bridge = HybridPlayerBridgeImpl()
        mount(bridge)
        bridge.loadFileWithAudio(videoUrl: url, audioUrl: nil, headersJson: nil, subtitlesJson: nil)
        bridge.play()
        for i in 1...12 { try? await Task.sleep(nanoseconds: 1_000_000_000); log("play t=\(i) \(describe(bridge))") }
        bridge.pause()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        log("paused \(describe(bridge))")
        bridge.seekTo(positionMs: 3000)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        log("after seek(3000) \(describe(bridge))")
        bridge.play()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        log("resumed \(describe(bridge))")
        let tracks = (bridge.getAudioTrackCount(), bridge.getSubtitleTrackCount())
        log("tracks audio=\(tracks.0) subtitles=\(tracks.1)")
        bridge.destroy()
        log("destroyed ok")

        // Forced failure: nothing listens on this port, so the first engine cannot open it.
        let failing = HybridPlayerBridgeImpl()
        mount(failing)
        failing.loadFileWithAudio(videoUrl: "http://127.0.0.1:1/missing.mp4", audioUrl: nil, headersJson: nil, subtitlesJson: nil)
        failing.play()
        for i in 1...10 { try? await Task.sleep(nanoseconds: 1_000_000_000); log("failure t=\(i) \(describe(failing))") }
        failing.destroy()

        // Trailer player (AVPlayer), muted, on the same clip.
        let heroURL = UserDefaults.standard.string(forKey: "BannerHeroSelfTestURL") ?? url
        let hero = HeroAvPlayerBridgeImpl(videoUrl: heroURL, audioUrl: nil)
        if let root = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.rootViewController {
            let v = hero.createView(); v.frame = CGRect(x: 0, y: 360, width: 360, height: 200); root.view.addSubview(v)
        }
        hero.setMuted(muted: true)
        for i in 1...6 { try? await Task.sleep(nanoseconds: 1_000_000_000); log("hero t=\(i) err=\(hero.debugError.prefix(200)) ready=\(hero.isReady()) failed=\(hero.isFailed()) ended=\(hero.isEnded()) pos=\(hero.getPositionMs())ms") }
        hero.setPlaying(playing: false)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let pausedAt = hero.getPositionMs()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        log("hero paused pos=\(pausedAt) -> \(hero.getPositionMs())")
        hero.seekToMs(positionMs: 8000); hero.setPlaying(playing: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        log("hero after seek(8000) pos=\(hero.getPositionMs())ms")
        hero.releasePlayer()
        let bad = HeroAvPlayerBridgeImpl(videoUrl: "http://127.0.0.1:1/missing.mp4", audioUrl: nil)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        log("hero bad source failed=\(bad.isFailed()) ready=\(bad.isReady())")
        bad.releasePlayer()
        log("done")
    }
}
#endif
