import Foundation

/// Helpers for the per-stream HTTP headers IPTV providers expect (User-Agent, Referer, Origin…).
///
/// Header names are normalised to their canonical HTTP casing so `user-agent`, `User-Agent`
/// and `http-user-agent` all end up under one key.
nonisolated enum StreamHTTPHeaders {
    static let userAgentKey = "User-Agent"

    /// Canonical header name for the aliases used by VLC/Kodi-style playlists.
    static func canonicalName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "user-agent", "http-user-agent", "useragent": return userAgentKey
        case "referer", "referrer", "http-referer", "http-referrer": return "Referer"
        case "origin", "http-origin": return "Origin"
        case "cookie", "http-cookie": return "Cookie"
        case "": return nil
        default:
            // Pass anything else through with its original casing (e.g. "X-Forwarded-For").
            return rawName.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Returns the User-Agent value regardless of header-name casing.
    static func userAgent(in headers: [String: String]?) -> String? {
        headers?.first { $0.key.caseInsensitiveCompare(userAgentKey) == .orderedSame }?.value
    }

    /// Combines stream-specific headers with the playlist-level default User-Agent.
    /// Stream headers win; returns nil when there is nothing to send.
    static func merged(_ headers: [String: String]?, defaultUserAgent: String?) -> [String: String]? {
        var result = headers ?? [:]
        if userAgent(in: result) == nil,
           let defaultUserAgent = defaultUserAgent?.trimmingCharacters(in: .whitespaces),
           !defaultUserAgent.isEmpty {
            result[userAgentKey] = defaultUserAgent
        }
        return result.isEmpty ? nil : result
    }

    /// Parses `key=value&key2=value2` pairs (URL-encoded), as used by
    /// `#KODIPROP:inputstream.adaptive.stream_headers=` and the `url|User-Agent=…` pipe suffix.
    static func parsePairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let rawName = String(pair[..<equals])
            let rawValue = String(pair[pair.index(after: equals)...])
            let decodedName = rawName.removingPercentEncoding ?? rawName
            let decodedValue = (rawValue.removingPercentEncoding ?? rawValue).trimmingCharacters(in: .whitespaces)
            guard let name = canonicalName(decodedName), !decodedValue.isEmpty else { continue }
            result[name] = decodedValue
        }
        return result
    }

    /// Splits a Kodi-style `url|User-Agent=…&Referer=…` line into the bare URL and its headers.
    static func splitPipeSuffix(_ line: String) -> (url: String, headers: [String: String]) {
        guard let pipe = line.firstIndex(of: "|") else { return (line, [:]) }
        let url = String(line[..<pipe]).trimmingCharacters(in: .whitespaces)
        let suffix = String(line[line.index(after: pipe)...])
        return (url, parsePairs(suffix))
    }

    /// Host plus path extension, for logs. Never includes the path or query, because
    /// Xtream stream URLs embed the account username and password.
    static func redactedDescription(of url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "no-ext" : url.pathExtension.lowercased()
        return "\(url.host ?? "unknown-host") · \(ext)"
    }
}
