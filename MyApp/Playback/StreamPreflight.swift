import Foundation

/// Quick reachability probe for failover candidates, so Auto doesn't spend a full
/// start-up timeout on a mirror that is already dead.
nonisolated enum StreamPreflight {
    enum Result: Equatable, Sendable {
        case reachable
        case dead
        /// Timed out or ambiguous. Treated as usable; a slow response isn't proof the stream is down.
        case inconclusive
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// GETs the URL and reads only the first few bytes. Valid if the body starts with
    /// `#EXTM3U` or the response is a video/MPEG-TS/HLS content type.
    static func probe(url: URL, headers: [String: String]?, timeout: TimeInterval = 3) async -> Result {
        await withTaskGroup(of: Result.self) { group in
            group.addTask { await fetch(url: url, headers: headers) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .inconclusive
            }
            let first = await group.next() ?? .inconclusive
            group.cancelAll()
            return first
        }
    }

    private static func fetch(url: URL, headers: [String: String]?) async -> Result {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            // 401/403/429/5xx don't mean the stream is down — they're as likely to be the
            // account's own connection limit rejecting this probe (see MatchLinker/PROMPTS.md,
            // Prompt 6), which must never mark a healthy mirror dead.
            let inconclusiveCodes: Set<Int> = [401, 403, 429]
            if inconclusiveCodes.contains(http.statusCode) || http.statusCode >= 500 { return .inconclusive }
            guard (200..<400).contains(http.statusCode) else { return .dead }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.hasPrefix("video/") || contentType.contains("mpegurl") || contentType.contains("mp2t") {
                return .reachable
            }
            var prefix: [UInt8] = []
            for try await byte in bytes {
                prefix.append(byte)
                if prefix.count >= 7 { break }
            }
            if prefix == Array("#EXTM3U".utf8) { return .reachable }
            // MPEG-TS packets start with the 0x47 sync byte.
            if prefix.first == 0x47 { return .reachable }
            // An HTML/JSON error page served with 200 is a dead stream.
            if contentType.contains("text/html") || contentType.contains("json") { return .dead }
            return .inconclusive
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badURL, .unsupportedURL,
                 .badServerResponse, .fileDoesNotExist, .resourceUnavailable:
                return .dead
            // A 401/403-style challenge surfacing as a URLError rather than a plain
            // HTTPURLResponse is the same connection-limit-rejection case handled above —
            // never grounds for marking the mirror dead.
            case .userAuthenticationRequired:
                return .inconclusive
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }
}
