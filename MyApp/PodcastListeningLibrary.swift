import Foundation
import Observation

/// Episode identities, queue order and history are shared by all playback surfaces.
/// Progress remains owned by PodcastStore's existing bookmark persistence.
@MainActor
@Observable
final class PodcastListeningLibrary {
    private(set) var queue: [PodcastEpisode] = []
    private(set) var currentIndex: Int?
    private(set) var history: [PodcastEpisode] = []
    var automaticallyAdvance = true {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key = "bannertv.podcasts.listening.v1"

    private struct Snapshot: Codable {
        var queue: [PodcastEpisode]
        var currentIndex: Int?
        var history: [PodcastEpisode]
        var automaticallyAdvance: Bool
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            queue = saved.queue
            currentIndex = saved.currentIndex.flatMap { queue.indices.contains($0) ? $0 : nil }
            history = saved.history
            automaticallyAdvance = saved.automaticallyAdvance
        }
    }

    var nextEpisode: PodcastEpisode? {
        guard let currentIndex, queue.indices.contains(currentIndex + 1) else { return nil }
        return queue[currentIndex + 1]
    }

    var previousEpisode: PodcastEpisode? {
        guard let currentIndex, queue.indices.contains(currentIndex - 1) else { return nil }
        return queue[currentIndex - 1]
    }

    var upcoming: [PodcastEpisode] {
        guard let currentIndex else { return queue }
        return Array(queue.dropFirst(currentIndex + 1))
    }

    func select(_ episode: PodcastEpisode) {
        if let index = queue.firstIndex(where: { $0.id == episode.id }) {
            currentIndex = index
        } else {
            queue = [episode]
            currentIndex = 0
        }
        history.removeAll { $0.id == episode.id }
        history.insert(episode, at: 0)
        history = Array(history.prefix(50))
        persist()
    }

    func replaceQueue(with episodes: [PodcastEpisode]) {
        var seen = Set<String>()
        queue = episodes.filter { seen.insert($0.id).inserted }
        currentIndex = nil
        persist()
    }

    func enqueue(_ episode: PodcastEpisode) {
        guard !queue.contains(where: { $0.id == episode.id }) else { return }
        queue.append(episode)
        persist()
    }

    func removeFromQueue(id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }), index != currentIndex else { return }
        queue.remove(at: index)
        if let currentIndex, index < currentIndex { self.currentIndex = currentIndex - 1 }
        persist()
    }

    private func persist() {
        let saved = Snapshot(queue: queue, currentIndex: currentIndex, history: history,
                             automaticallyAdvance: automaticallyAdvance)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
        NotificationCenter.default.post(name: .bannerAudioLibraryChanged, object: nil)
    }
}

extension Notification.Name {
    static let bannerAudioLibraryChanged = Notification.Name("bannertv.audioLibraryChanged")
    static let bannerPreferencesChanged = Notification.Name("bannertv.preferencesChanged")
}
