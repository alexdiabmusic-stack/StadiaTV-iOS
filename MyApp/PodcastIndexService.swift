import Foundation
import CryptoKit

// MARK: - PodcastIndex.org API wrapper
// Auth: https://podcastindex-org.github.io/docs-api/#auth

actor PodcastIndexService {
    static let shared = PodcastIndexService()

    private let apiKey    = "Z2BVKVVVFURXWXEBZBJU"
    private let apiSecret = "vEshVhQLBKhkFZgmRZKVngzRFUedbF8MQJjnCCxW"
    private let base      = "https://api.podcastindex.org/api/1.0"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // MARK: - Signed request builder

    private func authHeaders() -> [String: String] {
        let ts   = "\(Int(Date().timeIntervalSince1970))"
        let raw  = apiKey + apiSecret + ts
        let hash = Insecure.SHA1.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [
            "X-Auth-Key":  apiKey,
            "X-Auth-Date": ts,
            "Authorization": hash,
            "User-Agent":  "StadiaTV/1.0"
        ]
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(string: base + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Public API

    /// Full-text podcast search.
    func searchPodcasts(query: String, max: Int = 20) async throws -> [PIFeed] {
        let r: PISearchResponse = try await get("/search/byterm",
            query: ["q": query, "max": "\(max)", "fulltext": ""])
        return r.feeds
    }

    /// Episodes for any RSS feed URL (PodcastIndex proxies the feed).
    func episodes(forFeedURL url: URL, max: Int = 15) async throws -> [PIEpisode] {
        let r: PIEpisodesResponse = try await get("/episodes/byfeedurl",
            query: ["url": url.absoluteString, "max": "\(max)"])
        return r.items
    }

    /// Look up a single podcast by its feed URL.
    func podcast(forFeedURL url: URL) async throws -> PIFeed? {
        struct Wrapper: Decodable { let feed: PIFeed? }
        let r: Wrapper = try await get("/podcasts/byfeedurl",
            query: ["url": url.absoluteString])
        return r.feed
    }
}

// MARK: - Lightweight RSS fallback parser
// Used when PodcastIndex cannot find episodes for a feed.

final class RSSFeedParser: NSObject, XMLParserDelegate {

    struct ParseResult {
        var podcastTitle = ""
        var artworkURL: URL?
        var episodes: [PodcastEpisode] = []
    }

    private var result = ParseResult()
    private var feedURL: URL
    private var currentItem: [String: String] = [:]
    private var currentKey = ""
    private var insideItem = false
    private var buffer = ""

    init(feedURL: URL) { self.feedURL = feedURL }

    func parse(data: Data) -> ParseResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        buffer = ""
        if el == "item" || el == "entry" { insideItem = true; currentItem = [:] }
        if el == "enclosure" || el == "link" {
            let url = attributes["url"] ?? attributes["href"] ?? ""
            let type = attributes["type"] ?? ""
            if (type.hasPrefix("audio") || type.isEmpty), !url.isEmpty {
                currentItem["enclosureUrl"] = url
            }
        }
        if el == "itunes:image" || el == "image" {
            if let href = attributes["href"] { currentItem["artwork"] = href }
        }
        currentKey = el
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideItem {
            switch el {
            case "title": currentItem["title"] = text
            case "description", "itunes:summary": currentItem["description"] = text
            case "guid", "id": currentItem["guid"] = text
            case "pubDate", "published", "updated": currentItem["pubDate"] = text
            case "itunes:duration": currentItem["duration"] = text
            default: break
            }
            if el == "item" || el == "entry" {
                insideItem = false
                buildEpisode()
            }
        } else {
            if el == "title" && result.podcastTitle.isEmpty { result.podcastTitle = text }
            if el == "itunes:image" || (el == "url" && currentKey == "url") {
                if result.artworkURL == nil { result.artworkURL = URL(string: text) }
            }
        }
        buffer = ""
    }

    private func buildEpisode() {
        guard let rawURL = currentItem["enclosureUrl"], let audioURL = URL(string: rawURL) else { return }
        let id = currentItem["guid"] ?? rawURL
        let dur: TimeInterval = {
            guard let d = currentItem["duration"] else { return 0 }
            let parts = d.split(separator: ":").compactMap { Double($0) }
            switch parts.count {
            case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 2: return parts[0] * 60 + parts[1]
            case 1: return parts[0]
            default: return 0
            }
        }()
        let date: Date = {
            guard let raw = currentItem["pubDate"] else { return .distantPast }
            let fmt = DateFormatter()
            for f in ["EEE, dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
                fmt.dateFormat = f
                if let d = fmt.date(from: raw) { return d }
            }
            return .distantPast
        }()
        let ep = PodcastEpisode(
            id: id,
            podcastID: feedURL.absoluteString,
            podcastTitle: currentItem["title"] ?? "",
            podcastArtworkURL: nil,
            title: currentItem["title"] ?? "(No title)",
            episodeDescription: currentItem["description"] ?? "",
            audioURL: audioURL,
            duration: dur,
            publishedAt: date,
            feedURL: feedURL
        )
        result.episodes.append(ep)
    }
}
