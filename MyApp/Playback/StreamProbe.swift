import Foundation

/// Asks a provider what it actually returns for a stream, the way the player would, so a stream that won't start can
/// be explained: refused, a web page, a raw transport stream, an empty feed, or video arriving too slowly.
///
/// Run it only once the player has let go of the stream. It is a few short extra connections, and an IPTV account
/// often allows exactly one.
nonisolated enum StreamProbe {

    // MARK: - Results

    nonisolated struct Report: Sendable, Equatable {
        nonisolated enum Verdict: Sendable, Equatable {
            case healthy
            case unreachable
            case refused(Int)
            case segmentsRefused(Int)
            case rawTransportStream
            case webPage
            case providerMessage
            case emptyPlaylist
            case slowSegments
            case unrecognised
        }

        let verdict: Verdict
        /// One or two sentences for the person watching.
        let summary: String
        /// What was seen, for logs. Hosts and numbers only: never a path, so never a credential.
        let technical: String
    }

    /// One answer from the provider. `status` is nil when nothing HTTP came back at all.
    nonisolated struct Reply: Sendable, Equatable {
        nonisolated enum End: Sendable, Equatable {
            case completed
            /// The read stopped at the byte limit.
            case sizeLimit
            /// The read stopped at the time limit.
            case timeLimit
            case failed
        }

        var url: URL?
        var status: Int?
        var contentType: String?
        var contentLength: Int64?
        var body: Data
        var end: End
        var seconds: TimeInterval
        var failure: String?

        init(url: URL? = nil, status: Int? = nil, contentType: String? = nil, contentLength: Int64? = nil,
             body: Data = Data(), end: End = .completed, seconds: TimeInterval = 0, failure: String? = nil) {
            self.url = url
            self.status = status
            self.contentType = contentType
            self.contentLength = contentLength
            self.body = body
            self.end = end
            self.seconds = seconds
            self.failure = failure
        }
    }

    /// Fetches `url`, reading at most `byteLimit` bytes for at most `seconds`.
    typealias Fetch = @Sendable (_ url: URL, _ byteLimit: Int, _ seconds: TimeInterval) async -> Reply

    // MARK: - Running a probe

    /// Probes `url` over the network with the channel's own headers. `protocolClasses` lets a test answer in place
    /// of a provider.
    @concurrent
    static func run(url: URL, headers: [String: String]?, protocolClasses: [AnyClass]? = nil) async -> Report {
        await probe(url: url) { target, byteLimit, seconds in
            await BoundedFetch.get(target, headers: headers, byteLimit: byteLimit, seconds: seconds,
                                   protocolClasses: protocolClasses)
        }
    }

    /// Follows the stream the way the player does (playlist, then the variant playlist if there is one, then a
    /// segment near the live edge) and says where it goes wrong. `fetch` is how answers are obtained.
    static func probe(url: URL, fetch: Fetch) async -> Report {
        let host = url.host ?? "the provider"
        let hidden = secrets(in: url)
        var notes = [host]

        func finish(_ verdict: Report.Verdict, _ summary: String) -> Report {
            Report(verdict: verdict,
                   summary: redact(summary, secrets: hidden),
                   technical: redact(notes.joined(separator: " · "), secrets: hidden))
        }

        // 1. What the stream URL answers with.
        let first = await fetch(url, 64 * 1024, 8)
        notes.append(describe("stream", first))
        if let problem = unreachable(first, host: host, doing: "ask for the stream") {
            return finish(.unreachable, problem)
        }
        if let status = first.status, !(200..<300).contains(status) {
            return finish(.refused(status), refusalText(status, body: first.body))
        }

        var playlist = first
        var playlistURL = first.url ?? url
        var bandwidth: Int?
        switch classify(first.body) {
        case .transportStream:
            return finish(.rawTransportStream, "The provider sends this channel as a raw MPEG-TS stream, not HLS, and Apple's player can't play that. Ask the provider to turn on HLS (m3u8) output for the account.")
        case .html:
            let title = htmlTitle(first.body).map { " titled \"\($0)\"" } ?? ""
            return finish(.webPage, "The provider answered with a web page\(title) instead of a stream (HTTP \(first.status ?? 200)). The account may be blocked, or the provider may be down.")
        case .json, .text:
            let said = snippet(of: first.body).map { ": \"\($0)\"" } ?? "."
            return finish(.providerMessage, "The provider answered with a message instead of a stream\(said)")
        case .empty:
            return finish(.unrecognised, "The provider answered with nothing (HTTP \(first.status ?? 200)).")
        case .binary:
            return finish(.unrecognised, "The provider answered with data that isn't a playlist or a stream.")
        case .hlsMaster:
            let master = parsePlaylist(text(of: first.body), base: playlistURL)
            guard let variant = master.variants.first else {
                return finish(.emptyPlaylist, "The provider's list of qualities for this channel is empty. The channel may be offline.")
            }
            bandwidth = master.variantBandwidths.first.flatMap { $0 > 0 ? $0 : nil }
            guard !Task.isCancelled else { return finish(.unrecognised, "The check was cancelled.") }
            let reply = await fetch(variant, 64 * 1024, 8)
            notes.append(describe("variant", reply))
            if let problem = unreachable(reply, host: host, doing: "ask for the channel's playlist") {
                return finish(.unreachable, problem)
            }
            if let status = reply.status, !(200..<300).contains(status) {
                return finish(.refused(status), refusalText(status, body: reply.body))
            }
            guard classify(reply.body) == .hlsMedia else {
                return finish(.unrecognised, "The provider's playlist for this channel isn't in a form the player can read.")
            }
            playlist = reply
            playlistURL = reply.url ?? variant
        case .hlsMedia:
            break
        }

        // 2. The playlist itself.
        let media = parsePlaylist(text(of: playlist.body), base: playlistURL)
        notes.append("\(media.segments.count) segments"
                     + (media.targetDuration.map { ", target \(Int($0)) s" } ?? "")
                     + (media.isEnded ? ", ended" : ", live"))
        guard !media.segments.isEmpty else {
            return finish(.emptyPlaylist, "The provider's playlist for this channel has no video in it. The channel may be offline, or still starting up.")
        }

        // 3. A segment near the live edge, which is where playback starts.
        let index = max(0, media.segments.count - 3)
        let segmentDuration = media.segmentDurations.indices.contains(index) ? media.segmentDurations[index] : (media.targetDuration ?? 0)
        guard !Task.isCancelled else { return finish(.unrecognised, "The check was cancelled.") }
        let segment = await fetch(media.segments[index], 1_048_576, 6)
        notes.append(describe("segment", segment))
        if segment.status == nil || (segment.end == .failed && segment.body.isEmpty) {
            return finish(.unreachable, "The playlist loads, but fetching the video failed: \(segment.failure ?? "no answer").")
        }
        if let status = segment.status, !(200..<300).contains(status) {
            let hint = [401, 403].contains(status)
                ? " Usually the account is already using all its connections, or the provider blocks this app."
                : ""
            return finish(.segmentsRefused(status), "The playlist loads, but the provider refuses the video itself (HTTP \(status)).\(hint)")
        }
        if classify(segment.body) == .html {
            return finish(.webPage, "The playlist loads, but the provider answers its video requests with a web page.")
        }

        // 4. How fast the video arrives compared with how fast it plays.
        let received = Double(segment.body.count)
        let rate = received / max(segment.seconds, 0.001)
        let needed: Double? = {
            if segmentDuration > 0 {
                if segment.end == .completed { return received / segmentDuration }
                if let length = segment.contentLength, length > 0 { return Double(length) / segmentDuration }
            }
            return bandwidth.map { Double($0) / 8 }
        }()
        let factor = needed.map { rate / $0 }
        let megabits = rate * 8 / 1_000_000
        let tooSlow = factor.map { $0 < 1.2 } ?? (rate < 150_000 || segment.end == .timeLimit)
        if tooSlow {
            let speed = factor.map { String(format: "about %.1f× real time (%.1f Mbit/s)", $0, megabits) }
                ?? String(format: "only %.1f Mbit/s", megabits)
            return finish(.slowSegments, "The provider delivers this channel at \(speed), too slow to play without constant buffering. Anything under about 1.2× real time stalls.")
        }
        let speed = factor.map { String(format: ", about %.1f× real time", $0) } ?? ""
        return finish(.healthy, "The provider's stream looks healthy (HLS, \(media.segments.count) segments\(speed)). If it still won't play, the channel's video format may not be one this player can decode.")
    }

    // MARK: - Reading what came back

    nonisolated enum Kind: Equatable {
        case hlsMaster, hlsMedia, transportStream, html, json, text, empty, binary
    }

    /// What a body is: a playlist, a transport stream, a web page, a JSON message, plain text or something else.
    static func classify(_ data: Data) -> Kind {
        guard !data.isEmpty else { return .empty }
        let head = Array(data.prefix(2048))

        // MPEG-TS is a sync byte every 188 bytes, in what is otherwise binary data. (0x47 is also "G".)
        if head.count > 188, head[0] == 0x47, head[188] == 0x47,
           head.prefix(188).filter({ $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }).count > 4 {
            return .transportStream
        }

        let leading = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        if leading.hasPrefix("#EXTM3U") {
            let all = text(of: data)
            if all.contains("#EXT-X-STREAM-INF") { return .hlsMaster }
            return .hlsMedia
        }
        let lowered = leading.lowercased()
        if lowered.hasPrefix("<") {
            let markers = ["<html", "<!doctype html", "<head", "<body", "<title"]
            return markers.contains(where: lowered.contains) ? .html : .text
        }
        if lowered.hasPrefix("{") || lowered.hasPrefix("[") { return .json }
        // Text is mostly printable and valid UTF-8; anything else is taken for binary data.
        let unprintable = head.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }.count
        let invalid = String(decoding: head, as: UTF8.self).unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        return (unprintable + invalid) * 20 <= head.count ? .text : .binary
    }

    nonisolated struct Playlist: Equatable {
        var variants: [URL] = []
        var variantBandwidths: [Int] = []
        var segments: [URL] = []
        var segmentDurations: [Double] = []
        var targetDuration: Double?
        var isEnded = false
    }

    /// The variants of a master playlist or the segments of a media playlist, with relative URLs resolved against `base`.
    static func parsePlaylist(_ text: String, base: URL) -> Playlist {
        var result = Playlist()
        var pendingBandwidth: Int?
        var pendingVariant = false
        var pendingDuration: Double?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    pendingVariant = true
                    pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap { Int($0) }
                } else if line.hasPrefix("#EXTINF:") {
                    let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
                    pendingDuration = Double(value.trimmingCharacters(in: .whitespaces))
                } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                    result.targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count).trimmingCharacters(in: .whitespaces))
                } else if line == "#EXT-X-ENDLIST" {
                    result.isEnded = true
                }
                continue
            }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            if pendingVariant {
                result.variants.append(url)
                result.variantBandwidths.append(pendingBandwidth ?? 0)
                pendingVariant = false
                pendingBandwidth = nil
            } else {
                let known = (pendingDuration ?? 0) > 0
                result.segments.append(url)
                result.segmentDurations.append(known ? (pendingDuration ?? 0) : (result.targetDuration ?? 0))
                pendingDuration = nil
            }
        }
        return result
    }

    /// The value of `name=` in a playlist tag, taken from the start of an attribute list, not from inside another
    /// name (`AVERAGE-BANDWIDTH` doesn't answer for `BANDWIDTH`).
    private static func attribute(_ name: String, in line: String) -> String? {
        for marker in [":\(name)=", ",\(name)="] {
            guard let range = line.range(of: marker) else { continue }
            let value = line[range.upperBound...].prefix { $0 != "," }
            return String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return nil
    }

    private static func text(of data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
    }

    // MARK: - Wording

    private static func describe(_ label: String, _ reply: Reply) -> String {
        guard let status = reply.status else { return "\(label): no answer (\(reply.failure ?? "unknown"))" }
        var line = "\(label) HTTP \(status)"
        if let type = reply.contentType?.split(separator: ";").first, !type.isEmpty { line += " \(type)" }
        line += String(format: " %.1f KB in %.2f s", Double(reply.body.count) / 1024, reply.seconds)
        switch reply.end {
        case .sizeLimit: line += " (cut off at the size limit)"
        case .timeLimit: line += " (cut off at the time limit)"
        case .failed: line += " (\(reply.failure ?? "dropped"))"
        case .completed: break
        }
        return line
    }

    /// A summary when the provider could not be spoken to at all, or nil when it answered.
    private static func unreachable(_ reply: Reply, host: String, doing: String) -> String? {
        guard reply.status == nil || (reply.end == .failed && reply.body.isEmpty) else { return nil }
        return "Couldn't reach \(host) to \(doing): \(reply.failure ?? "no answer")."
    }

    /// What an HTTP error answer to a stream request means, in a sentence for the person watching.
    static func refusalText(_ status: Int, body: Data) -> String {
        let base: String
        switch status {
        case 401, 403:
            base = "The provider refused this stream (HTTP \(status)). Usually the account is already using all its connections, has expired, or the provider blocks this app (a different User-Agent in the playlist's settings can help)."
        case 404:
            base = "The provider has no HLS (m3u8) stream for this channel (HTTP 404). The channel may be offline, or HLS output may be turned off for the account."
        case 429:
            base = "The provider is limiting requests (HTTP 429). Wait a minute, then try again."
        case 500...599:
            base = "The provider's server failed (HTTP \(status)). Try again later."
        default:
            base = "The provider answered HTTP \(status) instead of a stream."
        }
        let said = classify(body) == .html ? htmlTitle(body) : snippet(of: body)
        guard let said else { return base }
        return base + " It said: \"\(said)\""
    }

    /// The first words of a plain-text or JSON body, on one line.
    private static func snippet(of body: Data, limit: Int = 80) -> String? {
        guard [.json, .text].contains(classify(body)) else { return nil }
        let flat = text(of: body).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func htmlTitle(_ body: Data) -> String? {
        let html = text(of: Data(body.prefix(4096)))
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let start = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<html.endIndex) else { return nil }
        let title = html[start.upperBound..<end.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return title.isEmpty ? nil : String(title.prefix(60))
    }

    // MARK: - Credentials

    /// The username and password carried by an Xtream-shaped URL (`/live/{user}/{pass}/{id}` or `/{user}/{pass}/{id}`)
    /// or a query, so a message that echoes them can be cleaned before anyone sees it.
    static func secrets(in url: URL) -> [String] {
        var found: [String] = []
        // The encoded path: a `/` inside a username is `%2F` there and must not be taken for a separator.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[0].lowercased() == "live" {
            found += [parts[1], parts[2]]
        } else if parts.count == 3 {
            found += [parts[0], parts[1]]
        }
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        where ["username", "user", "password", "pass", "token"].contains(item.name.lowercased()) {
            if let value = item.value { found.append(value) }
        }
        let decoded = found.compactMap { $0.removingPercentEncoding }
        return Array(Set(found + decoded)).filter { $0.count >= 3 }.sorted { $0.count > $1.count }
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "•••") }
    }

    /// AVFoundation's own User-Agent is `AppleCoreMedia/1.0.0.<build> (<device>; U; CPU OS <x_y> like Mac OS X; <locale>)`.
    /// A probe that introduced itself differently could be answered differently from the player.
    static var playerUserAgent: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let device = "Apple TV"
        #elseif os(macOS)
        let device = "Macintosh"
        #else
        let device = "iPhone"
        #endif
        return "AppleCoreMedia/1.0.0 (\(device); U; CPU OS \(version.majorVersion)_\(version.minorVersion) like Mac OS X; en_us)"
    }
}

// MARK: - Bounded network read

/// One GET that gives up after `byteLimit` bytes or `seconds`, whichever comes first. A live transport stream never
/// ends, so a plain `data(for:)` could wait for ever; this reads what it needs and lets go of the connection.
nonisolated private final class BoundedFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let byteLimit: Int
    private let seconds: TimeInterval
    private let started = Date()
    private let lock = NSLock()

    private var body = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<StreamProbe.Reply, Never>?
    private var reachedSizeLimit = false
    private var expired = false
    private var cancelledByCaller = false
    private var finished = false

    private init(byteLimit: Int, seconds: TimeInterval) {
        self.byteLimit = byteLimit
        self.seconds = seconds
    }

    static func get(_ url: URL, headers: [String: String]?, byteLimit: Int, seconds: TimeInterval,
                    protocolClasses: [AnyClass]?) async -> StreamProbe.Reply {
        let fetch = BoundedFetch(byteLimit: byteLimit, seconds: seconds)
        return await fetch.start(url: url, headers: headers, protocolClasses: protocolClasses)
    }

    private func start(url: URL, headers: [String: String]?, protocolClasses: [AnyClass]?) async -> StreamProbe.Reply {
        var request = URLRequest(url: url)
        request.timeoutInterval = seconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (name, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        if request.value(forHTTPHeaderField: StreamHTTPHeaders.userAgentKey) == nil {
            request.setValue(StreamProbe.playerUserAgent, forHTTPHeaderField: StreamHTTPHeaders.userAgentKey)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds + 2
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StreamProbe.Reply, Never>) in
                let task = session.dataTask(with: request)
                lock.lock()
                self.session = session
                self.task = task
                self.continuation = continuation
                let alreadyCancelled = cancelledByCaller
                lock.unlock()
                if alreadyCancelled { task.cancel() }
                task.resume()
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.expire() }
            }
        } onCancel: {
            self.cancelFromOutside()
        }
    }

    private func expire() {
        lock.lock()
        let task = finished ? nil : self.task
        if task != nil { expired = true }
        lock.unlock()
        task?.cancel()
    }

    private func cancelFromOutside() {
        lock.lock()
        cancelledByCaller = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let room = byteLimit - body.count
        if room > 0 { body.append(data.prefix(room)) }
        let full = body.count >= byteLimit
        if full { reachedSizeLimit = true }
        lock.unlock()
        if full { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let response = self.response
        let body = self.body
        let sizeLimited = reachedSizeLimit
        let timedOut = expired || (error as? URLError)?.code == .timedOut
        let cancelled = cancelledByCaller
        lock.unlock()
        session.finishTasksAndInvalidate()

        var end = StreamProbe.Reply.End.completed
        var failure: String?
        if sizeLimited {
            end = .sizeLimit
        } else if let error {
            if timedOut, response != nil, !body.isEmpty {
                end = .timeLimit
            } else {
                end = .failed
                failure = cancelled ? "the check was cancelled" : timedOut ? "no answer in \(Int(seconds)) s" : Self.friendly(error)
            }
        }
        let length = response?.expectedContentLength ?? -1
        continuation?.resume(returning: StreamProbe.Reply(
            url: response?.url,
            status: response?.statusCode,
            contentType: response?.value(forHTTPHeaderField: "Content-Type"),
            contentLength: length > 0 ? length : nil,
            body: body,
            end: end,
            seconds: Date().timeIntervalSince(started),
            failure: failure
        ))
    }

    private static func friendly(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed: return "the host name doesn't resolve"
        case .cannotConnectToHost: return "the connection was refused"
        case .networkConnectionLost: return "the connection dropped"
        case .notConnectedToInternet: return "this device is offline"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "the secure connection failed"
        default: return urlError.localizedDescription
        }
    }
}
