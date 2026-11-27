import SwiftUI

/// A poster or landscape card, as on the phone: rounded, no frame, lifting a little under the pointer.
struct PosterCard: View {
    let item: TitleCard
    var width: CGFloat = 176

    var body: some View {
        let size = item.isLandscape ? CGSize(width: width * 1.75, height: width * 1.75 / 1.77) : CGSize(width: width, height: width * 1.5)
        ZStack {
            RemoteImage(url: item.poster)
            if item.poster == nil {
                Text(item.name).font(.jb(14, .semibold)).multilineTextAlignment(.center).padding(10).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPoster, style: .continuous))
        .hoverLift()
        .help(item.name)
    }
}

/// A Continue Watching card: wide artwork with the title, where you are, a play button and a progress line.
struct ContinueTile: View {
    let card: ContinueCard
    var width: CGFloat = 340

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: card.backdrop)
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.ref.name).font(.jb(20, .bold)).lineLimit(1)
                Text(card.label).font(.jb(13)).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
            }
            .padding(.horizontal, 18).padding(.bottom, 20)
            HStack {
                Spacer()
                Image(systemName: "play.fill").font(.system(size: 14))
                    .frame(width: 40, height: 40).background(.black.opacity(0.35), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            }
            .padding(.trailing, 16).padding(.bottom, 14)
            if card.fraction > 0.01 {
                VStack { Spacer(); GeometryReader { g in
                    ZStack(alignment: .leading) { Color.white.opacity(0.22); Color.white.frame(width: g.size.width * min(card.fraction, 1)) }
                }.frame(height: 4) }
            }
        }
        .frame(width: width, height: width / 1.77)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPoster + 4, style: .continuous))
        .hoverLift(1.025)
    }
}

/// An Explore collection: artwork with its name and the small "COLLECTION" tag.
struct CollectionCard: View {
    let collection: Core.Collection
    @EnvironmentObject private var arts: CollectionArtCache
    var width: CGFloat = 340

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: arts.art[collection.id])
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(collection.title).font(.jb(26, .bold)).lineLimit(2).shadow(color: .black.opacity(0.5), radius: 6)
                Text(collection.isEpisodeCollection ? "EPISODES" : "COLLECTION").font(.jb(12, .semibold)).tracking(4).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 22).padding(.bottom, 20)
        }
        .frame(width: width, height: width * 0.56)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .hoverLift(1.025)
        .onAppear { arts.load(collection.id) }
    }
}

/// A shelf of titles with its heading. Given a [moreKey] it is endless: near its last card it asks Home for more.
struct TitleShelf: View {
    let title: String
    var subtitle: String? = nil
    let items: [TitleCard]
    var onMore: (() -> Void)? = nil
    var moreKey: String? = nil
    var moreKind: HomeModel.RowKind = .curated
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var home: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, subtitle: subtitle, onMore: onMore)
            HShelf {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { router.open(item.ref) } label: { PosterCard(item: item) }
                        .buttonStyle(.plain)
                        .onAppear {
                            if let moreKey, index >= items.count - 6 { home.loadMore(key: moreKey, kind: moreKind) }
                        }
                }
            }
        }
    }
}
