import AppKit
import Combine
import Foundation
import Libmpv

/// One mpv instance with a Metal video surface. Ported from the iPhone player (`MPVPlayerBridge.swift`) with the
/// same video options (`vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk`, `hwdec=videotoolbox`); UIKit and
/// AVAudioSession are replaced by AppKit and mpv's CoreAudio output.
///
/// All mpv calls happen on the main thread except event reading, which runs on `eventQueue` and publishes back to main.
public final class MPVPlayer: ObservableObject {
    /// Why playback is not progressing.
    public enum Phase: Equatable {
        case idle
        case loading
        case playing
        case paused
        case buffering
        case ended
        case failed(String)
    }

    public struct Track: Identifiable, Equatable {
        public enum Kind: String { case audio, sub, video }
        public let id: Int
        public let kind: Kind
        public let title: String
        public let language: String?
        public let isSelected: Bool
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isPaused = true
    @Published public private(set) var volume: Double = 100
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var videoSize: CGSize = .zero

    /// The AppKit surface to embed (SwiftUI uses `MPVVideoSurface`).
    public let view = MPVVideoView(frame: .zero)

    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "tv.banner.mpv.events", qos: .userInitiated)
    private var generation: UInt = 0
    private var hasCustomHeaders = false

    /// The Vulkan context mpv uses. `moltenvk` is MPVKit's layer-based context (as on iPhone); override with
    /// `BANNER_MPV_CONTEXT=macvk` to try mpv's own macOS Vulkan context while diagnosing.
    private static var gpuContext: String { ProcessInfo.processInfo.environment["BANNER_MPV_CONTEXT"] ?? "moltenvk" }

    public init() {
        setUp()
    }

    deinit {
        tearDown()
    }

    // MARK: - Playback

    /// Opens a stream. `headers` are sent with every request (add-on streams and IPTV portals often need them).
    public func load(_ url: URL, headers: [String: String] = [:], startAt: Double? = nil) {
        phase = .loading
        position = 0
        duration = 0
        tracks = []
        // An empty http-header-fields makes ffmpeg send a blank header line (HTTP 400), so it is only set when needed
        // and cleared (not blanked) when a later stream has none.
        if !headers.isEmpty {
            // One header at a time: mpv splits a list option on commas, which would break values such as Cookie.
            setProperty("http-header-fields-clr", "")
            for (name, value) in headers { setProperty("http-header-fields-append", "\(name): \(value)") }
            hasCustomHeaders = true
        } else if hasCustomHeaders {
            setProperty("http-header-fields-clr", "")
            hasCustomHeaders = false
        }
        if let startAt, startAt > 1 {
            setOption("start", String(format: "%.1f", startAt))
        } else {
            setOption("start", "none")
        }
        command(["loadfile", url.absoluteString, "replace"])
    }

    /// Preferred languages (ISO 639 codes, comma separated) and subtitle size, applied to the next stream that opens.
    public func applyPreferences(audioLanguages: String?, subtitleLanguages: String?, subtitleScale: Double) {
        setOption("alang", audioLanguages ?? "")
        setOption("slang", subtitleLanguages ?? "")
        setOption("sub-scale", String(subtitleScale))
    }

    public func play() { setProperty("pause", "no") }
    public func pause() { setProperty("pause", "yes") }
    public func togglePause() { isPaused ? play() : pause() }

    public func seek(to seconds: Double) { command(["seek", String(max(0, seconds)), "absolute"]) }
    public func seek(by seconds: Double) { command(["seek", String(seconds), "relative"]) }

    public func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 200)
        setProperty("volume", String(Int(clamped)))
        volume = clamped
    }

    public func selectTrack(_ track: Track) {
        setProperty(track.kind == .audio ? "aid" : track.kind == .sub ? "sid" : "vid", String(track.id))
    }

    public func disableSubtitles() { setProperty("sid", "no") }

    /// Adds a subtitle file from a URL (from an add-on) without selecting it unless nothing else is showing.
    public func addExternalSubtitle(_ url: URL, title: String? = nil, language: String? = nil) {
        var args = ["sub-add", url.absoluteString, "auto"]
        if let title { args.append(title) } else { args.append("") }
        if let language { args.append(language) }
        command(args)
    }

    public func setSpeed(_ value: Double) { setProperty("speed", String(value)) }

    public func stop() {
        command(["stop"])
        phase = .idle
    }

    // MARK: - Setup

    private func setUp() {
        guard let handle = mpv_create() else {
            phase = .failed("mpv could not be created")
            return
        }
        mpv = handle
        generation &+= 1
        _ = mpv_request_log_messages(handle, ProcessInfo.processInfo.environment["BANNER_MPV_LOG"] ?? "warn")

        var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(view.metalLayer).toOpaque()))
        _ = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPointer)

        let options: [(String, String)] = [
            // Streams come from add-ons and IPTV providers: never run helper programs (youtube-dl) or user scripts.
            ("ytdl", "no"),
            ("load-scripts", "no"),
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", Self.gpuContext),
            ("hwdec", "videotoolbox"),
            ("hwdec-software-fallback", "300"),
            ("hwdec-extra-frames", "3"),
            ("ao", "coreaudio"),
            ("audio-channels", "auto"),
            ("audio-fallback-to-null", "yes"),
            ("volume-max", "200"),
            ("volume", "100"),
            ("vulkan-swap-mode", "fifo"),
            ("vulkan-queue-count", "1"),
            ("vulkan-async-compute", "no"),
            ("vulkan-async-transfer", "no"),
            ("video-rotate", "no"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("keep-open", "yes"),
            ("target-colorspace-hint", "yes"),
            ("tone-mapping", "auto"),
            ("hdr-compute-peak", "yes"),
            ("demuxer-max-bytes", String(128 * 1024 * 1024)),
            ("demuxer-max-back-bytes", String(64 * 1024 * 1024)),
            // Network streams only: no local file or device protocols from add-on supplied URLs.
            ("demuxer-lavf-o", "protocol_whitelist=[file,crypto,data,http,https,tcp,tls]"),
        ]
        for (name, value) in options { setOption(name, value) }
        #if DEBUG
        // Bring-up aid: BANNER_MPV_OPTS="name=value;name=value" overrides options (debug builds only).
        if let overrides = ProcessInfo.processInfo.environment["BANNER_MPV_OPTS"] {
            for pair in overrides.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { setOption(String(parts[0]), String(parts[1])) }
            }
        }
        #endif

        let status = mpv_initialize(handle)
        if status < 0 {
            phase = .failed("mpv failed to start: \(String(cString: mpv_error_string(status)))")
            return
        }

        for (name, format) in [
            ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG), ("core-idle", MPV_FORMAT_FLAG),
            ("eof-reached", MPV_FORMAT_FLAG), ("seeking", MPV_FORMAT_FLAG),
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("volume", MPV_FORMAT_DOUBLE),
            ("track-list/count", MPV_FORMAT_INT64), ("dwidth", MPV_FORMAT_INT64), ("dheight", MPV_FORMAT_INT64),
        ] {
            mpv_observe_property(handle, 0, name, format)
        }

        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue().readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func tearDown() {
        guard let handle = mpv else { return }
        mpv = nil
        generation &+= 1
        mpv_set_wakeup_callback(handle, nil, nil)
        // Destroy off the main thread: mpv_terminate_destroy waits for the render thread to finish.
        // The layer handed to mpv as its window must outlive the instance, so the view is kept until it is gone.
        let keepAlive = view
        eventQueue.async { mpv_terminate_destroy(handle); _ = keepAlive }
    }

    // MARK: - Events

    private func readEvents() {
        let current = generation
        eventQueue.async { [weak self] in
            guard let self, self.generation == current, let handle = self.mpv else { return }
            while true {
                guard let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE else { break }
                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                          let rawName = data.name else { break }
                    self.handleProperty(String(cString: rawName), data: data)
                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async { if self.phase == .loading { self.phase = self.isPaused ? .paused : .playing } }
                    self.refreshTracks()
                case MPV_EVENT_END_FILE:
                    let end = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    DispatchQueue.main.async {
                        if let end, end.reason == MPV_END_FILE_REASON_ERROR {
                            self.phase = .failed("This stream could not be played (\(String(cString: mpv_error_string(end.error)))).")
                        } else if let end, end.reason == MPV_END_FILE_REASON_EOF {
                            self.phase = .ended
                        }
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    // mpv's own diagnostics (warnings and errors). Text can quote a stream address, so it only goes to
                    // the debug console in debug builds and is never shown in the UI.
                    #if DEBUG
                    if let log = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                       let prefix = log.prefix, let text = log.text {
                        NSLog("[mpv %@] %@", String(cString: prefix), String(cString: text).trimmingCharacters(in: .newlines))
                    }
                    #endif
                default:
                    break
                }
            }
        }
    }

    private func handleProperty(_ name: String, data: mpv_event_property) {
        // The property's memory is only valid until the next mpv_wait_event call, so decode it here, on the event
        // queue, and hand plain Swift values to the main thread.
        let flagValue: Bool? = data.format == MPV_FORMAT_FLAG ? data.data?.assumingMemoryBound(to: Int32.self).pointee != 0 : nil
        let doubleValue: Double? = data.format == MPV_FORMAT_DOUBLE ? data.data?.assumingMemoryBound(to: Double.self).pointee : nil
        let intValue: Int64? = data.format == MPV_FORMAT_INT64 ? data.data?.assumingMemoryBound(to: Int64.self).pointee : nil
        func flag() -> Bool? { flagValue }
        func double() -> Double? { doubleValue }
        func int() -> Int64? { intValue }
        DispatchQueue.main.async {
            switch name {
            case "eof-reached":
                // With keep-open the file stays loaded at its end, so this is how the end of a video is seen.
                if flag() == true, self.phase != .loading { self.phase = .ended }
            case "pause":
                if let paused = flag() {
                    self.isPaused = paused
                    if self.phase == .playing || self.phase == .paused { self.phase = paused ? .paused : .playing }
                }
            case "paused-for-cache":
                if let waiting = flag() {
                    if waiting, self.phase == .playing { self.phase = .buffering }
                    else if !waiting, self.phase == .buffering { self.phase = self.isPaused ? .paused : .playing }
                }
            case "time-pos": if let value = double() { self.position = value }
            case "duration": if let value = double() { self.duration = value }
            case "volume": if let value = double() { self.volume = value }
            case "track-list/count": self.refreshTracks()
            case "dwidth", "dheight":
                if let value = int() {
                    var size = self.videoSize
                    if name == "dwidth" { size.width = CGFloat(value) } else { size.height = CGFloat(value) }
                    self.videoSize = size
                }
            default: break
            }
        }
    }

    private func refreshTracks() {
        guard let handle = mpv else { return }
        let count = Int(propertyInt(handle, "track-list/count") ?? 0)
        var found: [Track] = []
        for index in 0..<count {
            guard let kindText = propertyString(handle, "track-list/\(index)/type"),
                  let kind = Track.Kind(rawValue: kindText),
                  let id = propertyInt(handle, "track-list/\(index)/id") else { continue }
            let language = propertyString(handle, "track-list/\(index)/lang")
            let title = propertyString(handle, "track-list/\(index)/title") ?? language ?? "\(kind.rawValue) \(id)"
            let selected = propertyString(handle, "track-list/\(index)/selected") == "yes"
            found.append(Track(id: Int(id), kind: kind, title: title, language: language, isSelected: selected))
        }
        DispatchQueue.main.async { self.tracks = found }
    }

    // MARK: - Diagnostics

    /// What mpv reports right now, for bring-up and bug reports. Never includes the stream address (it can hold a login).
    public func diagnosticSnapshot() -> String {
        guard let handle = mpv else { return "mpv not running" }
        func p(_ name: String) -> String { propertyString(handle, name) ?? "-" }
        return "phase=\(phase) pos=\(p("time-pos")) dur=\(p("duration")) paused=\(p("pause")) "
            + "vo=\(p("current-vo")) hwdec=\(p("hwdec-current")) vcodec=\(p("video-codec")) "
            + "size=\(p("video-params/w"))x\(p("video-params/h")) fps=\(p("estimated-vf-fps")) "
            + "acodec=\(p("audio-codec-name")) cache=\(p("demuxer-cache-duration")) dropped=\(p("frame-drop-count"))"
    }

    // MARK: - mpv helpers

    private func setOption(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        let status = mpv_set_option_string(handle, name, value)
        if status < 0 { NSLog("[BannerPlayer] ignoring mpv option %@: %@", name, String(cString: mpv_error_string(status))) }
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func command(_ args: [String]) {
        guard let handle = mpv else { return }
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for pointer in cArgs { free(UnsafeMutablePointer(mutating: pointer)) } }
        let status = mpv_command(handle, &cArgs)
        if status < 0 { NSLog("[BannerPlayer] mpv command %@ failed: %@", args.first ?? "", String(cString: mpv_error_string(status))) }
    }

    private func propertyString(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    private func propertyInt(_ handle: OpaquePointer, _ name: String) -> Int64? {
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }
}
