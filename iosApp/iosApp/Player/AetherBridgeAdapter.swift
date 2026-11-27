import BannerPlaybackContract
import ComposeApp
import Foundation
import UIKit

/// The Kotlin-facing player bridge over an AetherEngine playback surface (see BannerPlaybackKit).
///
/// Settings that only mean something to libmpv (video output tuning, night-mode filter chain, styled-overlay options) are
/// accepted and ignored here. Chapters are not provided by this engine path yet and report as
/// unsupported, so the app hides those controls instead of showing ones that do nothing.
@MainActor
final class AetherBridgeAdapter: NSObject, NuvioPlayerBridge {
    let backend: BannerPlaybackBackend
    private var lastRequest: BannerLoadRequest?
    private var preferredAudioLanguages: [String] = []
    private var subtitleDelayMs: Int32 = 0
    private var currentSubtitleHandler: SubtitleTextHandler?

    init(backend: BannerPlaybackBackend) {
        self.backend = backend
        super.init()
        backend.onSubtitleText = { [weak self] text in self?.currentSubtitleHandler?.onTextChanged(text: text) }
    }

    // MARK: lifecycle and loading

    func createPlayerViewController() -> UIViewController { backend.viewController }

    func loadFile(url: String) { loadFileWithAudio(videoUrl: url, audioUrl: nil, headersJson: nil, subtitlesJson: nil) }

    func loadFileWithAudio(videoUrl: String, audioUrl: String?, headersJson: String?, subtitlesJson: String?) {
        var request = BannerLoadRequest(
            url: videoUrl,
            headers: PlaybackRequestJSON.headers(headersJson),
            subtitles: PlaybackRequestJSON.subtitles(subtitlesJson),
            preferredAudioLanguages: preferredAudioLanguages
        )
        request.autoplay = true
        load(request)
    }

    /// Loads a prepared request (also used by the coordinator for handoffs, with a resume position).
    func load(_ request: BannerLoadRequest) {
        lastRequest = request
        backend.load(request)
    }

    func retry() {
        guard var request = lastRequest else { return }
        let position = Double(backend.snapshot.positionMs) / 1000
        request.startSeconds = position > 1 ? position : nil
        backend.load(request)
    }

    func destroy() {
        currentSubtitleHandler = nil
        backend.destroy()
    }

    // MARK: transport

    func play() { backend.play() }
    func pause() { backend.pause() }
    func seekTo(positionMs: Int64) { backend.seek(toMs: positionMs) }
    func seekBy(offsetMs: Int64) { backend.seek(toMs: max(0, backend.snapshot.positionMs + offsetMs)) }
    func setPlaybackSpeed(speed: Float) { backend.setRate(speed) }
    func getVolume() -> Float { backend.volume }
    func setVolume(volume: Float) { backend.volume = volume }
    func setMuted(muted: Bool) { backend.setMuted(muted) }
    func setResizeMode(mode: Int32) { backend.setResizeMode(Int(mode)) }
    func setVideoZoom(scale: Double) {}
    func syncVideoSurfaceLayout(width: Double, height: Double) {}
    func setEmbeddedPreviewMode(enabled: Bool) {}
    func getKeepsPlaybackInBackground() -> Bool { backend.keepsPlaybackInBackground }

    // The engine registers the system remote commands itself (one owner), so there is no handler to hand them to.
    func setSystemControlHandler(handler: PlayerSystemControlHandler?) {}
    func updateNowPlayingMetadata(title: String, subtitle: String?, artworkUrl: String?) {
        backend.setNowPlaying(title: title, subtitle: subtitle, artworkURL: artworkUrl)
    }
    func clearNowPlayingInfo() { backend.clearNowPlaying() }

    // MARK: not provided on this path

    func isPictureInPictureSupported() -> Bool { backend.isPictureInPictureSupported }
    func startPictureInPicture() { backend.startPictureInPicture() }
    func setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: Bool) {}
    func configureVideoOutput(hardwareDecoder: String, targetColorspaceHint: Bool, toneMapping: String, hdrComputePeak: Bool, targetPrimaries: String, targetTransfer: String, extendedDynamicRange: Bool, deband: Bool, interpolation: Bool, brightness: Int32, contrast: Int32, saturation: Int32, gamma: Int32) {}
    func configureAudioOutput(audioOutput: String) {}
    func setNightMode(enabled: Bool, filter: String, label: String) {}
    func isNightModeSupported() -> Bool { false }
    func setKeyboardShortcutsEnabled(enabled: Bool) {}
    func setKeyboardShortcutHandler(handler: ((String) -> Void)?) {}
    func applySubtitleStyle(textColor: String, backgroundColor: String, outlineColor: String, outlineSize: Float, bold: Bool, fontSize: Float, subPos: Int32, stripSdh: Bool, styledOverlay: Bool, outlineBlur: Int32) {}
    func getProperty(name: String) -> String { "" }

    // MARK: tracks

    private var audio: [BannerMediaTrack] { backend.audioTracks() }
    private var subtitles: [BannerMediaTrack] { backend.subtitleTracks() }

    func getAudioTrackCount() -> Int32 { Int32(audio.count) }
    func getAudioTrackIndex(at: Int32) -> Int32 { track(audio, at)?.id.asInt32 ?? 0 }
    func getAudioTrackId(at: Int32) -> String { track(audio, at).map { "\($0.id)" } ?? "0" }
    func getAudioTrackLabel(at: Int32) -> String { track(audio, at)?.label ?? "" }
    func getAudioTrackLang(at: Int32) -> String { track(audio, at)?.language ?? "" }
    func isAudioTrackSelected(at: Int32) -> Bool { track(audio, at)?.isSelected ?? false }

    func getSubtitleTrackCount() -> Int32 { Int32(subtitles.count) }
    func getSubtitleTrackIndex(at: Int32) -> Int32 { track(subtitles, at)?.id.asInt32 ?? 0 }
    func getSubtitleTrackId(at: Int32) -> String { track(subtitles, at).map { "\($0.id)" } ?? "0" }
    func getSubtitleTrackLabel(at: Int32) -> String { track(subtitles, at)?.label ?? "" }
    func getSubtitleTrackLang(at: Int32) -> String { track(subtitles, at)?.language ?? "" }
    func isSubtitleTrackSelected(at: Int32) -> Bool { track(subtitles, at)?.isSelected ?? false }

    private func track(_ list: [BannerMediaTrack], _ index: Int32) -> BannerMediaTrack? {
        let i = Int(index)
        return list.indices.contains(i) ? list[i] : nil
    }

    func selectAudioTrack(trackId: Int32) { backend.selectAudioTrack(id: Int(trackId)) }
    func selectSubtitleTrack(trackId: Int32) { backend.selectSubtitleTrack(id: Int(trackId)) }
    func applyAudioLanguagePreferences(languages: [String]) { preferredAudioLanguages = languages }

    func setSubtitleUrl(url: String) {
        backend.addExternalSubtitle(BannerSubtitleSource(url: url, language: "", name: nil, headers: nil))
    }
    func replaceExternalSubtitle(replacedUrl: String, path: String) {
        backend.addExternalSubtitle(BannerSubtitleSource(url: path, language: "", name: nil, headers: nil))
    }
    func clearExternalSubtitle() { backend.selectSubtitleTrack(id: -1) }
    func clearExternalSubtitleAndSelect(trackId: Int32) { backend.selectSubtitleTrack(id: Int(trackId)) }
    func setSubtitleDelayMs(delayMs: Int32) { subtitleDelayMs = delayMs; backend.setSubtitleDelayMs(Int(delayMs)) }
    func setSubtitleTextHandler(handler: SubtitleTextHandler?) { currentSubtitleHandler = handler }

    // MARK: state

    func getIsLoading() -> Bool { backend.snapshot.isLoading }
    func getIsPlaying() -> Bool { backend.snapshot.isPlaying }
    func getIsEnded() -> Bool { backend.snapshot.isEnded }
    func getDurationMs() -> Int64 { backend.snapshot.durationMs }
    func getPositionMs() -> Int64 { backend.snapshot.positionMs }
    func networkSpeedBytesPerSecond() -> Int64 { -1 }
    func getBufferedMs() -> Int64 { backend.snapshot.bufferedMs }
    func getPlaybackSpeed() -> Float { backend.snapshot.speed }
    func getVideoWidth() -> Int32 { Int32(backend.snapshot.videoWidth) }
    func getVideoHeight() -> Int32 { Int32(backend.snapshot.videoHeight) }
    func getErrorMessage() -> String { backend.snapshot.errorMessage }

    func getMediaInfoJson() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: backend.mediaInfo(), options: []) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private extension Int {
    var asInt32: Int32 { Int32(truncatingIfNeeded: self) }
}

/// Parses the JSON the Kotlin side sends with a load request.
enum PlaybackRequestJSON {
    static func headers(_ json: String?) -> [String: String] {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in raw { if let text = value as? String { headers[key] = text } }
        return headers
    }

    static func subtitles(_ json: String?) -> [BannerSubtitleSource] {
        guard let json, let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let url = dict["url"] as? String else { return nil }
            return BannerSubtitleSource(url: url, language: dict["language"] as? String ?? "", name: dict["name"] as? String, headers: dict["headers"] as? [String: String])
        }
    }
}
