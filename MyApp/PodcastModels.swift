import Foundation

// MARK: - Bundled catalog types

struct PodcastCatalog: Decodable {
    let feeds: [CatalogFeed]

    struct CatalogFeed: Decodable, Identifiable {
        let id: String
        let title: String
        let feedURL: URL
        let sport: String
        let tags: [String]
        let language: String

        enum CodingKeys: String, CodingKey {
            case id, title, tags, language, sport
            case feedURL = "feed_url"
        }
    }
}

struct TeamPodcastRegistry: Decodable {
    let teams: [TeamPodcastSeed]
}

// MARK: - Domain models

struct Podcast: Identifiable, Hashable, Codable {
    let id: String          // feedURL.absoluteString – stable across sessions
    let title: String
    let publisher: String
    let feedURL: URL
    let artworkURL: URL?
    let podcastDescription: String
    let sport: String?
    let tags: [String]

    static func == (lhs: Podcast, rhs: Podcast) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PodcastEpisode: Identifiable, Hashable, Codable {
    let id: String
    let podcastID: String       // parent feedURL string
    let podcastTitle: String
    let podcastArtworkURL: URL?
    let title: String
    let episodeDescription: String
    let audioURL: URL
    let duration: TimeInterval  // seconds, 0 when unknown
    let publishedAt: Date
    let feedURL: URL

    var formattedDuration: String {
        guard duration > 0 else { return "" }
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }

    var relativeDate: String {
        let diff = Date().timeIntervalSince(publishedAt)
        if diff < 86_400 { return "Today" }
        if diff < 172_800 { return "Yesterday" }
        if diff < 604_800 { return "\(Int(diff / 86_400))d ago" }
        return publishedAt.formatted(date: .abbreviated, time: .omitted)
    }

    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - PodcastIndex API response shapes

struct PISearchResponse: Decodable {
    let feeds: [PIFeed]
}

struct PIFeed: Decodable {
    let id: Int
    let title: String
    let url: URL
    let image: URL?
    let author: String?
    let description: String?

    func toPodcast(sport: String? = nil, tags: [String] = []) -> Podcast {
        Podcast(id: url.absoluteString, title: title, publisher: author ?? "",
                feedURL: url, artworkURL: image,
                podcastDescription: description ?? "", sport: sport, tags: tags)
    }
}

struct PIEpisodesResponse: Decodable {
    let items: [PIEpisode]
}

struct PIEpisode: Decodable {
    let id: Int
    let title: String
    let description: String?
    let enclosureUrl: URL?
    let duration: Int?
    let datePublished: Double?
    let feedTitle: String?
    let feedImage: URL?
    let feedUrl: URL?

    func toEpisode() -> PodcastEpisode? {
        guard let audioURL = enclosureUrl, let feedURL = feedUrl else { return nil }
        return PodcastEpisode(
            id: "\(id)",
            podcastID: feedURL.absoluteString,
            podcastTitle: feedTitle ?? "",
            podcastArtworkURL: feedImage,
            title: title,
            episodeDescription: description ?? "",
            audioURL: audioURL,
            duration: TimeInterval(duration ?? 0),
            publishedAt: Date(timeIntervalSince1970: datePublished ?? 0),
            feedURL: feedURL
        )
    }
}
