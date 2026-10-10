import Foundation

/// Plays a provider's raw MPEG-TS stream through Apple's player by serving it as HLS from this device.
///
/// Apple's player can't open a transport stream straight off a URL, which is what most IPTV panels serve best (and
/// some serve only). This opens that stream itself, cuts it into HLS segments (`HLSSegmenter`) and offers them on the
/// loopback interface, so the player is given an ordinary live HLS URL on 127.0.0.1.
///
/// One proxy is one stream: `start()` it, give the player the URL it returns and `stop()` it when the player lets go,
/// which also closes the provider's connection.
nonisolated final class TransportStreamProxy: @unchecked Sendable {

    private let upstream: URL
    private let headers: [String: String]?
    private let protocolClasses: [AnyClass]?
    private let retryDelays: [TimeInterval]
    /// The player is given a URL that includes this, so other apps on the device can't tune in to the stream.
    private let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let store = HLSSegmentStore()
    private let lock = NSLock()
    private var server: LocalHTTPServer?
    private var reader: UpstreamReader?
    private var stopped = false
    private var failureHandler: (@Sendable (String) -> Void)?
    private var failureReported = false

    /// `retryDelays` are the waits before each reconnect to the provider after a dropped or refused connection; tests
    /// shorten them.
    init(upstream: URL, headers: [String: String]?, protocolClasses: [AnyClass]? = nil,
         retryDelays: [TimeInterval] = UpstreamReader.defaultRetryDelays) {
        self.upstream = upstream
        self.headers = headers
        self.protocolClasses = protocolClasses
        self.retryDelays = retryDelays.isEmpty ? UpstreamReader.defaultRetryDelays : retryDelays
    }

    /// Called once, on a background thread, when the stream turns out not to be playable. Set it before `start()`.
    func onFailure(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        failureHandler = handler
        lock.unlock()
    }

    /// Why the stream can't be played, once that is known.
    var failure: String? { store.failureReason }

    /// What the stream carries, e.g. "H.264 video, AAC audio", once its program table has been read.
    var streamSummary: String? { currentReader?.summary }

    private var currentReader: UpstreamReader? {
        lock.lock()
        defer { lock.unlock() }
        return reader
    }

    /// What has happened so far, for explaining a stream that is slow to start.
    var progress: String {
        guard let reader = currentReader else { return "The converter hasn't started." }
        let bytes = reader.bytesReceived
        if bytes == 0 { return "The provider hasn't sent any video yet." }
        if reader.summary == nil { return "The provider's stream has no program table yet." }
        if store.segmentCount == 0 { return "The provider's stream has no keyframe yet." }
        return "The converter has cut \(store.segmentCount) segment(s) from \(bytes / 1024) KB."
    }

    /// Starts listening and connecting to the provider; returns the playlist URL for the player.
    func start() throws -> URL {
        let server = LocalHTTPServer { [weak self] request in
            self?.respond(to: request) ?? .text(503, "The stream was closed.")
        }
        let port = try server.start()
        let reader = UpstreamReader(url: upstream, headers: headers, store: store, protocolClasses: protocolClasses,
                                    retryDelays: retryDelays) { [weak self] reason in
            self?.fail(reason)
        }
        lock.lock()
        self.server = server
        self.reader = reader
        lock.unlock()
        reader.start()
        return URL(string: "http://127.0.0.1:\(port)/\(secret)/index.m3u8")!
    }

    /// A proxy let go of without `stop()` must not go on downloading the provider's stream: an account often allows
    /// one connection, and the next channel would be refused.
    deinit { stop() }

    /// Closes the provider's connection and the local server.
    func stop() {
        lock.lock()
        stopped = true
        let server = self.server
        let reader = self.reader
        lock.unlock()
        reader?.stop()
        server?.stop()
        store.cancel()
    }

    private func fail(_ reason: String) {
        store.fail(reason)
        lock.lock()
        let handler = failureReported || stopped ? nil : failureHandler
        failureReported = true
        lock.unlock()
        handler?(reason)
    }

    // MARK: - What the player asks for

    private func respond(to request: LocalHTTPServer.Request) -> LocalHTTPServer.Response {
        let prefix = "/\(secret)/"
        guard request.method == "GET" || request.method == "HEAD", request.path.hasPrefix(prefix) else {
            return .text(404, "Not found")
        }
        let name = String(request.path.dropFirst(prefix.count))

        if name == "index.m3u8" {
            switch store.playlist(timeout: 25) {
            case .playlist(let text):
                return .init(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
            case .failed(let reason):
                return .text(502, reason)
            case .timedOut:
                return .text(504, progress)
            }
        }

        if name.hasPrefix("segment"), name.hasSuffix(".ts"),
           let sequence = Int(name.dropFirst("segment".count).dropLast(".ts".count)),
           let data = store.segment(sequence: sequence) {
            return Self.segmentResponse(data, range: request.headers["range"])
        }
        return .text(404, "Not found")
    }

    /// A segment, or the part of it that a `Range: bytes=a-b` header asks for.
    static func segmentResponse(_ data: Data, range: String?) -> LocalHTTPServer.Response {
        guard let range, range.lowercased().hasPrefix("bytes=") else {
            return .init(status: 200, contentType: "video/mp2t", body: data, headers: ["Accept-Ranges": "bytes"])
        }
        let spec = range.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2 else { return .init(status: 200, contentType: "video/mp2t", body: data) }
        let first: Int?
        let last: Int?
        if spec[0].isEmpty {
            // "-n" is the last n bytes.
            guard let suffix = Int(spec[1]), suffix > 0 else { return .text(416, "Bad range") }
            first = max(0, data.count - suffix)
            last = data.count - 1
        } else {
            first = Int(spec[0])
            last = spec[1].isEmpty ? data.count - 1 : Int(spec[1])
        }
        guard let first, let last, first <= last, first < data.count else {
            return .init(status: 416, contentType: "text/plain", body: Data("Bad range".utf8),
                         headers: ["Content-Range": "bytes */\(data.count)"])
        }
        let end = min(last, data.count - 1)
        return .init(status: 206, contentType: "video/mp2t", body: data.subdata(in: first..<(end + 1)),
                     headers: ["Content-Range": "bytes \(first)-\(end)/\(data.count)", "Accept-Ranges": "bytes"])
    }
}

// MARK: - The provider's stream

/// Streams a provider's transport stream into a segmenter, reconnecting if the connection drops.
nonisolated final class UpstreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let defaultRetryDelays: [TimeInterval] = [0.5, 1, 2, 4]
    private static let maxFailuresInARow = 5

    private let url: URL
    private let headers: [String: String]?
    private let store: HLSSegmentStore
    private let protocolClasses: [AnyClass]?
    private let retryDelays: [TimeInterval]
    private let reportFailure: @Sendable (String) -> Void
    private let queue: OperationQueue
    private let lock = NSLock()

    // Touched only on `queue` (the session delegate queue).
    private let segmenter = HLSSegmenter()
    private var firstBytes = Data()
    private var checkedFirstBytes = false
    private var bytesThisConnection = 0
    private var failuresInARow = 0
    private var connections = 0
    /// The provider answered this connection with an error status, so whatever body follows is its error page, not video.
    private var refusedThisConnection = false
    /// What the provider last said when it refused a connection, to be the reason if the retries run out.
    private var lastRefusal: String?

    // Shared with other threads.
    private var session: URLSession?
    private var stopped = false
    private var total = 0
    private var latestSummary: String?

    init(url: URL, headers: [String: String]?, store: HLSSegmentStore, protocolClasses: [AnyClass]?,
         retryDelays: [TimeInterval] = UpstreamReader.defaultRetryDelays,
         reportFailure: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.headers = headers
        self.store = store
        self.protocolClasses = protocolClasses
        self.retryDelays = retryDelays
        self.reportFailure = reportFailure
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "TransportStreamProxy.upstream"
        queue.qualityOfService = .userInitiated
    }

    var bytesReceived: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    var summary: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestSummary
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        // A live stream never ends, so only silence is a reason to give up: no bytes for this long.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 24 * 3600
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lock.lock()
        self.session = session
        lock.unlock()
        queue.addOperation { [self] in open() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let session = self.session
        lock.unlock()
        session?.invalidateAndCancel()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Runs on `queue`.
    private func open() {
        guard !isStopped, let session = lockedSession() else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (name, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        if request.value(forHTTPHeaderField: StreamHTTPHeaders.userAgentKey) == nil {
            request.setValue(StreamProbe.playerUserAgent, forHTTPHeaderField: StreamHTTPHeaders.userAgentKey)
        }
        connections += 1
        bytesThisConnection = 0
        firstBytes = Data()
        checkedFirstBytes = false
        refusedThisConnection = false
        session.dataTask(with: request).resume()
    }

    private func lockedSession() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private func giveUp(_ reason: String) {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let session = self.session
        lock.unlock()
        session?.invalidateAndCancel()
        if !alreadyStopped { reportFailure(reason) }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            refusedThisConnection = true
            let refusal = StreamProbe.refusalText(http.statusCode, body: Data())
            lastRefusal = refusal
            completionHandler(.cancel)
            // The first connection failing is news the person should have now. After that, a refusal is often the
            // provider not having let go of the connection that just dropped, so it is retried.
            if connections <= 1 { giveUp(refusal) }
            return
        }
        lastRefusal = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // A refused connection's error page may still arrive before the cancel takes effect; it isn't a stream.
        guard !isStopped, !refusedThisConnection else { return }
        lock.lock()
        total += data.count
        lock.unlock()
        bytesThisConnection += data.count

        if !checkedFirstBytes {
            firstBytes.append(data)
            guard firstBytes.count >= TransportStream.packetSize else { feed(data); return }
            checkedFirstBytes = true
            if let complaint = Self.complaint(aboutFirstBytes: firstBytes) {
                giveUp(complaint)
                return
            }
        }
        feed(data)
    }

    private func feed(_ data: Data) {
        let segments = segmenter.feed(data)
        if let problem = segmenter.problem {
            giveUp(problem)
            return
        }
        store.add(segments)
        let summary = segmenter.summary
        lock.lock()
        latestSummary = summary
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isStopped else { return }
        // A short answer (a web page, a one-line message) ends before the first bytes were enough to judge.
        if !checkedFirstBytes, !firstBytes.isEmpty {
            checkedFirstBytes = true
            if let complaint = Self.complaint(aboutFirstBytes: firstBytes) {
                giveUp(complaint)
                return
            }
        }
        // A connection that delivered a good stretch of video counts as having worked.
        failuresInARow = bytesThisConnection >= TransportStream.packetSize * 200 ? 1 : failuresInARow + 1
        guard failuresInARow <= Self.maxFailuresInARow else {
            giveUp(lastRefusal ?? "The provider keeps dropping the connection.")
            return
        }
        let delay = retryDelays[min(failuresInARow - 1, retryDelays.count - 1)]
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.queue.addOperation {
                guard !self.isStopped else { return }
                self.segmenter.markDiscontinuity()
                self.open()
            }
        }
    }

    /// What is wrong with the first bytes of the answer, if they are not a transport stream.
    static func complaint(aboutFirstBytes data: Data) -> String? {
        switch StreamProbe.classify(data) {
        case .transportStream, .binary:
            return nil
        case .html:
            return "The provider answered with a web page instead of a stream. The account may be blocked, or the provider may be down."
        case .json, .text:
            let said = String(decoding: data.prefix(120), as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "The provider answered with a message instead of a stream: \"\(said)\""
        case .hlsMaster, .hlsMedia:
            return "The provider answered with an HLS playlist where a transport stream was expected."
        case .empty:
            return nil
        }
    }
}
