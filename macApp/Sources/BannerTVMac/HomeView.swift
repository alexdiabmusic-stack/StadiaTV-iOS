import BannerCore
import SwiftUI

/// Home, laid out like the phone's: a full-bleed hero carousel, Continue Watching, then the shelves in the saved order.
struct HomeView: View {
    @EnvironmentObject private var account: AccountModel
    @EnvironmentObject private var data: UserDataModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var model: HomeModel

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    HeroCarousel(items: heroItems, height: min(max(proxy.size.height * 0.84, 540), 780))
                    if !data.continueCards.isEmpty { ContinueShelf(cards: data.continueCards) }
                    ForEach(model.orderedRowIds, id: \.self) { rowId in rowView(rowId) }
                    if model.shelves.isEmpty && heroItems.isEmpty { emptyState }
                }
                .padding(.bottom, 60)
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    /// Up to eight titles with artwork, from the first shelves.
    private var heroItems: [TitleCard] {
        var seen = Set<String>()
        var out: [TitleCard] = []
        for item in model.shelves.flatMap({ $0.items }) where item.backdrop != nil && seen.insert(item.id).inserted {
            out.append(item)
            if out.count == 8 { break }
        }
        return out
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.isLoading ? "Loading your add-ons" : "Nothing to show yet").font(.jb(22, .semibold))
            Text(model.isLoading ? "Catalogs appear as they arrive." : "Install an add-on or sign in from Settings to fill Home.")
                .font(.jb(15)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.gutter).padding(.top, 120)
    }

    @ViewBuilder private func rowView(_ rowId: String) -> some View {
        if rowId == "top10" { Top10Shelf(cards: model.top10) }
        else if rowId == "recommended" { RecommendedShelf(cards: model.items("recommended", model.recommended), reasons: model.reasons) }
        else if rowId == MacBridge.shared.exploreRowId() { exploreShelf }
        else if let shelf = model.shelf(forRow: rowId) {
            TitleShelf(title: shelf.title, items: model.items(shelf.id, shelf.items), moreKey: shelf.id, moreKind: model.kind(forRow: rowId))
        }
    }

    /// This week's Explore Collections, chosen for the profile's taste by the shared engine.
    private var exploreShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Explore Collections") { router.path.append(.explore) }
            HShelf {
                ForEach(model.explore) { collection in
                    Button { router.openCollection(collection) } label: { CollectionCard(collection: collection) }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Hero

/// The big carousel at the top: backdrop, title art, genres, Play and My List, and the pager dots.
private struct HeroCarousel: View {
    let items: [TitleCard]
    let height: CGFloat
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var data: UserDataModel
    @StateObject private var meta = HeroMetaStore()
    @State private var index = 0
    @State private var hovering = false
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.surface
            if items.isEmpty {
                ProgressView().controlSize(.large)
            } else {
                let item = items[min(index, items.count - 1)]
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, candidate in
                        RemoteImage(url: candidate.backdrop).opacity(i == index ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: height).clipped()
                .animation(.easeInOut(duration: 0.6), value: index)
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.25),
                                       .init(color: Theme.background.opacity(0.55), location: 0.62), .init(color: Theme.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                content(item)
                if hovering && items.count > 1 {
                    HStack {
                        arrow("chevron.left") { step(-1) }
                        Spacer()
                        arrow("chevron.right") { step(1) }
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                }
            }
        }
        .frame(height: height)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .onReceive(timer) { _ in if !hovering, items.count > 1 { step(1) } }
        .onChange(of: items.map(\.id)) { _, _ in index = 0 }
        .task(id: items.map(\.id)) { for item in items { meta.load(item) } }
    }

    private func content(_ item: TitleCard) -> some View {
        VStack(spacing: 16) {
            Spacer()
            if let logo = meta.logo[item.id] {
                AsyncImage(url: logo) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) } else { Color.clear }
                }
                .frame(maxWidth: 520, maxHeight: 170)
            } else {
                Text(item.name).font(.jb(52, .bold)).multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 760)
            }
            Text((meta.genres[item.id] ?? item.genres).prefix(3).joined(separator: "  •  ")).font(.jb(18)).foregroundStyle(.white.opacity(0.78))
            HStack(spacing: 14) {
                Button { play(item) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(PillButtonStyle(kind: .primary))
                Button { toggleSaved(item) } label: {
                    Label(data.isSaved(item.ref) ? "In My List" : "My List", systemImage: data.isSaved(item.ref) ? "checkmark" : "plus")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .padding(.top, 4)
            Pager(count: items.count, index: index).padding(.top, 8)
        }
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .id(item.id)
        .transition(.opacity)
        .onTapGesture { router.open(item.ref) }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(GlassCircleButtonStyle(size: 48))
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }

    private func play(_ item: TitleCard) {
        if item.type == "movie" {
            router.sourceTarget = SourceTarget(ref: item.ref, videoId: item.ref.id, title: item.name, subtitle: nil, next: nil,
                                               startAt: data.resumePosition(videoId: item.ref.id))
        } else { router.open(item.ref) }
    }

    private func toggleSaved(_ item: TitleCard) {
        MacBridge.shared.setSaved(contentId: item.ref.id, contentType: item.type, name: item.name, poster: item.poster?.absoluteString,
                                  background: item.backdrop?.absoluteString, logo: meta.logo[item.id]?.absoluteString, description: item.blurb,
                                  releaseInfo: item.year, imdbRating: item.rating, genres: item.genres, saved: !data.isSaved(item.ref))
    }
}

private struct Pager: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(Color.white.opacity(i == index ? 1 : 0.45)).frame(width: i == index ? 34 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: index)
    }
}

/// Title art and genres for the hero's titles (the shelf previews have neither), loaded once through the shared core.
@MainActor
final class HeroMetaStore: ObservableObject {
    @Published private(set) var logo: [String: URL] = [:]
    @Published private(set) var genres: [String: [String]] = [:]
    private var requested = Set<String>()

    func load(_ item: TitleCard) {
        guard requested.insert(item.id).inserted else { return }
        MacContent.shared.loadMeta(type: item.type, id: item.ref.id) { [weak self] meta in
            guard let meta else { return }
            let logo = meta.logo.flatMap(URL.init(string:))
            let genres = meta.genres
            Task { @MainActor in
                if let logo { self?.logo[item.id] = logo }
                if !genres.isEmpty { self?.genres[item.id] = genres }
            }
        }
    }
}

// MARK: - Shelves

private struct ContinueShelf: View {
    let cards: [ContinueCard]
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var data: UserDataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Continue Watching")
            HShelf {
                ForEach(cards) { card in
                    Button { play(card) } label: { ContinueTile(card: card) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open Details") { router.open(card.ref) }
                            Button("Remove from Continue Watching") { data.removeFromContinue(card) }
                        }
                }
            }
        }
    }

    private func play(_ card: ContinueCard) {
        router.sourceTarget = SourceTarget(ref: card.ref, videoId: card.videoId, title: card.ref.name,
                                           subtitle: card.label, next: nil, startAt: card.startAt)
    }
}

private struct Top10Shelf: View {
    let cards: [TitleCard]
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Top 10 Today")
            HShelf(spacing: 6) {
                ForEach(Array(cards.prefix(10).enumerated()), id: \.element.id) { index, card in
                    Button { router.open(card.ref) } label: {
                        HStack(alignment: .bottom, spacing: -26) {
                            OutlinedNumeral(text: "\(index + 1)", size: 190).frame(width: index == 9 ? 200 : 118, alignment: .trailing).padding(.bottom, -22)
                            PosterCard(item: card)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct RecommendedShelf: View {
    let cards: [TitleCard]
    let reasons: [String: String]
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var home: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recommended For You")
            HShelf {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    Button { router.open(card.ref) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            PosterCard(item: card)
                                .onAppear { if index >= cards.count - 6 { home.loadMore(key: "recommended", kind: .curated) } }
                            if let reason = reasons[card.ref.id] {
                                Text(reason).font(.jb(12)).foregroundStyle(Theme.textSecondary).lineLimit(2).frame(width: 176, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
