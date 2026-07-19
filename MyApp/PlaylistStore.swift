import Foundation
import SwiftUI
import Combine

/// Owns the user's playlists, persists their configuration, and loads channels
/// (parsing M3U files and querying Xtream Codes servers).
@MainActor
final class PlaylistStore: ObservableObject {

    @Published private(set) var playlists: [Playlist] = []
    /// Channels loaded per playlist, keyed by playlist id.
    @Published private(set) var channelsByPlaylist: [UUID: [Channel]] = [:]
    @Published private(set) var loadingPlaylistIDs: Set<UUID> = []
    @Published var lastError: String?

    private let defaultsKey = "stadiatv.playlists.v1"
    private let session = URLSession(configuration: {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return c
    }())

    /// All channels across every loaded playlist — the pool the matcher searches.
    var allChannels: [Channel] {
        channelsByPlaylist.values.flatMap { $0 }
    }

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded.map { migrateCredentialsIfNeeded(for: $0) }
        persist()
    }

    private func persist() {
        let sanitized = playlists.map(\.sanitizedForPersistence)
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func migrateCredentialsIfNeeded(for playlist: Playlist) -> Playlist {
        guard playlist.kind == .xtream,
              let username = playlist.username, let password = playlist.password,
              !username.isEmpty, !password.isEmpty else {
            return playlist.sanitizedForPersistence
        }
        do {
            try KeychainStore.saveXtreamCredentials(
                XtreamCredentials(username: username, password: password),
                for: playlist.credentialID
            )
        } catch {
            lastError = "\(playlist.name): Couldn't secure saved credentials."
        }
        return playlist.sanitizedForPersistence
    }

    private func secureCredentialsIfNeeded(for playlist: Playlist) throws -> Playlist {
        guard playlist.kind == .xtream,
              let username = playlist.username, let password = playlist.password,
              !username.isEmpty, !password.isEmpty else {
            return playlist.sanitizedForPersistence
        }
        try KeychainStore.saveXtreamCredentials(
            XtreamCredentials(username: username, password: password),
            for: playlist.credentialID
        )
        return playlist.sanitizedForPersistence
    }

    // MARK: - Mutating

    func add(_ playlist: Playlist) {
        do {
            let secured = try secureCredentialsIfNeeded(for: playlist)
            playlists.append(secured)
            persist()
            Task { await refresh(secured) }
        } catch {
            lastError = "\(playlist.name): Couldn't save credentials securely."
        }
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let playlist = playlists[index]
            channelsByPlaylist[playlist.id] = nil
            if playlist.kind == .xtream {
                KeychainStore.deleteXtreamCredentials(for: playlist.credentialID)
            }
        }
        playlists.remove(atOffsets: offsets)
        persist()
    }

    func refreshAll() async {
        for playlist in playlists {
            await refresh(playlist)
        }
    }

    func channelCount(for playlist: Playlist) -> Int {
        channelsByPlaylist[playlist.id]?.count ?? 0
    }

    func isLoading(_ playlist: Playlist) -> Bool {
        loadingPlaylistIDs.contains(playlist.id)
    }

    // MARK: - Loading channels

    func refresh(_ playlist: Playlist) async {
        loadingPlaylistIDs.insert(playlist.id)
        defer { loadingPlaylistIDs.remove(playlist.id) }
        do {
            let channels: [Channel]
            switch playlist.kind {
            case .m3u:
                channels = try await loadM3U(playlist)
            case .xtream:
                channels = try await loadXtream(playlist)
            }
            channelsByPlaylist[playlist.id] = channels
        } catch {
            lastError = "\(playlist.name): \(error.localizedDescription)"
        }
    }

    // MARK: M3U

    private func loadM3U(_ playlist: Playlist) async throws -> [Channel] {
        guard let urlString = playlist.m3uURL, let url = URL(string: urlString), Self.isSupportedPlaylistURL(url) else {
            throw PlaylistError.unsupportedURL
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlaylistError.badResponse
        }
        let text = String(decoding: data, as: UTF8.self)
        return Self.parseM3U(text, playlist: playlist)
    }

    /// Parses an M3U/M3U8 playlist body into channels.
    static func parseM3U(_ text: String, playlist: Playlist) -> [Channel] {
        var channels: [Channel] = []
        var pendingName: String?
        var pendingLogo: String?
        var pendingGroup: String?

        let lines = text.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                pendingLogo = attribute("tvg-logo", in: line)
                pendingGroup = attribute("group-title", in: line)
                // Channel display name follows the last comma.
                if let commaIndex = line.lastIndex(of: ",") {
                    pendingName = String(line[line.index(after: commaIndex)...]).trimmingCharacters(in: .whitespaces)
                }
                if pendingName?.isEmpty ?? true {
                    pendingName = attribute("tvg-name", in: line)
                }
            } else if line.hasPrefix("#") {
                continue // other directives
            } else if !line.isEmpty, let streamURL = URL(string: line) {
                let name = pendingName ?? streamURL.lastPathComponent
                channels.append(Channel(
                    id: "\(playlist.id)-\(channels.count)-\(line.hashValue)",
                    name: name,
                    streamURL: streamURL,
                    logoURL: pendingLogo.flatMap(URL.init(string:)),
                    group: pendingGroup,
                    playlistID: playlist.id,
                    playlistName: playlist.name
                ))
                pendingName = nil; pendingLogo = nil; pendingGroup = nil
            }
        }
        return channels
    }

    /// Extracts an attribute like tvg-logo="..." from an #EXTINF line.
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    // MARK: Xtream Codes

    private func loadXtream(_ playlist: Playlist) async throws -> [Channel] {
        guard let host = playlist.host, var base = URLComponents(string: host), Self.isSupportedPlaylistScheme(base.scheme) else {
            throw PlaylistError.unsupportedURL
        }
        guard let credentials = try KeychainStore.xtreamCredentials(for: playlist.credentialID) else {
            throw PlaylistError.missingCredentials
        }
        let user = credentials.username
        let pass = credentials.password
        // Categories (for group names) then live streams.
        let categories = try await xtreamCategories(base: base, user: user, pass: pass)

        base.path = "/player_api.php"
        base.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action", value: "get_live_streams"),
        ]
        guard let url = base.url else { throw PlaylistError.invalidConfiguration }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlaylistError.badResponse
        }
        let streams = try JSONDecoder().decode([XtreamStream].self, from: data)

        // Base host without path for building stream URLs.
        var streamHost = URLComponents(string: host)
        streamHost?.queryItems = nil
        streamHost?.path = ""
        let hostString = streamHost?.string ?? host

        return streams.map { stream in
            let urlString = "\(hostString)/live/\(user)/\(pass)/\(stream.stream_id).m3u8"
            let group = stream.category_id.flatMap { categories[$0] }
            return Channel(
                id: "\(playlist.id)-\(stream.stream_id)",
                name: stream.name,
                streamURL: URL(string: urlString) ?? URL(string: hostString)!,
                logoURL: stream.stream_icon.flatMap(URL.init(string:)),
                group: group,
                playlistID: playlist.id,
                playlistName: playlist.name
            )
        }
    }

    private func xtreamCategories(base: URLComponents, user: String, pass: String) async throws -> [String: String] {
        var comps = base
        comps.path = "/player_api.php"
        comps.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action", value: "get_live_categories"),
        ]
        guard let url = comps.url else { return [:] }
        do {
            let (data, _) = try await session.data(from: url)
            let cats = try JSONDecoder().decode([XtreamCategory].self, from: data)
            return Dictionary(uniqueKeysWithValues: cats.map { ($0.category_id, $0.category_name) })
        } catch {
            return [:]
        }
    }

    private static func isSupportedPlaylistURL(_ url: URL) -> Bool {
        isSupportedPlaylistScheme(url.scheme)
    }

    private static func isSupportedPlaylistScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    enum PlaylistError: LocalizedError {
        case invalidConfiguration
        case unsupportedURL
        case missingCredentials
        case badResponse
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "The playlist details are incomplete or invalid."
            case .unsupportedURL: return "Playlist and Xtream API URLs must begin with http:// or https://."
            case .missingCredentials: return "Xtream credentials are missing. Remove and re-add this playlist."
            case .badResponse: return "The server returned an unexpected response."
            }
        }
    }
}

// MARK: - Xtream DTOs

private struct XtreamStream: Decodable {
    let name: String
    let stream_id: Int
    let stream_icon: String?
    let category_id: String?

    private enum CodingKeys: String, CodingKey {
        case name, stream_id, stream_icon, category_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Channel"
        // stream_id may be a number or a string depending on provider.
        if let intID = try? c.decode(Int.self, forKey: .stream_id) {
            stream_id = intID
        } else if let strID = try? c.decode(String.self, forKey: .stream_id), let i = Int(strID) {
            stream_id = i
        } else {
            stream_id = 0
        }
        stream_icon = try? c.decode(String.self, forKey: .stream_icon)
        if let strCat = try? c.decode(String.self, forKey: .category_id) {
            category_id = strCat
        } else if let intCat = try? c.decode(Int.self, forKey: .category_id) {
            category_id = String(intCat)
        } else {
            category_id = nil
        }
    }
}

private struct XtreamCategory: Decodable {
    let category_id: String
    let category_name: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .category_id) {
            category_id = s
        } else if let i = try? c.decode(Int.self, forKey: .category_id) {
            category_id = String(i)
        } else {
            category_id = ""
        }
        category_name = (try? c.decode(String.self, forKey: .category_name)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case category_id, category_name
    }
}
