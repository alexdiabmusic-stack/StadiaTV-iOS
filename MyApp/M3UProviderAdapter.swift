import Foundation

/// Loads channels from an M3U/M3U8 playlist URL.
/// Parsing runs on a background thread; no network or parse work reaches the main thread.
nonisolated struct M3UProviderAdapter: LiveProviderAdapter {
    let provider: LiveProvider
    private let session: URLSession

    init(provider: LiveProvider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    func loadGroups() async throws -> [AdapterGroup] {
        let (_, channels) = try await loadChannels()
        var seen = Set<String>()
        return channels.compactMap { ch -> AdapterGroup? in
            guard let title = ch.groupTitle, !title.isEmpty, !seen.contains(title) else { return nil }
            seen.insert(title)
            return AdapterGroup(id: "\(provider.id)|\(title)", title: title)
        }
    }

    func loadChannels() async throws -> (epgURL: String?, channels: [AdapterChannel]) {
        guard let urlString = provider.m3uURL, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LiveProviderError.missingConfiguration("M3U URL must begin with http:// or https://")
        }
        var request = URLRequest(url: url)
        if let userAgent = provider.userAgent?.trimmingCharacters(in: .whitespaces), !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: StreamHTTPHeaders.userAgentKey)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LiveProviderError.badResponse
        }
        return await Task.detached(priority: .userInitiated) {
            let text = String(decoding: data, as: UTF8.self)
            return M3UProviderAdapter.parseM3U(text)
        }.value
    }

    func resolveStream(for channel: LiveChannel) async throws -> StreamDescriptor {
        guard let stream = channel.primaryStream else { throw LiveProviderError.noStreamAvailable }
        return stream
    }

    // MARK: - M3U parser

    /// Parses raw M3U/M3U8 text into AdapterChannel records.
    /// Runs entirely off the main thread. Extracts tvg-id and tvg-name in addition
    /// to the existing tvg-logo and group-title, enabling reliable EPG matching downstream.
    ///
    /// Per-stream HTTP headers are collected from `#EXTVLCOPT:http-user-agent=` /
    /// `http-referrer=` / `http-origin=`, `#KODIPROP:inputstream.adaptive.stream_headers=`,
    /// `#EXTHTTP:{json}`, `user-agent=` / `http-user-agent=` / `referer=` attributes on
    /// `#EXTINF`, and the `url|User-Agent=…&Referer=…` pipe suffix. They apply to the next URL.
    static func parseM3U(_ text: String) -> (epgURL: String?, channels: [AdapterChannel]) {
        var channels: [AdapterChannel] = []
        var epgURL: String?
        var pendingName: String?
        var pendingLogo: URL?
        var pendingGroup: String?
        var pendingTvgID: String?
        var pendingTvgName: String?
        var pendingCatchupSource: String?
        var pendingCatchupDays: Int = 0
        var pendingCatchupEnabled: Bool = false
        var pendingHeaders: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTM3U") {
                epgURL = attribute("x-tvg-url", in: line)
            } else if line.hasPrefix("#EXTINF") {
                pendingLogo    = attribute("tvg-logo",    in: line).flatMap(URL.init(string:))
                pendingGroup   = attribute("group-title", in: line)
                pendingTvgID   = attribute("tvg-id",      in: line)
                pendingTvgName = attribute("tvg-name",    in: line)
                // Catch-up attributes
                pendingCatchupSource = attribute("catchup-source", in: line)
                    ?? attribute("catchup-template", in: line)
                pendingCatchupDays = attribute("catchup-days", in: line).flatMap(Int.init) ?? 0
                pendingCatchupEnabled = attribute("catchup", in: line) != nil
                    || pendingCatchupSource != nil
                if let commaIdx = line.lastIndex(of: ",") {
                    let after = String(line[line.index(after: commaIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    pendingName = after.isEmpty ? pendingTvgName : after
                }
                if pendingName?.isEmpty ?? true { pendingName = pendingTvgName }
                for key in ["user-agent", "http-user-agent", "referer", "referrer", "http-referrer", "http-referer", "origin", "http-origin"] {
                    if let value = headerAttribute(key, in: line), let name = StreamHTTPHeaders.canonicalName(key) {
                        pendingHeaders[name] = value
                    }
                }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst("#EXTVLCOPT:".count)
                if let equals = option.firstIndex(of: "=") {
                    let key = String(option[..<equals])
                    let value = String(option[option.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    // Only header options; VLC transport options like http-reconnect are ignored
                    // (canonicalName passes unknown names through unchanged).
                    if !value.isEmpty, let name = StreamHTTPHeaders.canonicalName(key), name != key {
                        pendingHeaders[name] = value
                    }
                }
            } else if line.hasPrefix("#KODIPROP:") {
                let prop = line.dropFirst("#KODIPROP:".count)
                let prefix = "inputstream.adaptive.stream_headers="
                if prop.lowercased().hasPrefix(prefix) {
                    pendingHeaders.merge(StreamHTTPHeaders.parsePairs(String(prop.dropFirst(prefix.count)))) { _, new in new }
                }
            } else if line.hasPrefix("#EXTHTTP:") {
                let json = Data(line.dropFirst("#EXTHTTP:".count).utf8)
                if let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                    for (key, value) in object {
                        guard let value = value as? String, !value.isEmpty,
                              let name = StreamHTTPHeaders.canonicalName(key) else { continue }
                        pendingHeaders[name] = value
                    }
                }
            } else if line.hasPrefix("#") {
                continue
            } else if !line.isEmpty,
                      case let (urlString, pipeHeaders) = StreamHTTPHeaders.splitPipeSuffix(line),
                      let streamURL = URL(string: urlString) {
                pendingHeaders.merge(pipeHeaders) { _, new in new }
                let name = pendingName ?? streamURL.lastPathComponent
                channels.append(AdapterChannel(
                    name: name,
                    streamURL: streamURL,
                    logoURL: pendingLogo,
                    groupTitle: pendingGroup,
                    tvgID: pendingTvgID,
                    tvgName: pendingTvgName,
                    rawIndex: channels.count,
                    archiveEnabled: pendingCatchupEnabled,
                    archiveDays: pendingCatchupDays,
                    catchupSource: pendingCatchupSource,
                    httpHeaders: pendingHeaders.isEmpty ? nil : pendingHeaders
                ))
                pendingHeaders = [:]
                pendingName = nil; pendingLogo = nil; pendingGroup = nil
                pendingTvgID = nil; pendingTvgName = nil
                pendingCatchupSource = nil; pendingCatchupDays = 0; pendingCatchupEnabled = false
            }
        }
        return (epgURL, channels)
    }

    /// Like `attribute(_:in:)` but requires the key to start a new attribute (preceded by a
    /// space), so `user-agent` doesn't match inside `http-user-agent`.
    private static func headerAttribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: " \(key)=\"", options: .caseInsensitive) else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        let value = String(after[..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        let value = String(after[..<end])
        return value.isEmpty ? nil : value
    }
}
