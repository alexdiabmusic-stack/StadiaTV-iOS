import Foundation

#if DEBUG
/// Test-only seam: lets a test substitute a stubbed `URLSession` into adapters constructed
/// internally by app code (e.g. `EventChannelRefreshService`, which builds its own
/// `XtreamProviderAdapter` per playlist and has no injection point in its public API).
enum XtreamProviderAdapterTestHooks {
    nonisolated(unsafe) static var session: URLSession?
}
#endif

extension String {
    /// Percent-encodes the string for use as a single URL path segment, so characters like
    /// `/ ? # %` in an Xtream username or password can't break (or silently truncate) a
    /// `/live/{user}/{pass}/{id}` stream URL. Characters that are legal in a path segment
    /// (`@ : ! $ & ' ( ) * + , ; =`) stay as typed, so URLs for ordinary credentials are unchanged.
    nonisolated var xtreamPathSegment: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        allowed.insert(charactersIn: ";")   // a legal segment character that some Foundation builds leave out of urlPathAllowed
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// Loads live channels from an Xtream Codes server.
/// Category and stream fetches are parallel-friendly; decoding runs on a background thread.
nonisolated struct XtreamProviderAdapter: LiveProviderAdapter {
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
        let (data, _) = try await session.data(for: apiRequest(url))
        let cats = (try? JSONDecoder().decode([XtreamCategory].self, from: data)) ?? []
        return cats.map { AdapterGroup(id: $0.category_id, title: $0.category_name) }
    }

    func loadChannels() async throws -> (epgURL: String?, channels: [AdapterChannel]) {
        guard let (base, user, pass) = try baseComponents() else {
            throw LiveProviderError.missingConfiguration("Host or credentials missing")
        }
        let categories = try await fetchCategoryMap(base: base, user: user, pass: pass)
        let channels = try await liveStreams(base: base, user: user, pass: pass, categories: categories, categoryID: nil)
        // An empty list is how a panel says "expired", "banned" or "slow down" as often as it is a real lineup.
        // Accepting it would replace the channels the user already has with nothing.
        guard !channels.isEmpty else { throw LiveProviderError.noChannels }

        var epgComps = base
        epgComps.path = "/xmltv.php"
        epgComps.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass)
        ]
        return (epgComps.url?.absoluteString, channels)
    }

    /// `get_live_streams`, optionally scoped to one category (~16 KB / 0.35s per the provider's
    /// own docs vs. 6.9 MB for the full list) — an API call, not a stream connection, so this is
    /// safe to poll even on a single-connection account. Used by `EventChannelRefreshService`
    /// to keep event-slot channel names (which carry the fixture and change during the day)
    /// current without re-downloading the whole playlist. See MatchLinker/PROMPTS.md, Prompt 5.
    func liveStreams(categoryID: String) async throws -> [AdapterChannel] {
        guard let (base, user, pass) = try baseComponents() else {
            throw LiveProviderError.missingConfiguration("Host or credentials missing")
        }
        return try await liveStreams(base: base, user: user, pass: pass, categories: [categoryID: ""], categoryID: categoryID)
    }

    private func liveStreams(
        base: URLComponents, user: String, pass: String, categories: [String: String], categoryID: String?
    ) async throws -> [AdapterChannel] {
        var comps = base
        comps.path = "/player_api.php"
        var queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action",   value: "get_live_streams"),
        ]
        if let categoryID { queryItems.append(URLQueryItem(name: "category_id", value: categoryID)) }
        comps.queryItems = queryItems
        guard let url = comps.url else {
            throw LiveProviderError.missingConfiguration("Could not build stream request URL")
        }
        let (data, response) = try await session.data(for: apiRequest(url))
        guard let http = response as? HTTPURLResponse else { throw LiveProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw LiveProviderError.httpStatus(http.statusCode) }

        let streams: [XtreamStream]
        do {
            streams = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode([XtreamStream].self, from: data)
            }.value
        } catch {
            throw Self.explainUndecodable(data)
        }

        var hostBase = URLComponents(string: provider.host ?? "")
        hostBase?.queryItems = nil
        hostBase?.path = ""
        let hostString = hostBase?.string ?? (provider.host ?? "")
        // Credentials sit in the URL path, so characters like `/ ? # %` must be escaped.
        let userSegment = user.xtreamPathSegment
        let passSegment = pass.xtreamPathSegment

        return await Task.detached(priority: .userInitiated) {
            streams.compactMap { stream in
                let urlString = "\(hostString)/live/\(userSegment)/\(passSegment)/\(stream.stream_id).m3u8"
                guard let streamURL = URL(string: urlString) else { return nil }
                let groupTitle = stream.category_id.flatMap { categories[$0] }
                return AdapterChannel(
                    name: stream.name,
                    streamURL: streamURL,
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

    /// What a reply that isn't a list of streams means. A panel rejects a login with HTTP 200 and
    /// `{"user_info":{"auth":0}}`; anything else (an HTML block page, a maintenance notice) is just unexpected.
    private static func explainUndecodable(_ data: Data) -> LiveProviderError {
        struct Envelope: Decodable {
            struct UserInfo: Decodable { let auth: XtreamNumeric? }
            let user_info: UserInfo?
        }
        // A rejection is a few dozen bytes. Anything bigger is some other reply, and reading it here, on the caller's
        // actor, could mean parsing megabytes for nothing.
        if data.count <= 16_384,
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.user_info?.auth?.intValue == 0 {
            return .authenticationFailed
        }
        return .badResponse
    }

    func resolveStream(for channel: LiveChannel) async throws -> StreamDescriptor {
        guard let stream = channel.primaryStream else { throw LiveProviderError.noStreamAvailable }
        return stream
    }

    // MARK: - Per-channel EPG

    /// Now/next only (2-4 entries) — cheap enough to call for a channel the moment it
    /// becomes visible. Reads `start_timestamp`/`stop_timestamp` directly (epoch seconds),
    /// never a formatted date string, so no string date parsing is needed for this path.
    func shortEPG(streamID: Int, limit: Int = 4) async throws -> [XtreamEPGListing] {
        try await epgListings(action: "get_short_epg", streamID: streamID,
                              extra: [URLQueryItem(name: "limit", value: String(limit))])
    }

    /// Full multi-day schedule for one channel (~38-74KB, ~0.5-1s per the provider docs) —
    /// only worth calling for rows actually scrolled into view.
    func simpleDataTable(streamID: Int) async throws -> [XtreamEPGListing] {
        try await epgListings(action: "get_simple_data_table", streamID: streamID, extra: [])
    }

    private func epgListings(action: String, streamID: Int, extra: [URLQueryItem]) async throws -> [XtreamEPGListing] {
        guard let (base, user, pass) = try baseComponents() else {
            throw LiveProviderError.missingConfiguration("Host or credentials missing")
        }
        var comps = base
        comps.path = "/player_api.php"
        comps.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "stream_id", value: String(streamID)),
        ] + extra
        guard let url = comps.url else { return [] }
        let (data, response) = try await session.data(for: apiRequest(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LiveProviderError.badResponse
        }
        struct Envelope: Decodable { let epg_listings: [XtreamEPGListing]? }
        let envelope = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(Envelope.self, from: data)
        }.value
        return envelope.epg_listings ?? []
    }

    // MARK: - Account / connection-limit status

    /// Reads `user_info`/`server_info` from `player_api.php`. 401/403/429/5xx are reported
    /// as inconclusive — a probe failure doesn't mean the connection limit is reached, it
    /// means we don't know, and callers should fall back to the existing reactive handling
    /// (a 403/429 surfacing mid-stream) rather than guessing.
    func accountStatus() async -> XtreamAccountStatus {
        guard let (base, user, pass) = try? baseComponents() else {
            return XtreamAccountStatus(maxConnections: nil, activeConnections: nil, isInconclusive: true)
        }
        var comps = base
        comps.path = "/player_api.php"
        comps.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
        ]
        guard let url = comps.url else {
            return XtreamAccountStatus(maxConnections: nil, activeConnections: nil, isInconclusive: true)
        }
        do {
            let (data, response) = try await session.data(for: apiRequest(url))
            guard let http = response as? HTTPURLResponse else {
                return XtreamAccountStatus(maxConnections: nil, activeConnections: nil, isInconclusive: true)
            }
            if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 429 || http.statusCode >= 500 {
                return XtreamAccountStatus(maxConnections: nil, activeConnections: nil, isInconclusive: true)
            }
            guard (200..<300).contains(http.statusCode) else {
                return XtreamAccountStatus(maxConnections: nil, activeConnections: nil, isInconclusive: true)
            }
            struct Envelope: Decodable {
                struct UserInfo: Decodable {
                    let max_connections: XtreamNumeric?
                    let active_cons: XtreamNumeric?
                    let status: String?
                    let exp_date: XtreamNumeric?
                }
                // Read alongside user_info as instructed, even though nothing here
                // currently feeds the connection-limit decision below.
                struct ServerInfo: Decodable {
                    let url: String?
                    let timestamp_now: XtreamNumeric?
                }
                let user_info: UserInfo?
                let server_info: ServerInfo?
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let expDate = envelope.user_info?.exp_date?.intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return XtreamAccountStatus(
                maxConnections: envelope.user_info?.max_connections?.intValue,
                activeConnections: envelope.user_info?.active_cons?.intValue,
                status: envelope.user_info?.status,
                expiresAt: expDate,
                isInconclusive: false
            )
        } catch {
            return XtreamAccountStatus(maxConnections: nil, activeConnections: nil, isInconclusive: true)
        }
    }

    // MARK: - Helpers

    /// API request carrying the playlist's User-Agent, so providers that filter on it
    /// see the same client for the API calls and the streams.
    private func apiRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let userAgent = provider.userAgent?.trimmingCharacters(in: .whitespaces), !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: StreamHTTPHeaders.userAgentKey)
        }
        return request
    }

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
        let (data, _) = try await session.data(for: apiRequest(url))
        let cats = (try? JSONDecoder().decode([XtreamCategory].self, from: data)) ?? []
        // Panels sometimes repeat an id or send entries with none; the first title wins. A repeated key
        // would otherwise trap, taking the whole app down while a playlist opens.
        return Dictionary(cats.filter { !$0.category_id.isEmpty }.map { ($0.category_id, $0.category_name) },
                          uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Account / connection-limit status

struct XtreamAccountStatus {
    let maxConnections: Int?
    let activeConnections: Int?
    /// Raw `user_info.status` ("Active", "Expired", "Banned", "Disabled"...), for Settings.
    var status: String? = nil
    var expiresAt: Date? = nil
    /// True when the probe itself was inconclusive (network error, or a 401/403/429/5xx
    /// response) — as opposed to a successful response that simply had no connection info.
    let isInconclusive: Bool

    /// Whether starting one more connection (a second live stream) risks disrupting an
    /// existing one. Deliberately restrictive when we can't tell: an unknown limit or a
    /// limit of exactly one both block without needing to probe further.
    /// An inconclusive probe does NOT block proactively — the existing reactive handling
    /// (a 403/429 surfacing mid-stream) remains the safety net for that case.
    var blocksAdditionalConnection: Bool {
        if isInconclusive { return false }
        guard let max = maxConnections else { return true }
        if max <= 1 { return true }
        guard let active = activeConnections else { return true }
        return active >= max
    }
}

/// Xtream panels commonly send numeric fields as either a JSON number or a numeric string
/// depending on the panel software — this decodes either.
private struct XtreamNumeric: Decodable {
    let intValue: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            intValue = i
        } else if let s = try? c.decode(String.self) {
            intValue = Int(s)
        } else {
            intValue = nil
        }
    }
}

// MARK: - Per-channel EPG listing

struct XtreamEPGListing: Decodable {
    let id: String
    let epgChannelId: String?
    let title: String
    let description: String?
    let startTimestamp: Date
    let stopTimestamp: Date

    private enum CodingKeys: String, CodingKey {
        case id, channel_id, title, description, start_timestamp, stop_timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        epgChannelId = try? c.decode(String.self, forKey: .channel_id)
        let titleB64 = (try? c.decode(String.self, forKey: .title)) ?? ""
        title = Self.decodeBase64(titleB64) ?? titleB64
        let descB64 = try? c.decode(String.self, forKey: .description)
        description = descB64.flatMap(Self.decodeBase64)
        startTimestamp = Self.date(c, .start_timestamp) ?? Date()
        stopTimestamp = Self.date(c, .stop_timestamp) ?? startTimestamp.addingTimeInterval(1800)
    }

    private static func decodeBase64(_ s: String) -> String? {
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func date(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let i = try? container.decode(Int.self, forKey: key) { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let s = try? container.decode(String.self, forKey: key), let i = TimeInterval(s) {
            return Date(timeIntervalSince1970: i)
        }
        return nil
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
