import BannerCore
import Foundation

/// A title on a shelf, copied out of the Kotlin `MetaPreview` so SwiftUI never holds Kotlin objects.
struct TitleCard: Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: URL?
    let backdrop: URL?
    let blurb: String?
    let year: String?
    let rating: String?
    let genres: [String]
    let isLandscape: Bool

    init(_ meta: MetaPreview) {
        id = "\(meta.type):\(meta.id)"
        type = meta.type
        name = meta.name
        poster = meta.poster.flatMap(URL.init(string:))
        backdrop = (meta.banner ?? meta.landscapePoster ?? meta.poster).flatMap(URL.init(string:))
        blurb = meta.description_
        year = meta.releaseInfo
        rating = meta.imdbRating
        genres = meta.genres
        isLandscape = meta.posterShape == PosterShape.landscape
    }
}

struct HomeShelf: Identifiable, Hashable {
    let id: String
    let rowId: String
    let title: String
    let source: String
    let items: [TitleCard]
}

/// Home rows from the shared core: the enabled add-ons' catalogs, fetched and parsed by the same code as the phones.
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var shelves: [HomeShelf] = []
    @Published private(set) var isLoading = false
    @Published private(set) var rowOrder: [String] = []
    @Published private(set) var recommended: [TitleCard] = []
    @Published private(set) var reasons: [String: String] = [:]
    @Published private(set) var personal: [HomeShelf] = []
    @Published private(set) var top10: [TitleCard] = []
    @Published private(set) var curated: [HomeShelf] = []
    @Published private(set) var explore: [Core.Collection] = []
    /// Titles added to a row after its first screenful (rows are endless), by row key.
    @Published private(set) var extra: [String: [TitleCard]] = [:]
    private var finished: Set<String> = []
    private var busy: Set<String> = []
    private var discoveryWatch: MacWatch?
    private var watch: MacWatch?

    /// The ids of the rows Home shows, in the person's saved order (Explore plus each add-on catalog).
    var orderedRowIds: [String] {
        var ids: [String] = []
        if !top10.isEmpty { ids.append("top10") }
        if !recommended.isEmpty { ids.append("recommended") }
        ids.append(MacBridge.shared.exploreRowId())
        ids += personal.map(\.rowId) + curated.map(\.rowId) + shelves.map(\.rowId)
        return MacBridge.shared.orderRows(ids: ids, saved: rowOrder)
    }

    func titleForRow(_ id: String) -> String {
        switch id {
        case "top10": return "Top 10 Today"
        case "recommended": return "Recommended For You"
        case MacBridge.shared.exploreRowId(): return "Explore Collections"
        default: return (personal + curated + shelves).first { $0.rowId == id }?.title ?? id
        }
    }

    enum RowKind { case catalog, curated }

    /// A row as shown: its own titles, then whatever scrolling has added.
    func items(_ key: String, _ base: [TitleCard]) -> [TitleCard] {
        guard let more = extra[key], !more.isEmpty else { return base }
        let have = Set(base.map(\.id))
        return base + more.filter { !have.contains($0.id) }
    }

    func kind(forRow id: String) -> RowKind { shelves.contains { $0.rowId == id } ? .catalog : .curated }

    /// Asks for the next titles of a row, once, until they arrive. Add-on rows ask their add-on for its next page; the
    /// TMDB rows ask for titles related to the row.
    func loadMore(key: String, kind: RowKind) {
        guard !finished.contains(key), !busy.contains(key) else { return }
        busy.insert(key)
        switch kind {
        case .catalog:
            MacBridge.shared.loadMoreHome(key: key, count: 18) { [weak self] items, hasMore in
                let cards = items.map(TitleCard.init)
                Task { @MainActor in self?.received(key: key, cards: cards, hasMore: hasMore.boolValue) }
            }
        case .curated:
            var shown = Set<String>()
            for card in top10 + recommended + (personal + curated + shelves).flatMap({ $0.items }) + extra.values.flatMap({ $0 }) { shown.insert(card.ref.id) }
            MacBridge.shared.loadMoreCurated(key: key, shownIds: Array(shown)) { [weak self] items in
                let cards = items.map(TitleCard.init)
                Task { @MainActor in self?.received(key: key, cards: cards, hasMore: !cards.isEmpty) }
            }
        }
    }

    private func received(key: String, cards: [TitleCard], hasMore: Bool) {
        busy.remove(key)
        if CommandLine.arguments.contains("--debug-rows") { FileHandle.standardError.write(Data("[rows] \(key): +\(cards.count), more=\(hasMore)\n".utf8)) }
        if !cards.isEmpty { extra[key, default: []] += cards }
        if !hasMore { finished.insert(key) }
    }

    func shelf(forRow id: String) -> HomeShelf? { (personal + curated + shelves).first { $0.rowId == id } }

    func start() {
        guard watch == nil else { return }
        discoveryWatch = MacBridge.shared.watchDiscovery { [weak self] state in
            let recommended = state.recommended.map(TitleCard.init)
            let reasons = state.reasons
            let personal = state.rows.map { r in HomeShelf(id: r.key, rowId: r.rowId, title: r.title, source: r.addonName, items: r.items.map(TitleCard.init)) }
            let top10 = state.top10.map(TitleCard.init)
            let curated = state.curated.map { r in HomeShelf(id: r.key, rowId: r.rowId, title: r.title, source: r.addonName, items: r.items.map(TitleCard.init)) }
            let explore = state.explore.map(Core.Collection.init)
            Task { @MainActor in
                self?.recommended = recommended; self?.reasons = reasons; self?.personal = personal
                self?.top10 = top10; self?.curated = curated; self?.explore = explore
            }
        }
        watch = MacBridge.shared.watchHomeSettings { [weak self] settings in
            let order = settings.rowOrder
            Task { @MainActor in self?.rowOrder = order }
        }
    }

    func saveOrder(visible: [String]) {
        let saved = MacBridge.shared.rowOrderToSave(saved: rowOrder, visible: visible)
        rowOrder = saved
        MacBridge.shared.saveRowOrder(order: saved)
    }

    /// Reloads when the set of usable add-ons changes (installed, enabled, or their manifests finished loading).
    func reloadIfNeeded(addons: [AddonRow]) {
        let usable = addons.filter { $0.enabled && !$0.isRefreshing && $0.error == nil }.map { "\($0.id)|\($0.detail)" }
        guard !usable.isEmpty, usable != lastSignature else { return }
        lastSignature = usable
        reload()
    }
    private var lastSignature: [String] = []

    /// Forgets the previous profile's rows so nothing of it shows while the next one loads.
    func reset() { shelves = []; lastSignature = []; extra = [:]; finished = []; busy = [] }

    func reload() {
        isLoading = true
        extra = [:]; finished = []; busy = []
        MacBridge.shared.loadHome(
            previewLimit: 18,
            onRows: { [weak self] rows in
                let shelves = rows.map { row in
                    HomeShelf(id: row.key, rowId: row.rowId, title: row.title, source: row.addonName, items: row.items.map(TitleCard.init))
                }
                Task { @MainActor in self?.shelves = shelves }
            },
            onDone: { [weak self] in Task { @MainActor in self?.isLoading = false } }
        )
    }
}
