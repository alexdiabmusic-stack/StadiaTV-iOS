import BannerCore
import Foundation

/// Where a title lives: enough to open its Details page. Hashable so it can sit in a navigation path.
struct TitleRef: Hashable, Identifiable {
    let type: String
    let id: String
    let name: String
    let poster: URL?
    var key: String { "\(type):\(id)" }
}

extension TitleCard {
    var ref: TitleRef { TitleRef(type: type, id: String(id.dropFirst(type.count + 1)), name: name, poster: poster) }
}

struct Person: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let photo: URL?
}

struct Episode: Identifiable, Hashable {
    let id: String           // the add-on's video id, e.g. tt0944947:1:1
    let title: String
    let season: Int
    let number: Int
    let thumbnail: URL?
    let overview: String?
    let released: Date?
    let runtimeMinutes: Int?
    let available: Bool
}

/// A title's details, copied from the Kotlin `MetaDetails`.
struct TitleDetails: Hashable {
    let ref: TitleRef
    let logo: URL?
    let backdrop: URL?
    let blurb: String?
    let year: String?
    let runtime: String?
    let rating: String?
    let ageRating: String?
    let genres: [String]
    let cast: [Person]
    let directors: [String]
    let writers: [String]
    let episodes: [Episode]
    let defaultVideoId: String?

    var isSeries: Bool { ref.type != "movie" && !episodes.isEmpty }
    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted { a, b in (a == 0 ? Int.max : a) < (b == 0 ? Int.max : b) } }
    func episodes(in season: Int) -> [Episode] { episodes.filter { $0.season == season }.sorted { $0.number < $1.number } }

    init(_ meta: MetaDetails, fallback: TitleRef) {
        let poster = meta.poster.flatMap(URL.init(string:)) ?? fallback.poster
        ref = TitleRef(type: meta.type, id: meta.id, name: meta.name, poster: poster)
        logo = meta.logo.flatMap(URL.init(string:))
        backdrop = (meta.background ?? meta.poster).flatMap(URL.init(string:))
        blurb = meta.description_
        year = meta.releaseInfo
        runtime = meta.runtime
        rating = meta.imdbRating
        ageRating = meta.ageRating
        genres = meta.genres
        cast = meta.cast.enumerated().map { index, p in
            Person(id: "\(index)-\(p.name)", name: p.name, role: p.role, photo: p.photo.flatMap(URL.init(string:)))
        }
        directors = meta.director
        writers = meta.writer
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        episodes = meta.videos.compactMap { v in
            guard let season = v.season?.intValue, let number = v.episode?.intValue else { return nil }
            let date = v.released.flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            return Episode(id: v.id, title: v.title, season: season, number: number,
                           thumbnail: v.thumbnail.flatMap(URL.init(string:)), overview: v.overview, released: date,
                           runtimeMinutes: v.runtime?.intValue, available: v.available)
        }
        defaultVideoId = meta.defaultVideoId
    }
}

/// How a stream can (or cannot) be played on the Mac.
enum SourceKind: Hashable { case direct, torrent, external, unsupported }

struct SourceOption: Identifiable, Hashable {
    let id: String
    let addonId: String
    let title: String
    let detail: String?
    let url: URL?
    let headers: [String: String]
    let kind: SourceKind
    let subtitles: [SubtitleOption]
}

struct SubtitleOption: Hashable {
    let url: URL
    let language: String
    let name: String?
}

struct SourceGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: URL?
    let isLoading: Bool
    let error: String?
    let options: [SourceOption]
}

/// Everything the player needs to start, and what to record about it afterwards.
struct PlaybackRequest: Identifiable, Hashable {
    let id = UUID()
    let ref: TitleRef
    let videoId: String
    let title: String
    let subtitle: String?
    let source: SourceOption
    let startAt: Double?
    let next: Episode?
    var isLive: Bool = false
    /// The episodes after this one, in order; the first is "next".
    var upcoming: [Episode] = []
    /// Which episode this is, taken from the episode itself (never guessed from the video id).
    var season: Int? = nil
    var episode: Int? = nil
}
