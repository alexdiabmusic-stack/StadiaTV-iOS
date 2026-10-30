import SwiftUI

struct EntertainmentCollectionsView: View {
    private let repository = EntertainmentRepository.shared
    @State private var watched = false
    @State private var query = ""
    @State private var kind = "all"
    @State private var reverseTitle = false
    @State private var availableOnly = false
    @State private var items: [EntertainmentItem] = []

    var body: some View {
        List {
            Picker("Collection", selection: $watched) {
                Text("Watchlist").tag(false)
                Text("Watched History").tag(true)
            }
            ForEach(items) { item in
                NavigationLink { EntertainmentDetailView(itemID: item.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline)
                        if item.sources.allSatisfy({ $0.availability != .available }) {
                            Text("Currently unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    if watched {
                        Button("Mark Unwatched") { repository.removeProgress(for: item) }
                    } else {
                        Button("Remove from Watchlist", role: .destructive) { repository.toggleWatchlist(item.id) }
                    }
                }
            }
            if items.isEmpty {
                ContentUnavailableView("Your collection is empty", systemImage: watched ? "clock" : "bookmark",
                    description: Text("Saved titles and completed viewing will appear here."))
            }
        }
        .navigationTitle("Your Library")
        .searchable(text: $query)
        .toolbar {
            Menu {
                Toggle("Reverse Title Order", isOn: $reverseTitle)
                Toggle("Available Only", isOn: $availableOnly)
                Picker("Content type", selection: $kind) {
                    Text("All").tag("all")
                    Text("Movies").tag("movie")
                    Text("Series").tag("series")
                    Text("Episodes").tag("episode")
                }
            } label: { Label("Collection Filters", systemImage: "line.3.horizontal.decrease") }
        }
        .task(id: "\(watched)|\(query)|\(kind)|\(reverseTitle)|\(availableOnly)|\(repository.userStateRevision)|\(repository.revision)") {
            let catalog = repository.catalog + repository.seasonsBySeries.values.flatMap { $0.flatMap(\.episodes) }
            let currentIDs = Set(catalog.map(\.progressID))
            let retained = repository.savedHistoryItems.values.filter { !currentIDs.contains($0.progressID) }.compactMap { repository.item(for: $0.id) }
            let all = catalog + retained
            let entries = watched ? all.filter { repository.watchProgress(for: $0)?.completed == true } :
                repository.watchlist.compactMap { repository.item(for: $0) ??
                    EntertainmentItem(id: $0, kind: .movie, providerTitle: String(localized: "Saved title unavailable")) }
            items = entries.filter {
                (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) &&
                (kind == "all" || $0.kind.rawValue == kind) &&
                (!availableOnly || $0.isPlayable || ($0.kind == .series && $0.sources.contains { $0.availability == .available }))
            }.sorted {
                $0.title.localizedStandardCompare($1.title) == (reverseTitle ? .orderedDescending : .orderedAscending)
            }
        }
    }
}

struct EntertainmentSearchSections: View {
    let items: [EntertainmentItem]
    var limit = 100
    var body: some View {
        ForEach(EntertainmentKind.allCases, id: \.self) { kind in
            let matches = items.filter { $0.kind == kind }
            if !matches.isEmpty {
                Text(kind == .movie ? "Movies" : kind == .series ? "Series" : "Episodes").font(.title2.bold())
                ForEach(Array(matches.prefix(limit))) { item in
                    NavigationLink { EntertainmentDetailView(itemID: item.seriesID ?? item.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: kind == .movie ? "film" : "play.rectangle")
                            Text(item.isPlayable ? "Available to Watch" : kind == .series && item.sources.contains(where: { $0.availability == .available }) ? "View available episodes" : "Currently unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
