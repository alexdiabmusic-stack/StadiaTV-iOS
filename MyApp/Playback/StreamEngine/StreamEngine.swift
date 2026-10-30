import Foundation

/// The process-wide engine: one loopback server shared by every playing session (the main
/// player, multiview tiles, CarPlay audio).
nonisolated final class StreamEngine: @unchecked Sendable {
    static let shared = StreamEngine()

    private let lock = NSLock()
    private var server: LoopbackHTTPServer?
    private var sessions: [String: StreamEngineSession] = [:]
    /// Path secret: other processes on the device can reach 127.0.0.1, but can't guess this.
    private let token = StreamEngine.randomHex(bytes: 16)

    /// Starts a session for `routes`. It doesn't connect until `start()`.
    func makeSession(routes: [StreamEngineSession.Route], headers: [String: String],
                     configuration: StreamEngineConfiguration, isSingleConnectionAccount: Bool,
                     onEvent: @escaping @Sendable (StreamEngineSession.Event) -> Void) throws -> StreamEngineSession {
        let port = try ensureServer()
        let id = StreamEngine.randomHex(bytes: 8)
        let session = StreamEngineSession(id: id, routes: routes, headers: headers, configuration: configuration,
                                          isSingleConnectionAccount: isSingleConnectionAccount,
                                          baseURL: baseURL(port: port, sessionID: id), onEvent: onEvent)
        lock.lock()
        sessions[id] = session
        lock.unlock()
        return session
    }

    func remove(sessionID: String) {
        lock.lock()
        sessions[sessionID] = nil
        lock.unlock()
    }

    private func baseURL(port: UInt16, sessionID: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/\(sessionID)/") ?? URL(fileURLWithPath: "/")
    }

    private func ensureServer() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if let server { return server.port }
        let server = LoopbackHTTPServer { [weak self] request in
            self?.route(request) ?? .notFound()
        }
        server.onPortChange = { [weak self] port in self?.portChanged(port) }
        let port = try server.start()
        self.server = server
        return port
    }

    private func route(_ request: LoopbackHTTPServer.Request) -> LoopbackHTTPServer.Response {
        let parts = request.path.split(separator: "/")
        guard parts.count == 3, parts[0] == token else { return .notFound() }
        lock.lock()
        let session = sessions[String(parts[1])]
        lock.unlock()
        return session?.handle(file: String(parts[2])) ?? .notFound()
    }

    private func portChanged(_ port: UInt16) {
        lock.lock()
        let current = Array(sessions.values)
        lock.unlock()
        for session in current { session.updateBaseURL(baseURL(port: port, sessionID: session.id)) }
    }

    private static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Decides whether the engine should carry a stream, and over which routes.
nonisolated enum StreamEnginePlanner {
    /// Routes for a live stream, primary first; nil when the URL belongs to AVPlayer directly
    /// (on-demand files, catch-up/archive requests, DASH, non-HTTP schemes).
    static func routes(for url: URL) -> [StreamEngineSession.Route]? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard !isOnDemand(url) else { return nil }
        if let xtream = xtreamLiveRoutes(for: url) { return xtream }
        let label = ["m3u8", "m3u"].contains(url.pathExtension.lowercased()) ? "HLS" : "MPEG-TS"
        return [StreamEngineSession.Route(url: url, label: label)]
    }

    /// Finite content: playing it through a live reserve would replay it on every reconnect.
    static func isOnDemand(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let markers = ["/movie/", "/movies/", "/series/", "/timeshift/", "timeshift.php", "/streaming/timeshift",
                       "/vod/", "/archive/", "/catchup/", "/recordings/"]
        if markers.contains(where: { path.contains($0) }) { return true }
        let query = (url.query ?? "").lowercased()
        if ["utc=", "lutc=", "catchup", "timeshift", "playseek="].contains(where: { query.contains($0) }) { return true }
        let fileExtension = url.pathExtension.lowercased()
        let finite: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "mp3", "aac", "m4a", "flac", "ogg",
                                   "wav", "mpd", "ism", "f4m", "wmv", "flv"]
        if finite.contains(fileExtension) { return true }
        // Flussonic archive URLs carry a start time and duration: index-1700000000-3600.m3u8.
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        if parts.count >= 3, parts[parts.count - 2].count >= 9, parts[parts.count - 2].allSatisfy(\.isNumber),
           parts[parts.count - 1].allSatisfy(\.isNumber) {
            return true
        }
        return false
    }

    /// `http(s)://host[:port]/{user}/{pass}/{id}` and `/live/{user}/{pass}/{id}[.ts|.m3u8]`:
    /// the raw transport stream first (one long connection, the provider's buffered burst on
    /// connect), the panel's HLS output as the backup route.
    static func xtreamLiveRoutes(for url: URL) -> [StreamEngineSession.Route]? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0].lowercased() == "live" { parts.removeFirst() }
        guard parts.count == 3 else { return nil }
        let last = parts[2]
        let fileExtension = (last as NSString).pathExtension.lowercased()
        let streamID = (last as NSString).deletingPathExtension
        guard ["", "ts", "m3u8"].contains(fileExtension), !streamID.isEmpty, streamID.allSatisfy(\.isNumber) else { return nil }

        components.path = "/live/\(parts[0])/\(parts[1])/\(streamID).m3u8"
        guard let hls = components.url else { return nil }
        let transport: URL
        if fileExtension == "m3u8" {
            components.path = "/live/\(parts[0])/\(parts[1])/\(streamID).ts"
            guard let derived = components.url else { return nil }
            transport = derived
        } else {
            transport = url
        }
        return [StreamEngineSession.Route(url: transport, label: "MPEG-TS"),
                StreamEngineSession.Route(url: hls, label: "HLS")]
    }
}
