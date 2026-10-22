import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a provider connection reports to its session. Delivered on the session's queue.
nonisolated enum EngineConnectionEvent {
    /// The provider answered with a usable response. `cadence` is the longest normal gap between
    /// deliveries (an HLS target duration; zero for a continuous stream).
    case opened(status: Int, cadence: Double)
    /// Bytes arrived (for delivery measurement); the media itself follows in `media`.
    case received(bytes: Int)
    case media(Data)
    /// The source declared a timeline break (HLS #EXT-X-DISCONTINUITY or a skipped segment).
    case sourceDiscontinuity
    /// HLS ingest delivered this media sequence number; a reconnect resumes after it.
    case segmentDelivered(sequence: Int)
    /// The URL serves an HLS playlist rather than a transport stream.
    case playlist(text: String, url: URL)
    case ended(RecoveryReferee.FailureKind)
}

/// One provider connection, confined to its session's queue.
nonisolated protocol EngineConnection: AnyObject {
    func start()
    func cancel()
}

/// The engine's URLSession: system TLS, no caching, no idle timeout that would pre-empt the
/// referee's own stall handling, and bytes delivered as they arrive.
nonisolated final class EngineHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = EngineHTTPClient()

    /// AVPlayer's identity, used when the playlist names no User-Agent: providers that worked with
    /// AVPlayer fetching the stream keep working when the engine fetches it instead.
    static let defaultUserAgent = "AppleCoreMedia/1.0.0.22A3354 (iPhone; U; CPU OS 18_0 like Mac OS X; en_us)"

    struct Callbacks: Sendable {
        let data: @Sendable (Data, HTTPURLResponse?) -> Void
        let completion: @Sendable (Error?, HTTPURLResponse?) -> Void
    }

    private let lock = NSLock()
    private var callbacks: [Int: Callbacks] = [:]
    private let delegateQueue: OperationQueue
    private var session: URLSession?

    override init() {
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "BannerTV.StreamEngine.http"
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 6
        #if canImport(Darwin)
        configuration.waitsForConnectivity = false
        configuration.networkServiceType = .avStreaming
        #endif
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    static func request(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil { request.setValue("*/*", forHTTPHeaderField: "Accept") }
        return request
    }

    @discardableResult
    func start(_ request: URLRequest, callbacks: Callbacks) -> URLSessionDataTask? {
        guard let session else { return nil }
        let task = session.dataTask(with: request)
        lock.lock()
        self.callbacks[task.taskIdentifier] = callbacks
        lock.unlock()
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let callbacks = self.callbacks[dataTask.taskIdentifier]
        lock.unlock()
        callbacks?.data(data, dataTask.response as? HTTPURLResponse)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let callbacks = self.callbacks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        callbacks?.completion(error, task.response as? HTTPURLResponse)
    }

    /// How an HTTP status reads to the referee.
    static func failure(forStatus status: Int) -> RecoveryReferee.FailureKind {
        switch status {
        case 401, 402, 403, 407, 423, 429, 451, 456, 458, 509, 551: return .accountRejected(status)
        case 404, 410: return .notFound(status)
        default: return .server(status)
        }
    }
}

/// A continuous MPEG-TS HTTP response held open for as long as the provider sends it.
///
/// The first bytes are sniffed: a transport stream flows on, an HLS playlist is handed back
/// so the session can switch this route to HLS ingest, and anything else (an HTML error page
/// served with 200) is reported as unsupported rather than fed to the demuxer.
nonisolated final class TSStreamConnection: EngineConnection, @unchecked Sendable {
    private enum Mode { case sniffing, streaming, playlist }

    private let url: URL
    private let headers: [String: String]
    private let queue: DispatchQueue
    private let emit: (EngineConnectionEvent) -> Void
    private var task: URLSessionDataTask?
    private var mode: Mode = .sniffing
    private var buffer = Data()
    private var opened = false
    private var finished = false

    init(url: URL, headers: [String: String], queue: DispatchQueue, emit: @escaping (EngineConnectionEvent) -> Void) {
        self.url = url
        self.headers = headers
        self.queue = queue
        self.emit = emit
    }

    func start() {
        let callbacks = EngineHTTPClient.Callbacks(
            data: { [weak self] data, response in
                guard let self else { return }
                self.queue.async { self.received(data, response: response) }
            },
            completion: { [weak self] error, response in
                guard let self else { return }
                self.queue.async { self.completed(error, response: response) }
            })
        task = EngineHTTPClient.shared.start(EngineHTTPClient.request(url: url, headers: headers), callbacks: callbacks)
    }

    func cancel() {
        finished = true
        task?.cancel()
        task = nil
    }

    private func received(_ data: Data, response: HTTPURLResponse?) {
        guard !finished else { return }
        if !opened {
            let status = response?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                finish(EngineHTTPClient.failure(forStatus: status))
                return
            }
            opened = true
            emit(.opened(status: status, cadence: 0))
        }
        emit(.received(bytes: data.count))
        switch mode {
        case .streaming:
            emit(.media(data))
        case .playlist:
            buffer.append(data)
            if buffer.count > 2 * 1024 * 1024 { finish(.unsupportedContent("oversized playlist")) }
        case .sniffing:
            buffer.append(data)
            if Self.looksLikePlaylist(buffer) {
                mode = .playlist
            } else if Self.containsTransportSync(buffer) {
                mode = .streaming
                emit(.media(buffer))
                buffer = Data()
            } else if buffer.count > 32 * 1024 {
                finish(.unsupportedContent("not an MPEG transport stream"))
            }
        }
    }

    private func completed(_ error: Error?, response: HTTPURLResponse?) {
        guard !finished else { return }
        if !opened, let status = response?.statusCode, !(200..<300).contains(status) {
            finish(EngineHTTPClient.failure(forStatus: status))
            return
        }
        if error != nil {
            finish(.network)
            return
        }
        switch mode {
        case .playlist:
            finished = true
            let text = String(decoding: buffer, as: UTF8.self)
            emit(.playlist(text: text, url: response?.url ?? url))
        case .sniffing:
            if Self.containsTransportSync(buffer) {
                emit(.media(buffer))
                finish(.endOfStream)
            } else {
                finish(buffer.isEmpty ? .endOfStream : .unsupportedContent("not an MPEG transport stream"))
            }
        case .streaming:
            finish(.endOfStream)
        }
    }

    private func finish(_ kind: RecoveryReferee.FailureKind) {
        guard !finished else { return }
        finished = true
        task?.cancel()
        task = nil
        emit(.ended(kind))
    }

    static func looksLikePlaylist(_ data: Data) -> Bool {
        let bytes = data.prefix(64).drop { $0 == 0xEF || $0 == 0xBB || $0 == 0xBF || $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        return bytes.starts(with: Array("#EXTM3U".utf8))
    }

    static func containsTransportSync(_ data: Data) -> Bool {
        let size = MPEGTS.packetSize
        guard data.count >= 2 * size + 1 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let limit = min(bytes.count - 2 * size - 1, 16 * 1024)
            guard limit >= 0 else { return false }
            for index in 0...limit where bytes[index] == MPEGTS.syncByte
                && bytes[index + size] == MPEGTS.syncByte && bytes[index + 2 * size] == MPEGTS.syncByte {
                return true
            }
            return false
        }
    }
}

/// Live HLS ingest: follows a provider media playlist and feeds its transport-stream segments,
/// in order, into the same reserve and splicer as a continuous stream.
///
/// Segments are handed over whole, so a failed download is retried instead of leaving half a
/// segment in the reserve. Skipped segments and source discontinuities are announced so the
/// splicer re-times what follows.
nonisolated final class HLSIngestConnection: EngineConnection, @unchecked Sendable {
    private let headers: [String: String]
    private let queue: DispatchQueue
    private let emit: (EngineConnectionEvent) -> Void
    private var playlistURL: URL
    private var initialPlaylist: String?

    private var segments: [HLSPlaylistParser.Segment] = []
    private var targetDuration: Double = 6
    private var nextSequence: Int?
    private var playlistTask: URLSessionDataTask?
    private var segmentTask: URLSessionDataTask?
    private var segmentBuffer = Data()
    private var playlistFailures = 0
    private var segmentFailures = 0
    private var deliveredSegments = 0
    private var opened = false
    private var finished = false
    private var refreshPending = false
    /// Programme seconds to fetch behind the live end when joining: the provider's window
    /// downloads at line rate, so this becomes an instant reserve.
    private let joinSeconds: Double
    /// The last segment a previous connection delivered; a reconnect continues right after it.
    private let resumeAfter: Int?
    /// Segments fetched behind the live end at least.
    private let joinDepth: Int

    /// Segments fetched behind the live end when the deep join isn't possible.
    static let joinDepth = 3

    init(playlistURL: URL, initialPlaylist: String?, headers: [String: String], joinSeconds: Double,
         joinDepth: Int = HLSIngestConnection.joinDepth, resumeAfter: Int?, queue: DispatchQueue,
         emit: @escaping (EngineConnectionEvent) -> Void) {
        self.playlistURL = playlistURL
        self.initialPlaylist = initialPlaylist
        self.headers = headers
        self.joinSeconds = joinSeconds
        self.joinDepth = max(1, joinDepth)
        self.resumeAfter = resumeAfter
        self.queue = queue
        self.emit = emit
    }

    /// Where to start in a freshly loaded playlist.
    private func joinSequence(in segments: [HLSPlaylistParser.Segment]) -> Int? {
        guard let last = segments.last else { return nil }
        if let resumeAfter, segments.contains(where: { $0.sequence == resumeAfter + 1 }) { return resumeAfter + 1 }
        if let resumeAfter, resumeAfter >= last.sequence { return last.sequence + 1 }
        var covered = 0.0
        var start = last.sequence
        for segment in segments.reversed() {
            start = segment.sequence
            covered += segment.duration
            if covered >= joinSeconds { break }
        }
        return min(start, max(segments.first?.sequence ?? start, last.sequence - (joinDepth - 1)))
    }

    func start() {
        if let text = initialPlaylist {
            initialPlaylist = nil
            handlePlaylist(text, from: playlistURL)
        } else {
            fetchPlaylist()
        }
    }

    func cancel() {
        finished = true
        playlistTask?.cancel()
        segmentTask?.cancel()
        playlistTask = nil
        segmentTask = nil
    }

    // MARK: Playlist

    private func fetchPlaylist() {
        guard !finished, playlistTask == nil else { return }
        let collected = LockedData()
        let callbacks = EngineHTTPClient.Callbacks(
            data: { data, _ in collected.append(data) },
            completion: { [weak self] error, response in
                guard let self else { return }
                let body = collected.value
                self.queue.async { self.playlistCompleted(body: body, error: error, response: response) }
            })
        playlistTask = EngineHTTPClient.shared.start(EngineHTTPClient.request(url: playlistURL, headers: headers), callbacks: callbacks)
    }

    private func playlistCompleted(body: Data, error: Error?, response: HTTPURLResponse?) {
        playlistTask = nil
        guard !finished else { return }
        if let status = response?.statusCode, !(200..<300).contains(status) {
            // A refused playlist on a running stream is retried like any other hiccup at first.
            if !opened || playlistFailures >= 2 { finish(EngineHTTPClient.failure(forStatus: status)); return }
            playlistFailures += 1
            scheduleRefresh(after: 1)
            return
        }
        guard error == nil else {
            playlistFailures += 1
            if playlistFailures >= 3 { finish(.network) } else { scheduleRefresh(after: 1) }
            return
        }
        playlistFailures = 0
        handlePlaylist(String(decoding: body, as: UTF8.self), from: response?.url ?? playlistURL)
    }

    private func handlePlaylist(_ text: String, from url: URL) {
        switch HLSPlaylistParser.parse(text, baseURL: url) {
        case .invalid:
            finish(.unsupportedContent("invalid playlist"))
        case .master(let variants):
            // IPTV masters usually wrap one rendition; a real ladder is AVPlayer's job.
            guard Set(variants.map(\.url)).count == 1, let variant = variants.first else {
                finish(.unsupportedContent("adaptive bitrate ladder"))
                return
            }
            playlistURL = variant.url
            fetchPlaylist()
        case .media(let playlist):
            if let reason = playlist.unsupportedReason {
                finish(.unsupportedContent(reason))
                return
            }
            playlistURL = url
            if !opened {
                opened = true
                emit(.opened(status: 200, cadence: max(1, playlist.targetDuration)))
            }
            let changed = playlist.segments.last?.sequence != segments.last?.sequence
            segments = playlist.segments
            targetDuration = max(1, playlist.targetDuration)
            if nextSequence == nil {
                nextSequence = joinSequence(in: segments)
            } else if let next = nextSequence, let first = segments.first, next < first.sequence {
                // Fell out of the provider's window: resume near its live end.
                nextSequence = max(first.sequence, (segments.last?.sequence ?? first.sequence) - (Self.joinDepth - 1))
                emit(.sourceDiscontinuity)
            }
            downloadNextSegment()
            scheduleRefresh(after: changed ? targetDuration : targetDuration / 2)
        }
    }

    private func scheduleRefresh(after seconds: Double) {
        guard !finished, !refreshPending else { return }
        refreshPending = true
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.fetchPlaylist()
        }
    }

    // MARK: Segments

    private func downloadNextSegment() {
        guard !finished, segmentTask == nil, let sequence = nextSequence,
              let segment = segments.first(where: { $0.sequence == sequence }) else { return }
        segmentBuffer = Data()
        let callbacks = EngineHTTPClient.Callbacks(
            data: { [weak self] data, _ in
                guard let self else { return }
                self.queue.async { self.segmentReceived(data) }
            },
            completion: { [weak self] error, response in
                guard let self else { return }
                self.queue.async { self.segmentCompleted(segment, error: error, response: response) }
            })
        segmentTask = EngineHTTPClient.shared.start(EngineHTTPClient.request(url: segment.url, headers: headers), callbacks: callbacks)
    }

    private func segmentReceived(_ data: Data) {
        guard !finished else { return }
        segmentBuffer.append(data)
        emit(.received(bytes: data.count))
    }

    private func segmentCompleted(_ segment: HLSPlaylistParser.Segment, error: Error?, response: HTTPURLResponse?) {
        segmentTask = nil
        guard !finished else { return }
        let status = response?.statusCode ?? 200
        if error != nil || !(200..<300).contains(status) {
            segmentFailures += 1
            if response == nil {
                // The provider is unreachable: skipping segments would only throw programme away.
                // Keep trying this one, and if the provider stays away, end the connection so the
                // referee reconnects and resumes right after the last segment delivered.
                if segmentFailures >= 4 {
                    finish(.network)
                    return
                }
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.downloadNextSegment() }
            } else if segmentFailures <= 2 {
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.downloadNextSegment() }
            } else {
                // The provider answers but this one segment is broken: skip it rather than stall the stream.
                segmentFailures = 0
                nextSequence = segment.sequence + 1
                emit(.sourceDiscontinuity)
                downloadNextSegment()
            }
            return
        }
        segmentFailures = 0
        if deliveredSegments == 0, !TSStreamConnection.containsTransportSync(segmentBuffer) {
            finish(.unsupportedContent("segments aren't MPEG-TS"))
            return
        }
        if segment.discontinuity, deliveredSegments > 0 { emit(.sourceDiscontinuity) }
        deliveredSegments += 1
        emit(.media(segmentBuffer))
        emit(.segmentDelivered(sequence: segment.sequence))
        segmentBuffer = Data()
        nextSequence = segment.sequence + 1
        downloadNextSegment()
    }

    private func finish(_ kind: RecoveryReferee.FailureKind) {
        guard !finished else { return }
        cancel()
        emit(.ended(kind))
    }
}

/// A byte buffer filled from URLSession's delegate queue and read once on completion.
nonisolated private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
