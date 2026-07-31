import Foundation

// MARK: - Podcast medium (audio vs video)

enum PodcastMedium: String, Codable {
    case audio, video

    /// Map PodcastIndex `medium` field strings to our enum.
    static func from(piMedium: String?) -> PodcastMedium {
        switch piMedium?.lowercased() {
        case "video", "film", "videol": return .video
        default: return .audio
        }
    }

    /// Infer medium from a MIME type string (enclosureType).
    static func from(mimeType: String?) -> PodcastMedium {
        guard let mime = mimeType?.lowercased() else { return .audio }
        return mime.hasPrefix("video") ? .video : .audio
    }
}

// MARK: - Bundled catalog types

struct PodcastCatalog: Decodable {
    let feeds: [CatalogFeed]

    struct CatalogFeed: Decodable, Identifiable {
        let id: String
        let title: String
        let feedURL: URL
        let imageURL: URL?   // pre-populated from DB catalog; optional
        let sport: String
        let tags: [String]
        let language: String

        enum CodingKeys: String, CodingKey {
            case id, title, tags, language, sport
            case feedURL = "feed_url"
            case imageURL = "image_url"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            feedURL = try c.decode(URL.self, forKey: .feedURL)
            imageURL = try? c.decode(URL.self, forKey: .imageURL)
            sport = try c.decode(String.self, forKey: .sport)
            tags = (try? c.decode([String].self, forKey: .tags)) ?? []
            language = (try? c.decode(String.self, forKey: .language)) ?? "en"
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
    var medium: PodcastMedium

    static func == (lhs: Podcast, rhs: Podcast) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Custom Codable to default medium to .audio for legacy persisted data
    enum CodingKeys: String, CodingKey {
        case id, title, publisher, feedURL, artworkURL, podcastDescription, sport, tags, medium
    }

    init(id: String, title: String, publisher: String, feedURL: URL, artworkURL: URL?,
         podcastDescription: String, sport: String?, tags: [String], medium: PodcastMedium = .audio) {
        self.id = id; self.title = title; self.publisher = publisher; self.feedURL = feedURL
        self.artworkURL = artworkURL; self.podcastDescription = podcastDescription
        self.sport = sport; self.tags = tags; self.medium = medium
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        publisher = try c.decode(String.self, forKey: .publisher)
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        artworkURL = try? c.decode(URL.self, forKey: .artworkURL)
        podcastDescription = (try? c.decode(String.self, forKey: .podcastDescription)) ?? ""
        sport = try? c.decode(String.self, forKey: .sport)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        medium = (try? c.decode(PodcastMedium.self, forKey: .medium)) ?? .audio
    }
}

struct PodcastEpisode: Identifiable, Hashable, Codable {
    let id: String
    let podcastID: String       // parent feedURL string
    let podcastTitle: String
    let podcastArtworkURL: URL?
    let title: String
    let episodeDescription: String
    let audioURL: URL           // works for both audio and video enclosures
    let duration: TimeInterval  // seconds, 0 when unknown
    let publishedAt: Date
    let feedURL: URL
    var medium: PodcastMedium

    var isVideo: Bool { medium == .video }

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

    enum CodingKeys: String, CodingKey {
        case id, podcastID, podcastTitle, podcastArtworkURL, title, episodeDescription
        case audioURL, duration, publishedAt, feedURL, medium
    }

    init(id: String, podcastID: String, podcastTitle: String, podcastArtworkURL: URL?,
         title: String, episodeDescription: String, audioURL: URL, duration: TimeInterval,
         publishedAt: Date, feedURL: URL, medium: PodcastMedium = .audio) {
        self.id = id; self.podcastID = podcastID; self.podcastTitle = podcastTitle
        self.podcastArtworkURL = podcastArtworkURL; self.title = title
        self.episodeDescription = episodeDescription; self.audioURL = audioURL
        self.duration = duration; self.publishedAt = publishedAt; self.feedURL = feedURL
        self.medium = medium
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        podcastID = try c.decode(String.self, forKey: .podcastID)
        podcastTitle = (try? c.decode(String.self, forKey: .podcastTitle)) ?? ""
        podcastArtworkURL = try? c.decode(URL.self, forKey: .podcastArtworkURL)
        title = try c.decode(String.self, forKey: .title)
        episodeDescription = (try? c.decode(String.self, forKey: .episodeDescription)) ?? ""
        audioURL = try c.decode(URL.self, forKey: .audioURL)
        duration = (try? c.decode(TimeInterval.self, forKey: .duration)) ?? 0
        publishedAt = (try? c.decode(Date.self, forKey: .publishedAt)) ?? Date()
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        medium = (try? c.decode(PodcastMedium.self, forKey: .medium)) ?? .audio
    }
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
    let medium: String?     // "podcast", "video", "film", etc.

    var podcastMedium: PodcastMedium { PodcastMedium.from(piMedium: medium) }

    func toPodcast(sport: String? = nil, tags: [String] = []) -> Podcast {
        Podcast(id: url.absoluteString, title: title, publisher: author ?? "",
                feedURL: url, artworkURL: image,
                podcastDescription: description ?? "", sport: sport, tags: tags,
                medium: podcastMedium)
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
    let enclosureType: String?  // "audio/mpeg", "video/mp4", etc.
    let duration: Int?
    let datePublished: Double?
    let feedTitle: String?
    let feedImage: URL?
    let feedUrl: URL?

    var podcastMedium: PodcastMedium { PodcastMedium.from(mimeType: enclosureType) }

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
            feedURL: feedURL,
            medium: podcastMedium
        )
    }
}
