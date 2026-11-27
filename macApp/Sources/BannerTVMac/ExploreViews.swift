import BannerCore
import SwiftUI

/// A collection card's artwork, loaded once per collection from TMDB through the shared core.
@MainActor
final class CollectionArtCache: ObservableObject {
    @Published private(set) var art: [String: URL] = [:]
    private var requested: Set<String> = []

    func load(_ id: String) {
        guard !requested.contains(id) else { return }
        requested.insert(id)
        MacDiscovery.shared.collectionArt(id: id) { [weak self] art in
            guard let url = art?.backdrop.flatMap(URL.init(string:)) else { return }
            Task { @MainActor in self?.art[id] = url }
        }
    }
}

/// Explore: every collection, grouped by category.
struct ExploreView: View {
    @EnvironmentObject private var router: Router
    private let groups = Core.collectionsByCategory()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("Explore").font(.jb(40, .bold)).padding(.horizontal, Theme.gutter).padding(.top, 96)
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: group.title)
                        HShelf {
                            ForEach(group.items) { c in
                                Button { router.openCollection(c) } label: { CollectionCard(collection: c) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 60)
        }
    }
}

@MainActor
final class CollectionPageModel: ObservableObject {
    @Published private(set) var shelves: [HomeShelf] = []
    @Published private(set) var isLoading = true

    func load(_ id: String) {
        MacDiscovery.shared.resolveCollection(id: id, onProgress: { [weak self] resolved in
            let shelves = resolved.sections.enumerated().map { index, section in
                HomeShelf(id: "\(id)-\(index)", rowId: "\(id)-\(index)", title: section.title, source: "", items: section.items.map(TitleCard.init))
            }
            Task { @MainActor in self?.shelves = shelves }
        }, done: { [weak self] in Task { @MainActor in self?.isLoading = false } })
    }
}

struct CollectionPage: View {
    let collection: CollectionRoute
    @StateObject private var model = CollectionPageModel()
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var arts: CollectionArtCache

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: arts.art[collection.id]).frame(maxWidth: .infinity).frame(height: 380).clipped()
                    LinearGradient(colors: [.black.opacity(0.1), Theme.background], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(collection.title).font(.jb(44, .bold))
                        Text("COLLECTION").font(.jb(12, .semibold)).tracking(4).foregroundStyle(.white.opacity(0.75))
                        if !collection.blurb.isEmpty { Text(collection.blurb).font(.jb(16)).foregroundStyle(Theme.textSecondary).frame(maxWidth: 640, alignment: .leading) }
                    }
                    .padding(.horizontal, Theme.gutter).padding(.bottom, 24)
                }
                .frame(height: 380)
                if model.shelves.isEmpty {
                    Text(model.isLoading ? "Loading titles" : "Nothing found for this collection right now.").font(.jb(16)).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.gutter)
                }
                ForEach(model.shelves) { shelf in TitleShelf(title: shelf.title, items: shelf.items) }
            }
            .padding(.bottom, 60)
        }
        .ignoresSafeArea(edges: .top)
        .onAppear { arts.load(collection.id); model.load(collection.id) }
    }
}
