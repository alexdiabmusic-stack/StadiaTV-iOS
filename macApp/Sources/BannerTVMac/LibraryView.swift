import SwiftUI

/// The profile's saved titles.
struct LibraryView: View {
    @EnvironmentObject private var data: UserDataModel
    @EnvironmentObject private var router: Router
    @State private var filter = "all"

    private var items: [SavedTitle] {
        data.saved.filter { filter == "all" || ($0.ref.type == "movie") == (filter == "movie") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Library").font(.jb(40, .bold))
                HStack(spacing: 8) {
                    Chip(title: "All", selected: filter == "all") { filter = "all" }
                    Chip(title: "Movies", selected: filter == "movie") { filter = "movie" }
                    Chip(title: "Series", selected: filter == "series") { filter = "series" }
                }
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing saved yet").font(.jb(22, .semibold))
                        Text("Use My List on a title's page to keep it here. Your list syncs with your other devices.")
                            .font(.jb(15)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.top, 30)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 190), spacing: 20)], alignment: .leading, spacing: 26) {
                        ForEach(items) { title in
                            Button { router.open(title.ref) } label: {
                                PosterCard(item: TitleCard(saved: title))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.gutter).padding(.top, 96).padding(.bottom, 60)
        }
    }
}

extension TitleCard {
    init(saved: SavedTitle) {
        id = saved.id; type = saved.ref.type; name = saved.ref.name; poster = saved.ref.poster; backdrop = saved.backdrop
        blurb = nil; year = saved.year; rating = nil; genres = []; isLandscape = false
    }
}
