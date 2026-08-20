import Foundation
import OSLog

// MARK: - EPG.pw Configuration

nonisolated struct EPGPWConfiguration: Sendable {
    let baseURL: URL
    let cacheTTL: TimeInterval
    let staleTTL: TimeInterval
    let negativeCacheTTL: TimeInterval
    let requestTimeout: TimeInterval
    let maximumConcurrentRequests: Int
    let requestPacing: TimeInterval
    let enabled: Bool

    init(
        baseURL: URL = URL(string: "https://epg.pw")!,
        cacheTTL: TimeInterval = 6 * 3600,
        staleTTL: TimeInterval = 24 * 3600,
        negativeCacheTTL: TimeInterval = 45 * 60,
        requestTimeout: TimeInterval = 20,
        maximumConcurrentRequests: Int = 4,
        requestPacing: TimeInterval = 0.15,
        enabled: Bool = true
    ) {
        self.baseURL = baseURL
        self.cacheTTL = cacheTTL
        self.staleTTL = staleTTL
        self.negativeCacheTTL = negativeCacheTTL
        self.requestTimeout = requestTimeout
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.requestPacing = requestPacing
        self.enabled = enabled
    }

    func scheduleJSONURL(channelId: Int) -> URL {
        baseURL.appending(path: "api/epg.json").appending(queryItems: [URLQueryItem(name: "channel_id", value: String(channelId))])
    }

    func scheduleXMLURL(channelId: Int) -> URL {
        baseURL.appending(path: "api/epg.xml").appending(queryItems: [URLQueryItem(name: "channel_id", value: String(channelId))])
    }

    func channelDetailURL(channelId: Int) -> URL {
        baseURL.appending(path: "last/\(channelId).html").appending(queryItems: [URLQueryItem(name: "lang", value: "en")])
    }

    var canadaDirectoryURL: URL {
        baseURL.appending(path: "areas/ca.html").appending(queryItems: [URLQueryItem(name: "lang", value: "en")])
    }

    var unitedStatesDirectoryURL: URL {
        baseURL.appending(path: "areas/us.html").appending(queryItems: [URLQueryItem(name: "lang", value: "en")])
    }

    var allAreasDirectoryURL: URL {
        baseURL.appending(path: "areas/index.html").appending(queryItems: [URLQueryItem(name: "lang", value: "en")])
    }

    static let `default` = EPGPWConfiguration()
}

nonisolated enum EPGPWSourcePolicy {
    static var epgPWEnabled: Bool { true }
    static var providerEPGEnabled: Bool { true }
    static var epgShareFallbackEnabled: Bool { true }
}

// MARK: - EPG.pw Response Models

nonisolated struct EPGPWResponse: Decodable {
    let endDate: String?
    let name: String?
    let infoURL: String?
    let country: String?
    let description: String?
    let errorMessage: String?
    let provider: String?
    let sourceURL: String?
    let epgList: [EPGPWProgramme]
    let offset: String?
    let timezone: String?
    let errorCode: Int?
    let startDate: String?
    let icon: String?

    private enum CodingKeys: String, CodingKey {
        case endDate = "end_date"
        case name
        case infoURL = "info_url"
        case country
        case description
        case errorMessage = "error_message"
        case provider
        case sourceURL = "source_url"
        case epgList = "epg_list"
        case offset
        case timezone
        case errorCode = "error_code"
        case startDate = "start_date"
        case icon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        infoURL = try container.decodeIfPresent(String.self, forKey: .infoURL)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        epgList = (try? container.decode([EPGPWProgramme].self, forKey: .epgList)) ?? []
        offset = try container.decodeIfPresent(String.self, forKey: .offset)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
        errorCode = try container.decodeIfPresent(Int.self, forKey: .errorCode)
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }
}

nonisolated struct EPGPWProgramme: Decodable {
    let title: String
    let desc: String?
    let startDate: String

    private enum CodingKeys: String, CodingKey {
        case title
        case desc
        case startDate = "start_date"
    }
}

// MARK: - Mapping

nonisolated struct EPGPWMapping: Codable, Hashable, Identifiable, Sendable {
    let canonicalChannelId: String
    let canonicalName: String
    let epgpwChannelId: Int
    let epgpwName: String
    let country: String
    let matchMethod: String
    let confidence: Double
    let verified: Bool
    let lastValidated: String?

    var id: String { canonicalChannelId }

    private enum CodingKeys: String, CodingKey {
        case canonicalChannelId = "canonical_id"
        case canonicalName = "canonical_name"
        case epgpwChannelId = "epgpw_channel_id"
        case epgpwName = "epgpw_name"
        case country
        case matchMethod = "match_method"
        case confidence
        case verified
        case lastValidated = "last_validated"
    }
}

nonisolated struct EPGPWMappingRepository {
    private let mappingsByCanonicalId: [String: EPGPWMapping]

    init(mappings: [EPGPWMapping] = Self.loadBundledMappings()) {
        mappingsByCanonicalId = Dictionary(uniqueKeysWithValues: mappings.map { ($0.canonicalChannelId, $0) })
    }

    func mapping(for canonicalChannelId: String) -> EPGPWMapping? {
        mappingsByCanonicalId[canonicalChannelId]
    }

    var allMappings: [EPGPWMapping] {
        mappingsByCanonicalId.values.sorted { $0.canonicalName < $1.canonicalName }
    }

    private static func loadBundledMappings() -> [EPGPWMapping] {
        guard let url = Bundle.main.url(forResource: "epgpw_channel_map", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([EPGPWMapping].self, from: data)) ?? []
    }
}

// MARK: - Provider Output

nonisolated struct EPGPWFetchResult: Sendable {
    enum CacheState: String, Sendable {
        case fresh
        case stale
        case missing
        case negative
        case refreshed
    }

    let channelId: Int
    let mapping: EPGPWMapping
    let programmes: [EPGProgramme]
    let cacheState: CacheState
    let lastFetch: Date?
    let lastSuccessfulFetch: Date?
    let coverageStart: Date?
    let coverageEnd: Date?
    let httpStatus: Int?
    let responseBytes: Int?
    let errorMessage: String?
}

nonisolated struct EPGPWChannelDiagnostics: Sendable {
    let canonicalName: String
    let canonicalChannelId: String
    let epgpwChannelId: Int
    let epgpwName: String
    let country: String
    let matchMethod: String
    let confidence: Double
    let verified: Bool
    let lastFetch: Date?
    let lastSuccessfulFetch: Date?
    let coverageStart: Date?
    let coverageEnd: Date?
    let programmeCount: Int
    let current: String?
    let next: String?
    let cacheState: String
    let requestState: String
}

// MARK: - Actor-backed Provider

actor EPGPWProvider {
    static let sourceId = "epgpw"
    static let sourcePriority = 0

    private let configuration: EPGPWConfiguration
    private let session: URLSession
    private let cacheDir: URL
    private let logger = Logger(subsystem: "StadiaTV", category: "EPGPW")
    private var inFlight: [Int: Task<EPGPWFetchResult, Error>] = [:]
    private var activeRequests = 0
    private var lastRequestStart = Date.distantPast

    init(configuration: EPGPWConfiguration = .default, cacheDir: URL) {
        self.configuration = configuration
        self.cacheDir = cacheDir.appendingPathComponent("EPGPW", isDirectory: true)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = configuration.requestTimeout
        cfg.timeoutIntervalForResource = configuration.requestTimeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    func programmes(for mapping: EPGPWMapping, forceRefresh: Bool = false) async throws -> EPGPWFetchResult {
        guard configuration.enabled, EPGPWSourcePolicy.epgPWEnabled else {
            throw EPGPWError.disabled
        }

        if !forceRefresh, let cached = readCache(for: mapping), cached.isFresh(configuration: configuration) {
            return cached.result(mapping: mapping, cacheState: .fresh)
        }

        if !forceRefresh, let cached = readCache(for: mapping), cached.isNegativeFresh(configuration: configuration) {
            return cached.result(mapping: mapping, cacheState: .negative)
        }

        if let task = inFlight[mapping.epgpwChannelId] {
            return try await task.value
        }

        let stale = readCache(for: mapping)
        let task = Task<EPGPWFetchResult, Error> { [configuration, session, cacheDir] in
            try await self.waitForTurn()
            defer { Task { self.finishRequest() } }
            return try await Self.fetch(mapping: mapping, configuration: configuration, session: session, cacheDir: cacheDir, stale: stale)
        }
        inFlight[mapping.epgpwChannelId] = task
        do {
            let result = try await task.value
            inFlight[mapping.epgpwChannelId] = nil
            return result
        } catch {
            inFlight[mapping.epgpwChannelId] = nil
            if let stale, stale.isUsable(configuration: configuration) {
                return stale.result(mapping: mapping, cacheState: .stale, errorMessage: error.localizedDescription)
            }
            throw error
        }
    }

    private func waitForTurn() async throws {
        while activeRequests >= configuration.maximumConcurrentRequests {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        let elapsed = Date().timeIntervalSince(lastRequestStart)
        if elapsed < configuration.requestPacing {
            try await Task.sleep(nanoseconds: UInt64((configuration.requestPacing - elapsed) * 1_000_000_000))
        }
        activeRequests += 1
        lastRequestStart = Date()
    }

    private func finishRequest() {
        activeRequests = max(0, activeRequests - 1)
    }

    private static func fetch(
        mapping: EPGPWMapping,
        configuration: EPGPWConfiguration,
        session: URLSession,
        cacheDir: URL,
        stale: EPGPWCacheEntry?
    ) async throws -> EPGPWFetchResult {
        let requestStart = Date()
        var request = URLRequest(url: configuration.scheduleJSONURL(channelId: mapping.epgpwChannelId))
        request.timeoutInterval = configuration.requestTimeout
        if let etag = stale?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = stale?.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EPGPWError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw EPGPWError.invalidResponse }
        if http.statusCode == 304, let stale {
            var updated = stale
            updated.lastFetch = Date()
            writeCache(updated, cacheDir: cacheDir)
            return updated.result(mapping: mapping, cacheState: .fresh, httpStatus: http.statusCode, responseBytes: data.count)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 {
                throw EPGPWError.rateLimited(http.value(forHTTPHeaderField: "Retry-After"))
            }
            if http.statusCode == 404 {
                writeCache(EPGPWCacheEntry.negative(channelId: mapping.epgpwChannelId), cacheDir: cacheDir)
            }
            throw EPGPWError.httpStatus(http.statusCode)
        }

        let decoded: EPGPWResponse
        do {
            decoded = try JSONDecoder().decode(EPGPWResponse.self, from: data)
        } catch {
            throw EPGPWError.invalidJSON(error.localizedDescription)
        }

        let programmes = normalize(response: decoded, mapping: mapping)
        if programmes.isEmpty, !(decoded.errorMessage ?? "").isEmpty {
            writeCache(EPGPWCacheEntry.negative(channelId: mapping.epgpwChannelId, errorMessage: decoded.errorMessage), cacheDir: cacheDir)
            throw EPGPWError.api(decoded.errorMessage ?? "No EPG.pw programmes")
        }
        if programmes.isEmpty {
            let entry = EPGPWCacheEntry.negative(channelId: mapping.epgpwChannelId, errorMessage: decoded.errorMessage)
            writeCache(entry, cacheDir: cacheDir)
            return entry.result(mapping: mapping, cacheState: .negative, httpStatus: http.statusCode, responseBytes: data.count)
        }

        let entry = EPGPWCacheEntry(
            channelId: mapping.epgpwChannelId,
            lastFetch: Date(),
            lastSuccessfulFetch: Date(),
            coverageStart: programmes.map(\.start).min(),
            coverageEnd: programmes.compactMap(\.end).max(),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            errorMessage: decoded.errorMessage?.isEmpty == true ? nil : decoded.errorMessage,
            programmes: programmes.map(EPGPWCachedProgramme.init)
        )
        writeCache(entry, cacheDir: cacheDir)

        #if DEBUG
        let duration = Date().timeIntervalSince(requestStart)
        print("EPG.pw channel=\(mapping.epgpwChannelId) status=\(http.statusCode) duration=\(String(format: "%.2f", duration))s bytes=\(data.count) programmes=\(programmes.count) coverage=\(entry.coverageStart?.description ?? "nil")...\(entry.coverageEnd?.description ?? "nil")")
        #endif

        return entry.result(mapping: mapping, cacheState: .refreshed, httpStatus: http.statusCode, responseBytes: data.count)
    }

    private func readCache(for mapping: EPGPWMapping) -> EPGPWCacheEntry? {
        Self.readCache(channelId: mapping.epgpwChannelId, cacheDir: cacheDir)
    }

    private static func readCache(channelId: Int, cacheDir: URL) -> EPGPWCacheEntry? {
        let url = cacheFile(channelId: channelId, cacheDir: cacheDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EPGPWCacheEntry.self, from: data)
    }

    private static func writeCache(_ entry: EPGPWCacheEntry, cacheDir: URL) {
        let url = cacheFile(channelId: entry.channelId, cacheDir: cacheDir)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func cacheFile(channelId: Int, cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent("\(channelId).json")
    }

    private static func normalize(response: EPGPWResponse, mapping: EPGPWMapping) -> [EPGProgramme] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var seen = Set<String>()
        let starts = response.epgList.compactMap { item -> (EPGPWProgramme, Date)? in
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = formatter.date(from: item.startDate) else { return nil }
            return (item, start)
        }.sorted { $0.1 < $1.1 }

        var programmes: [EPGProgramme] = []
        for index in starts.indices {
            let item = starts[index].0
            let start = starts[index].1
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(mapping.canonicalChannelId)|\(Int(start.timeIntervalSince1970))|\(title.lowercased())"
            guard seen.insert(key).inserted else { continue }
            guard index + 1 < starts.count else { continue }
            let end = starts[index + 1].1
            guard end > start else { continue }
            programmes.append(EPGProgramme(
                id: "epgpw-\(mapping.epgpwChannelId)-\(Int(start.timeIntervalSince1970))-\(title.lowercased().hashValue)",
                epgChannelId: String(mapping.epgpwChannelId),
                canonicalChannelId: mapping.canonicalChannelId,
                title: title,
                subtitle: nil,
                description: item.desc,
                categories: [],
                start: start,
                end: end,
                imageURL: nil,
                season: nil,
                episode: nil,
                rating: nil,
                sourceId: Self.sourceId,
                sourcePriority: Self.sourcePriority,
                endTimeIsInferred: true
            ))
        }
        return programmes
    }
}

// MARK: - Cache

nonisolated private struct EPGPWCacheEntry: Codable, Sendable {
    let channelId: Int
    var lastFetch: Date
    var lastSuccessfulFetch: Date?
    var coverageStart: Date?
    var coverageEnd: Date?
    var etag: String?
    var lastModified: String?
    var errorMessage: String?
    var programmes: [EPGPWCachedProgramme]

    static func negative(channelId: Int, errorMessage: String? = nil) -> EPGPWCacheEntry {
        EPGPWCacheEntry(
            channelId: channelId,
            lastFetch: Date(),
            lastSuccessfulFetch: nil,
            coverageStart: nil,
            coverageEnd: nil,
            etag: nil,
            lastModified: nil,
            errorMessage: errorMessage,
            programmes: []
        )
    }

    func isFresh(configuration: EPGPWConfiguration) -> Bool {
        !programmes.isEmpty && Date().timeIntervalSince(lastFetch) < configuration.cacheTTL
    }

    func isUsable(configuration: EPGPWConfiguration) -> Bool {
        !programmes.isEmpty && Date().timeIntervalSince(lastFetch) < configuration.staleTTL
    }

    func isNegativeFresh(configuration: EPGPWConfiguration) -> Bool {
        programmes.isEmpty && Date().timeIntervalSince(lastFetch) < configuration.negativeCacheTTL
    }

    func result(
        mapping: EPGPWMapping,
        cacheState: EPGPWFetchResult.CacheState,
        httpStatus: Int? = nil,
        responseBytes: Int? = nil,
        errorMessage: String? = nil
    ) -> EPGPWFetchResult {
        EPGPWFetchResult(
            channelId: channelId,
            mapping: mapping,
            programmes: programmes.map { $0.programme(mapping: mapping) },
            cacheState: cacheState,
            lastFetch: lastFetch,
            lastSuccessfulFetch: lastSuccessfulFetch,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            httpStatus: httpStatus,
            responseBytes: responseBytes,
            errorMessage: errorMessage ?? self.errorMessage
        )
    }
}

nonisolated private struct EPGPWCachedProgramme: Codable, Sendable {
    let id: String
    let epgChannelId: String
    let title: String
    let description: String?
    let start: Date
    let end: Date
    let sourceId: String
    let sourcePriority: Int
    let endTimeIsInferred: Bool

    init(_ programme: EPGProgramme) {
        id = programme.id
        epgChannelId = programme.epgChannelId
        title = programme.title
        description = programme.description
        start = programme.start
        end = programme.end
        sourceId = programme.sourceId
        sourcePriority = programme.sourcePriority
        endTimeIsInferred = programme.endTimeIsInferred
    }

    func programme(mapping: EPGPWMapping) -> EPGProgramme {
        EPGProgramme(
            id: id,
            epgChannelId: epgChannelId,
            canonicalChannelId: mapping.canonicalChannelId,
            title: title,
            subtitle: nil,
            description: description,
            categories: [],
            start: start,
            end: end,
            imageURL: nil,
            season: nil,
            episode: nil,
            rating: nil,
            sourceId: sourceId,
            sourcePriority: sourcePriority,
            endTimeIsInferred: endTimeIsInferred
        )
    }
}

private enum EPGPWError: LocalizedError {
    case disabled
    case invalidResponse
    case invalidJSON(String)
    case network(String)
    case httpStatus(Int)
    case rateLimited(String?)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "EPG.pw is disabled"
        case .invalidResponse:
            return "EPG.pw returned an invalid response"
        case .invalidJSON(let message):
            return "EPG.pw JSON decode failed: \(message)"
        case .network(let message):
            return "EPG.pw network failed: \(message)"
        case .httpStatus(let status):
            return "EPG.pw HTTP status \(status)"
        case .rateLimited(let retryAfter):
            return "EPG.pw rate limited; Retry-After=\(retryAfter ?? "none")"
        case .api(let message):
            return "EPG.pw API error: \(message)"
        }
    }
}

// MARK: - Development Mapper

#if DEBUG
nonisolated struct EPGPWChannelMapper {
    struct Candidate: Codable {
        let epgpwId: Int
        let name: String
        let country: String
        let confidence: Double

        private enum CodingKeys: String, CodingKey {
            case epgpwId = "epgpw_id"
            case name
            case country
            case confidence
        }
    }

    struct ReportEntry: Codable {
        let canonical: String
        let canonicalId: String
        let candidates: [Candidate]
        let unresolvedReason: String?

        private enum CodingKeys: String, CodingKey {
            case canonical
            case canonicalId = "canonical_id"
            case candidates
            case unresolvedReason = "unresolved_reason"
        }
    }

    static func report(curatedChannels: [CuratedChannel], mappings: [EPGPWMapping]) -> [ReportEntry] {
        let mappedIds = Set(mappings.map(\.canonicalChannelId))
        return curatedChannels.filter { !mappedIds.contains($0.key) }.map { channel in
            ReportEntry(canonical: channel.name, canonicalId: channel.key, candidates: [], unresolvedReason: "No verified EPG.pw mapping")
        }
    }
}
#endif
