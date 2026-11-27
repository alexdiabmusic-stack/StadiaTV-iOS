import BannerCore
import SwiftUI

/// Navigation that spans sections: pushed Details pages and the full-window player.
@MainActor
final class Router: ObservableObject {
    @Published var path: [Route] = []
    @Published var playback: PlaybackRequest?
    @Published var sourceTarget: SourceTarget?

    func open(_ ref: TitleRef) { path.append(.title(ref)) }
    func openCollection(_ c: Core.Collection) { path.append(.collection(CollectionRoute(id: c.id, title: c.title, blurb: c.blurb))) }
    func play(_ request: PlaybackRequest) { playback = request }
    func closePlayer() { playback = nil }
}

struct CollectionRoute: Hashable { let id: String; let title: String; let blurb: String }

enum Route: Hashable {
    case title(TitleRef)
    case collection(CollectionRoute)
    case explore
    case game(String)
    case league(String)
    case serializd
    case serializdAdvanced
    case letterboxd
    case letterboxdAdvanced
}
