import Foundation

/// One way of playing a channel's stream.
nonisolated struct PlaybackCandidate: Equatable, Sendable {
    nonisolated enum Source: Equatable, Sendable {
        /// Given to Apple's player as it is: HLS, or anything else it can open itself.
        case direct
        /// A transport stream, converted to HLS on this device (`TransportStreamProxy`) so Apple's player can play it.
        case convertedTransportStream
    }

    let url: URL
    let source: Source
}

/// Which URLs to try for a channel, and in what order.
///
/// An Xtream panel offers each live stream as HLS (`.m3u8`) and as a raw transport stream (`.ts`). Apple's player
/// plays the first directly; the second needs converting. HLS is tried first, as it needs no converting, but some
/// panels' HLS is slow or never starts while their transport stream is instant, so the transport stream is the
/// fallback, and is tried first for a host where it has worked and HLS has not.
nonisolated enum PlaybackCandidates {

    static func candidates(for url: URL, prefersTransportStream: Bool) -> [PlaybackCandidate] {
        var direct: [PlaybackCandidate] = []
        var converted: [PlaybackCandidate] = []

        let hls = hlsURLCandidates(for: url)
        if hls.count == 2 {
            // A `.ts` or extension-less Xtream URL: its HLS form, then the stream it came from.
            direct = [PlaybackCandidate(url: hls[0], source: .direct)]
            converted = [PlaybackCandidate(url: hls[1], source: .convertedTransportStream)]
        } else if let transport = xtreamURL(url, extension: "ts"), url.pathExtension.lowercased() == "m3u8" {
            direct = [PlaybackCandidate(url: url, source: .direct)]
            converted = [PlaybackCandidate(url: transport, source: .convertedTransportStream)]
        } else if url.pathExtension.lowercased() == "ts", ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            // Nearly always a transport stream. A panel can name an HLS playlist like this, though: the converter says
            // so as soon as it sees the first bytes, and the player is then given the address as it is.
            return [PlaybackCandidate(url: url, source: .convertedTransportStream), PlaybackCandidate(url: url, source: .direct)]
        } else {
            direct = [PlaybackCandidate(url: url, source: .direct)]
        }
        return prefersTransportStream ? converted + direct : direct + converted
    }

    // MARK: Xtream URLs

    /// URLs to try, in order, as HLS. Apple's player can't play raw MPEG-TS, so an Xtream-shaped `.ts` or
    /// extension-less URL is tried as its HLS `.m3u8` form first, keeping the original as the second.
    static func hlsURLCandidates(for url: URL) -> [URL] {
        guard let hls = xtreamHLSURL(for: url), hls != url else { return [url] }
        return [hls, url]
    }

    /// Rewrites `http(s)://host[:port]/{user}/{pass}/{id}` and `/live/{user}/{pass}/{id}[.ts]` to `.m3u8`.
    static func xtreamHLSURL(for url: URL) -> URL? {
        guard let parts = xtreamParts(of: url), parts.extension.isEmpty || parts.extension == "ts" else { return nil }
        return xtreamURL(url, extension: "m3u8")
    }

    /// The same Xtream live stream with another extension (`ts` for the raw stream, `m3u8` for HLS); nil if `url`
    /// isn't shaped like an Xtream live stream. The username and password keep the encoding they came with, so
    /// ones containing `/` or `?` still survive.
    static func xtreamURL(_ url: URL, extension newExtension: String) -> URL? {
        guard let parts = xtreamParts(of: url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedPath = "/live/\(parts.user)/\(parts.password)/\(parts.streamID).\(newExtension)"
        return components.url
    }

    private static func xtreamParts(of url: URL) -> (user: String, password: String, streamID: String, extension: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0].lowercased() == "live" { parts.removeFirst() }
        guard parts.count == 3 else { return nil }
        let last = parts[2]
        let dot = last.lastIndex(of: ".")
        let fileExtension = dot.map { String(last[last.index(after: $0)...]).lowercased() } ?? ""
        let streamID = dot.map { String(last[..<$0]) } ?? last
        guard ["", "ts", "m3u8"].contains(fileExtension), !streamID.isEmpty, streamID.allSatisfy(\.isNumber) else { return nil }
        return (parts[0], parts[1], streamID, fileExtension)
    }
}

/// Which format worked last for each provider, so the converter is used straight away where HLS has been the problem.
nonisolated struct PlaybackFormatMemory {
    /// How long a provider keeps being tried as a transport stream first once it has needed that.
    static let lifetime: TimeInterval = 14 * 24 * 3600

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Whether the transport stream has worked for this provider where HLS had not.
    func prefersTransportStream(for url: URL) -> Bool {
        guard let key = Self.key(for: url), let since = defaults.object(forKey: key) as? Double else { return false }
        return now().timeIntervalSince1970 - since < Self.lifetime
    }

    /// Records which format just played for this provider. HLS working again clears the preference.
    func record(_ source: PlaybackCandidate.Source, for url: URL) {
        guard let key = Self.key(for: url) else { return }
        switch source {
        case .convertedTransportStream: defaults.set(now().timeIntervalSince1970, forKey: key)
        case .direct: defaults.removeObject(forKey: key)
        }
    }

    private static func key(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return "playback.prefersTransportStream.\(host):\(url.port ?? 0)"
    }
}
