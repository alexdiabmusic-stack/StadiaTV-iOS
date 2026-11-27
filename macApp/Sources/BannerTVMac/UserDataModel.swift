import BannerCore
import Foundation

/// A Continue Watching card.
struct ContinueCard: Identifiable, Hashable {
    let id: String
    let ref: TitleRef
    let backdrop: URL?
    let logo: URL?
    let label: String
    let fraction: Double
    let videoId: String
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let startAt: Double?
    let isNextUp: Bool
}

struct SavedTitle: Identifiable, Hashable {
    var id: String { ref.key }
    let ref: TitleRef
    let backdrop: URL?
    let year: String?
    let addedAt: Int64
}

/// The active profile's Continue Watching, library and watched history, kept current by the shared core.
@MainActor
final class UserDataModel: ObservableObject {
    @Published private(set) var continueCards: [ContinueCard] = []
    @Published private(set) var saved: [SavedTitle] = []
    @Published private(set) var watchedKeys: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]   // progress key -> fraction
    @Published private(set) var positions: [String: Double] = [:]  // video id -> seconds
    private var watches: [MacWatch] = []
    private var savedKeys: Set<String> = []

    func start() {
        guard watches.isEmpty else { return }
        watches.append(MacBridge.shared.watchContinue { [weak self] items in
            let cards = items.map(Self.card)
            Task { @MainActor in self?.continueCards = cards }
        })
        watches.append(MacBridge.shared.watchLibrary { [weak self] items in
            let titles = items.map { item in
                SavedTitle(ref: TitleRef(type: item.contentType, id: item.contentId, name: item.name,
                                         poster: item.poster.flatMap(URL.init(string:))),
                           backdrop: (item.background ?? item.poster).flatMap(URL.init(string:)),
                           year: item.releaseInfo, addedAt: item.addedAt)
            }
            Task { @MainActor in self?.saved = titles; self?.savedKeys = Set(titles.map(\.id)) }
        })
        watches.append(MacBridge.shared.watchWatched { [weak self] items in
            let keys = Set(items.map(\.key))
            Task { @MainActor in self?.watchedKeys = keys }
        })
        watches.append(MacBridge.shared.watchProgress { [weak self] items in
            var fractions: [String: Double] = [:]
            var positions: [String: Double] = [:]
            for p in items {
                fractions[p.progressKey] = p.fraction
                if !p.isComplete { positions[p.videoId] = Double(p.position) / 1000 }
            }
            Task { @MainActor in self?.progress = fractions; self?.positions = positions }
        })
    }

    func refresh() { MacBridge.shared.refreshAccountData { _ in } }

    func isSaved(_ ref: TitleRef) -> Bool { savedKeys.contains(ref.key) }
    func isWatched(contentId: String, season: Int?, episode: Int?) -> Bool {
        let key = season.flatMap { s in episode.map { "\(contentId)_s\(s)e\($0)" } } ?? contentId
        return watchedKeys.contains(key)
    }
    func fraction(contentId: String, season: Int?, episode: Int?) -> Double? {
        let key = season.flatMap { s in episode.map { "\(contentId)_s\(s)e\($0)" } } ?? contentId
        return progress[key]
    }
    func resumePosition(videoId: String) -> Double? { positions[videoId] }

    func setSaved(_ details: TitleDetails, saved: Bool) {
        MacBridge.shared.setSaved(contentId: details.ref.id, contentType: details.ref.type, name: details.ref.name,
                                  poster: details.ref.poster?.absoluteString, background: details.backdrop?.absoluteString,
                                  logo: details.logo?.absoluteString, description: details.blurb, releaseInfo: details.year,
                                  imdbRating: details.rating, genres: details.genres, saved: saved)
    }

    func setWatched(_ ref: TitleRef, title: String, season: Int?, episode: Int?, watched: Bool) {
        MacBridge.shared.setWatched(contentId: ref.id, contentType: ref.type, title: title,
                                    season: Self.kotlinInt(season), episode: Self.kotlinInt(episode), watched: watched)
    }

    func removeFromContinue(_ card: ContinueCard) { MacBridge.shared.removeFromContinue(contentId: card.ref.id) }

    func recordPlayback(_ request: PlaybackRequest, position: Double, duration: Double) {
        let season = request.season, episode = request.episode
        MacBridge.shared.recordProgress(contentId: request.ref.id, contentType: request.ref.type, videoId: request.videoId,
                                        season: Self.kotlinInt(season), episode: Self.kotlinInt(episode),
                                        positionMs: Int64(position * 1000), durationMs: Int64(duration * 1000))
        // Finishing something marks it watched.
        if duration > 0, position / duration >= 0.9 {
            setWatched(request.ref, title: request.title, season: season, episode: episode, watched: true)
        }
    }

    private static func kotlinInt(_ value: Int?) -> KotlinInt? { value.flatMap { Int32(exactly: $0) }.map { KotlinInt(int: $0) } }

    private static func card(_ item: MacContinueItem) -> ContinueCard {
        let ref = TitleRef(type: item.contentType, id: item.contentId, name: item.name, poster: item.poster.flatMap(URL.init(string:)))
        var label = item.isNextUp ? "Next up" : "Resume"
        if let s = item.season, let e = item.episode { label = "S\(s) E\(e)" + (item.episodeTitle.map { "  \($0)" } ?? "") }
        else if item.durationMs > 0 {
            let left = Int((item.durationMs - item.positionMs) / 60_000)
            label = left >= 60 ? "\(left / 60)h \(left % 60)m left" : "\(max(left, 1))m left"
        }
        return ContinueCard(id: "\(ref.key)|\(item.videoId)", ref: ref, backdrop: item.background.flatMap(URL.init(string:)),
                            logo: item.logo.flatMap(URL.init(string:)), label: item.isNextUp ? "Up next · \(label)" : label,
                            fraction: item.fraction, videoId: item.videoId, season: item.season?.intValue, episode: item.episode?.intValue,
                            episodeTitle: item.episodeTitle, startAt: item.isNextUp ? nil : Double(item.positionMs) / 1000, isNextUp: item.isNextUp)
    }
}
