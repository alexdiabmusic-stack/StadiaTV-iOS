import Foundation

/// Loads live channels from an Xtream Codes server.
/// Category and stream fetches are parallel-friendly; decoding runs on a background thread.
struct XtreamProviderAdapter: LiveProviderAdapter {
    let provider: LiveProvider
    private let session: URLSession

    init(provider: LiveProvider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    func loadGroups() async throws -> [AdapterGroup] {
        guard let (base, user, pass) = try baseComponents() else {
            throw LiveProviderError.missingConfiguration("Host or credentials missing")
        }
        var comps = base
        comps.path = "/player_api.php"
        comps.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action",   value: "get_live_categories"),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let cats = (try? JSONDecoder().decode([XtreamCategory].self, from: data)) ?? []
        return cats.map { AdapterGroup(id: $0.category_id, title: $0.category_name) }
    }

    func loadChannels() async throws -> [AdapterChannel] {
        guard let (base, user, pass) = try baseComponents() else {
            throw LiveProviderError.missingConfiguration("Host or credentials missing")
        }
        let categories = try await fetchCategoryMap(base: base, user: user, pass: pass)

        var comps = base
        comps.path = "/player_api.php"
        comps.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action",   value: "get_live_streams"),
        ]
        guard let url = comps.url else {
            throw LiveProviderError.missingConfiguration("Could not build stream request URL")
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LiveProviderError.badResponse
        }

        let streams = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode([XtreamStream].self, from: data)
        }.value

        var hostBase = URLComponents(string: provider.host ?? "")
        hostBase?.queryItems = nil
        hostBase?.path = ""
        let hostString = hostBase?.string ?? (provider.host ?? "")

        return await Task.detached(priority: .userInitiated) {
            streams.map { stream in
                let urlString  = "\(hostString)/live/\(user)/\(pass)/\(stream.stream_id).m3u8"
                let groupTitle = stream.category_id.flatMap { categories[$0] }
                return AdapterChannel(
                    name: stream.name,
                    streamURL: URL(string: urlString) ?? URL(string: hostString)!,
                    logoURL: stream.stream_icon.flatMap(URL.init(string:)),
                    groupTitle: groupTitle,
                    tvgID: stream.epg_channel_id,
                    rawIndex: 0,
                    xtreamStreamID: stream.stream_id,
                    xtreamCategoryID: stream.category_id,
                    archiveEnabled: stream.tv_archive == 1,
                    archiveDays: stream.tv_archive_duration ?? 0
                )
            }
        }.value
    }

    func resolveStream(for channel: LiveChannel) async throws -> StreamDescriptor {
        guard let stream = channel.primaryStream else { throw LiveProviderError.noStreamAvailable }
        return stream
    }

    // MARK: - Helpers

    private func baseComponents() throws -> (URLComponents, String, String)? {
        guard let host = provider.host, let base = URLComponents(string: host) else { return nil }
        guard let creds = try KeychainStore.xtreamCredentials(for: provider.credentialID) else {
            throw LiveProviderError.authenticationFailed
        }
        return (base, creds.username, creds.password)
    }

    private func fetchCategoryMap(base: URLComponents, user: String, pass: String) async throws -> [String: String] {
        var comps = base
        comps.path = "/player_api.php"
        comps.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action",   value: "get_live_categories"),
        ]
        guard let url = comps.url else { return [:] }
        let (data, _) = try await session.data(from: url)
        let cats = (try? JSONDecoder().decode([XtreamCategory].self, from: data)) ?? []
        return Dictionary(uniqueKeysWithValues: cats.map { ($0.category_id, $0.category_name) })
    }
}

// MARK: - Xtream DTOs (private)

private struct XtreamStream: Decodable {
    let name: String
    let stream_id: Int
    let stream_icon: String?
    let category_id: String?
    let epg_channel_id: String?
    let tv_archive: Int?
    let tv_archive_duration: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Channel"
        if let i = try? c.decode(Int.self, forKey: .stream_id) {
            stream_id = i
        } else if let s = try? c.decode(String.self, forKey: .stream_id), let i = Int(s) {
            stream_id = i
        } else {
            stream_id = 0
        }
        stream_icon = try? c.decode(String.self, forKey: .stream_icon)
        if let s = try? c.decode(String.self, forKey: .category_id) {
            category_id = s
        } else if let i = try? c.decode(Int.self, forKey: .category_id) {
            category_id = String(i)
        } else {
            category_id = nil
        }
        epg_channel_id       = try? c.decode(String.self, forKey: .epg_channel_id)
        tv_archive           = try? c.decode(Int.self,    forKey: .tv_archive)
        tv_archive_duration  = try? c.decode(Int.self,    forKey: .tv_archive_duration)
    }

    private enum CodingKeys: String, CodingKey {
        case name, stream_id, stream_icon, category_id,
             epg_channel_id, tv_archive, tv_archive_duration
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

    private enum CodingKeys: String, CodingKey { case category_id, category_name }
}
