import BannerCore
import Foundation
import SwiftUI

/// Sports status and the helpers the Sports screens share. The games themselves come from the shared core on demand
/// (they depend on the chosen day and sport), and are re-read whenever [tick] changes.
@MainActor
final class SportsModel: ObservableObject {
    @Published private(set) var status: MacSportsStatus?
    @Published private(set) var tick = 0
    private var watch: MacWatch?

    func start() {
        MacSports.shared.start()
        guard watch == nil else { return }
        watch = MacSports.shared.watchStatus { [weak self] status in
            Task { @MainActor in self?.status = status; self?.tick += 1 }
        }
    }

    func setViewing(_ on: Bool) { MacSports.shared.setViewing(on: on) }
    func refresh() { MacSports.shared.refresh() }

    var hideScores: Bool { status?.hideScores ?? false }
}

enum SportsFormat {
    static func time(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened)
    }

    static func day(_ offset: Int) -> String {
        switch offset {
        case -1: return "Yesterday"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            return date.formatted(.dateTime.weekday(.abbreviated).day())
        }
    }

    static func dayAndTime(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// The corner of a card: the game clock, the start time or the result.
    static func status(_ game: MacSportsGame, hideScores: Bool) -> String {
        switch game.state {
        case "live":
            if !hideScores, let status = game.status, !status.isEmpty, game.hasScore { return status }
            return game.hasTime ? "Started \(time(game.startMs))" : "On now"
        case "post":
            return game.status.flatMap { $0.isEmpty ? nil : $0 } ?? "Final"
        default:
            if game.hasTime { return time(game.startMs) }
            return "All day"
        }
    }

    static func hasLiveStyle(_ game: MacSportsGame) -> Bool { game.state == "live" }
}

/// Starts a stream the Sports hub found, in the full-window player.
@MainActor
enum SportsPlayback {
    static func play(_ stream: MacSportsStream, game: MacSportsGame, router: Router) {
        guard let url = URL(string: stream.url) else { return }
        MacBridge.shared.markLiveWatched(channelId: stream.key)
        let ref = TitleRef(type: "tv", id: stream.key, name: stream.name, poster: stream.logo.flatMap(URL.init(string:)))
        let source = SourceOption(id: stream.key, addonId: stream.isAddon ? "sports-addon" : "live", title: stream.name, detail: stream.quality,
                                  url: url, headers: stream.headers, kind: .direct, subtitles: [])
        router.play(PlaybackRequest(ref: ref, videoId: stream.key, title: game.title, subtitle: stream.name, source: source,
                                    startAt: nil, next: nil, isLive: true))
    }
}

/// A team crest, or a neutral placeholder when the feed has none.
struct TeamLogo: View {
    let url: String?
    var size: CGFloat = 28
    var placeholder = "shield"

    var body: some View {
        Group {
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) } else { Color.clear }
                }
            } else {
                Image(systemName: placeholder).foregroundStyle(Theme.textSecondary).padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
    }
}
