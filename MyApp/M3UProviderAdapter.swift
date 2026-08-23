import Foundation

/// Loads channels from an M3U/M3U8 playlist URL.
/// Parsing runs on a background thread; no network or parse work reaches the main thread.
struct M3UProviderAdapter: LiveProviderAdapter {
    let provider: LiveProvider
    private let session: URLSession

    init(provider: LiveProvider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    func loadGroups() async throws -> [AdapterGroup] {
        let channels = try await loadChannels()
        var seen = Set<String>()
        return channels.compactMap { ch -> AdapterGroup? in
            guard let title = ch.groupTitle, !title.isEmpty, !seen.contains(title) else { return nil }
            seen.insert(title)
            return AdapterGroup(id: "\(provider.id)|\(title)", title: title)
        }
    }

    func loadChannels() async throws -> [AdapterChannel] {
        guard let urlString = provider.m3uURL, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LiveProviderError.missingConfiguration("M3U URL must begin with http:// or https://")
        }
        let (data, response) = try await session.data(from: url)
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
    static func parseM3U(_ text: String) -> [AdapterChannel] {
        var channels: [AdapterChannel] = []
        var pendingName: String?
        var pendingLogo: URL?
        var pendingGroup: String?
        var pendingTvgID: String?
        var pendingTvgName: String?
        var pendingCatchupSource: String?
        var pendingCatchupDays: Int = 0
        var pendingCatchupEnabled: Bool = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
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
            } else if line.hasPrefix("#") {
                continue
            } else if !line.isEmpty, let streamURL = URL(string: line) {
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
                    catchupSource: pendingCatchupSource
                ))
                pendingName = nil; pendingLogo = nil; pendingGroup = nil
                pendingTvgID = nil; pendingTvgName = nil
                pendingCatchupSource = nil; pendingCatchupDays = 0; pendingCatchupEnabled = false
            }
        }
        return channels
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        let value = String(after[..<end])
        return value.isEmpty ? nil : value
    }
}
