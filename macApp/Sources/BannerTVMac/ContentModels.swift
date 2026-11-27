import BannerCore
import Foundation

/// Loads a title's details through the shared core.
@MainActor
final class DetailsModel: ObservableObject {
    enum State { case loading, loaded(TitleDetails), failed }
    @Published private(set) var state: State = .loading
    let ref: TitleRef

    init(ref: TitleRef) { self.ref = ref }

    func load() {
        state = .loading
        let ref = ref
        MacContent.shared.loadMeta(type: ref.type, id: ref.id) { [weak self] meta in
            let details = meta.map { TitleDetails($0, fallback: ref) }
            Task { @MainActor in self?.state = details.map(State.loaded) ?? .failed }
        }
    }
}

/// Collects sources for one title or episode from every installed add-on that serves streams.
@MainActor
final class SourcesModel: ObservableObject {
    @Published private(set) var groups: [SourceGroup] = []
    @Published private(set) var isLoading = true

    func load(type: String, videoId: String) {
        isLoading = true
        MacContent.shared.loadStreams(type: type, videoId: videoId, onGroups: { [weak self] list in
            let mapped = list.map(Self.group)
            Task { @MainActor in self?.groups = mapped }
        }, onDone: { [weak self] in
            Task { @MainActor in self?.isLoading = false }
        })
    }

    func cancel() { MacContent.shared.cancelStreams() }

    private static func group(_ g: MacStreamGroup) -> SourceGroup {
        SourceGroup(id: g.addonId, name: g.addonName, logo: g.addonLogo.flatMap(URL.init(string:)),
                    isLoading: g.isLoading, error: g.error, options: g.streams.enumerated().map { option($1, index: $0, group: g.addonId) })
    }

    private static func option(_ s: StreamItem, index: Int, group: String) -> SourceOption {
        let direct = s.playableDirectUrl.flatMap(URL.init(string:))
        let kind: SourceKind
        if direct != nil { kind = .direct }
        else if s.isTorrentStream || s.isDirectDebridStream { kind = .torrent }
        else if s.externalOpenUrl != nil { kind = .external }
        else { kind = .unsupported }
        let subs = s.externalSubtitles.compactMap { sub -> SubtitleOption? in
            URL(string: sub.url).map { SubtitleOption(url: $0, language: sub.language, name: sub.name) }
        }
        return SourceOption(id: "\(group)-\(index)", addonId: group, title: s.streamLabel.replacingOccurrences(of: "\n", with: " "),
                            detail: s.streamSubtitle?.replacingOccurrences(of: "\n", with: "  "),
                            url: kind == .external ? s.externalOpenUrl.flatMap(URL.init(string:)) : direct,
                            headers: s.behaviorHints.proxyHeaders?.request ?? [:], kind: kind, subtitles: subs)
    }
}
