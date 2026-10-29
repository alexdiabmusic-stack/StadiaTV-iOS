import SwiftUI
import AVKit

struct EntertainmentLibraryView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    private let repository = EntertainmentRepository.shared
    @State private var query = ""
    @State private var kind: EntertainmentKind = .movie
    @State private var watchlistOnly = false
    @State private var recentFirst = false
    @State private var category = ""
    @State private var categories: [String] = []
    @State private var genre = ""
    @State private var genres: [String] = []
    @State private var results: [EntertainmentItem] = []
    @State private var continuing: [EntertainmentItem] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !repository.sourceErrors.isEmpty {
                    Label("Some sources could not refresh. Cached titles may be unavailable.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Retry") { Task { await refresh(force: true) } }
                }
                if !continuing.isEmpty {
                    Text("Continue Watching").font(.title2.bold())
                    ForEach(continuing) { item in
                        NavigationLink { EntertainmentDetailView(itemID: item.seriesID ?? item.id) } label: {
                            EntertainmentLibraryRow(item: item, progress: repository.watchProgress(for: item))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from Continue Watching", role: .destructive) { repository.removeProgress(for: item) }
                        }
                    }
                }
                Picker("Content type", selection: $kind) {
                    Text("Movies").tag(EntertainmentKind.movie)
                    Text("TV Shows").tag(EntertainmentKind.series)
                }
                .pickerStyle(.segmented)
                if repository.isRefreshing && results.isEmpty && repository.sourceErrors.isEmpty {
                    ProgressView("Loading your library…").frame(maxWidth: .infinity).padding()
                } else if results.isEmpty {
                    ContentUnavailableView("No titles found", systemImage: "film", description:
                        Text("Your library shows movies and series from your connected sources. Add a supported source in Settings or change your filters."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)], spacing: 22) {
                        ForEach(results) { item in
                            NavigationLink { EntertainmentDetailView(itemID: item.id) } label: {
                                EntertainmentPosterCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.screen)
        }
        .background(Theme.background)
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Search your library")
        .toolbar {
            Menu {
                Toggle("Watchlist", isOn: $watchlistOnly)
                Toggle("Recently Added", isOn: $recentFirst)
                Picker("Category", selection: $category) {
                    Text("All Categories").tag("")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag("")
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }
                Button("Refresh Library") { Task { await refresh(force: true) } }
            } label: { Image(systemName: "line.3.horizontal.decrease") }
            .accessibilityLabel("Library filters")
        }
        .refreshable { await refresh(force: true) }
        .task(id: playlists.channelsRevision) { await refresh(force: false) }
        .task(id: "\(repository.revision)|\(query)|\(kind.rawValue)|\(watchlistOnly)|\(recentFirst)|\(category)|\(genre)|\(repository.watchlist.hashValue)|\(repository.progress.hashValueForSearch)") {
            await updateResults()
        }
    }

    private func refresh(force: Bool) async {
        await repository.sync(playlists: playlists.playlists, channels: playlists.allChannels, force: force)
    }

    private func updateResults() async {
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        let items = repository.catalog
        let progress = repository.progress
        let episodes = repository.seasonsBySeries.values.flatMap { $0.flatMap(\.episodes) }
        let watchlist = repository.watchlist
        let query = query, kind = kind, only = watchlistOnly, newest = recentFirst, category = category, genre = genre
        let result = await Task.detached(priority: .userInitiated) {
            let key = EntertainmentMatching.normalized(query)
            let matches = items.filter {
                $0.kind == kind && (!only || watchlist.contains($0.id)) &&
                (category.isEmpty || $0.sources.contains { $0.category == category }) &&
                (genre.isEmpty || $0.metadata.genres.contains(genre)) &&
                (key.isEmpty || EntertainmentMatching.normalized($0.title + " " + $0.metadata.genres.joined(separator: " ")).contains(key))
            }.sorted {
                if newest, $0.addedAt != $1.addedAt { return ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let categories = Set(items.flatMap { $0.sources.compactMap(\.category) }).sorted()
            let continuing = (items + episodes).filter {
                guard let state = progress[$0.progressID] ?? progress[$0.id] else { return false }
                return !state.completed && state.position > 0 && $0.isPlayable
            }.sorted { ((progress[$0.progressID] ?? progress[$0.id])?.lastWatched ?? .distantPast) > ((progress[$1.progressID] ?? progress[$1.id])?.lastWatched ?? .distantPast) }
            return (matches, categories, Array(continuing.prefix(10)), Set(items.flatMap { $0.metadata.genres }).sorted())
        }.value
        guard !Task.isCancelled else { return }
        results = result.0; categories = result.1; continuing = result.2; genres = result.3
    }
}

private extension Dictionary where Key == String, Value == EntertainmentProgress {
    var hashValueForSearch: String {
        values.map { "\($0.contentID):\($0.position):\($0.completed)" }.sorted().joined(separator: "|")
    }
}

private struct EntertainmentPosterCard: View {
    let item: EntertainmentItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedImage(url: item.metadata.poster) { image in image.resizable().scaledToFit() } placeholder: {
                Rectangle().fill(Theme.surface).overlay {
                    Image(systemName: item.kind == .movie ? "film" : "tv").font(.largeTitle).foregroundStyle(Theme.accent)
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.headline).lineLimit(3)
            if let year = item.metadata.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
            if item.sources.allSatisfy({ $0.availability != .available }) {
                Text("Availability unverified").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EntertainmentLibraryRow: View {
    let item: EntertainmentItem
    let progress: EntertainmentProgress?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .movie ? "film" : "play.rectangle").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline)
                if let progress, let duration = progress.duration {
                    ProgressView(value: min(1, progress.position / duration))
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
        }
        .padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EntertainmentDetailView: View {
    let itemID: String
    private let repository = EntertainmentRepository.shared
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var loading = false
    @State private var selectedSeason: Int?
    @State private var playback: EntertainmentPlaybackPresentation?
    @State private var failure: String?
    @State private var sourceChoice: EntertainmentItem?

    private var item: EntertainmentItem? { repository.item(for: itemID) }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 20) {
                    EntertainmentDetailHeader(item: item)
                    HStack {
                        Button {
                            repository.toggleWatchlist(item.id)
                        } label: {
                            Label(repository.watchlist.contains(item.id) ? "In Watchlist" : "Watchlist",
                                  systemImage: repository.watchlist.contains(item.id) ? "checkmark" : "plus")
                        }
                        .buttonStyle(.bordered)
                        if loading { ProgressView() }
                    }
                    if item.kind == .movie {
                        EntertainmentPlayButton(item: item) { chooseSource(item) }
                    } else {
                        EntertainmentEpisodeBrowser(series: item, selectedSeason: $selectedSeason, onPlay: chooseSource)
                    }
                    if let error = repository.sourceErrors[item.sources.first?.sourceID ?? UUID()] {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("Retry") { Task { await loadDetail() } }
                    }
                    EntertainmentCreditsView(metadata: item.metadata)
                }
                .padding(Theme.Spacing.screen)
            } else {
                ContentUnavailableView("Title unavailable", systemImage: "film",
                    description: Text("This title is no longer in your connected sources."))
            }
        }
        .background(Theme.background)
        .navigationTitle(item?.title ?? String(localized: "Library"))
        .inlineNavigationTitle()
        .task(id: itemID) { await loadDetail() }
        .confirmationDialog("Choose a source", isPresented: Binding(get: { sourceChoice != nil }, set: { if !$0 { sourceChoice = nil } })) {
            if let choice = sourceChoice {
                ForEach(choice.sources.filter { $0.availability == .available }) { source in
                    Button(sourceLabel(source)) { Task { await play(choice, source: source) } }
                }
            }
        }
        .alert("Playback unavailable", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .fullScreenCoverCompat(item: $playback) { presentation in
            EntertainmentPlayerView(presentation: presentation)
        }
    }

    private func sourceLabel(_ source: EntertainmentSource) -> String {
        let name = playlists.playlists.first { $0.id == source.sourceID }?.name ?? String(localized: "Source")
        return [name, source.quality, source.language].compactMap { $0 }.joined(separator: " · ")
    }

    private func loadDetail() async {
        guard let item else { return }
        loading = true
        await repository.detail(item, playlists: playlists.playlists)
        loading = false
    }

    private func chooseSource(_ item: EntertainmentItem) {
        let sources = item.sources.filter { $0.availability == .available }
        if sources.count == 1, let source = sources.first { Task { await play(item, source: source) } }
        else if !sources.isEmpty { sourceChoice = item }
    }

    private func play(_ item: EntertainmentItem, source: EntertainmentSource) async {
        do {
            let channel = try await repository.channel(for: item, source: source,
                playlists: playlists.playlists, channels: playlists.allChannels)
            playback = EntertainmentPlaybackPresentation(item: item, source: source, channel: channel)
        } catch {
            failure = (error as? EntertainmentError)?.localizedDescription ?? EntertainmentError.unavailable.localizedDescription
        }
    }
}

private struct EntertainmentDetailHeader: View {
    let item: EntertainmentItem
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let backdrop = item.metadata.backdrop {
                CachedImage(url: backdrop) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
                    .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
            }
            Text(item.title).font(.largeTitle.bold())
            if let original = item.metadata.originalTitle, original != item.title {
                Text(original).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                if let year = item.metadata.year { Text(String(year)) }
                if let runtime = item.metadata.runtimeMinutes { Text("\(runtime) min") }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if !item.metadata.genres.isEmpty { Text(item.metadata.genres.formatted(.list(type: .and))).font(.subheadline) }
            if let overview = item.metadata.overview { Text(overview).font(.body) }
            ForEach(item.metadata.ratings, id: \.source) { rating in
                Text("\(rating.source): \(rating.value, specifier: "%.1f") / \(rating.scale, specifier: "%.0f")").font(.caption)
            }
        }
    }
}

private struct EntertainmentCreditsView: View {
    let metadata: EntertainmentMetadata
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let director = metadata.director { Text("Director: \(director)").font(.subheadline) }
            if !metadata.cast.isEmpty {
                Text("Cast").font(.title2.bold())
                ForEach(Array(metadata.cast.enumerated()), id: \.offset) { _, credit in
                    VStack(alignment: .leading) {
                        Text(credit.name).font(.headline)
                        if let role = credit.role { Text(role).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
            if metadata.confidence != .unmatched { Text("Metadata: TMDB").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct EntertainmentPlayButton: View {
    let item: EntertainmentItem
    let onPlay: () -> Void
    private let repository = EntertainmentRepository.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isPlayable {
                Button(action: onPlay) {
                    Label(repository.watchProgress(for: item).map { !$0.completed && $0.position > 0 } == true ? "Resume" : "Play",
                          systemImage: "play.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                if let progress = repository.watchProgress(for: item), let duration = progress.duration {
                    ProgressView(value: min(1, progress.position / duration))
                    if progress.completed { Label("Watched", systemImage: "checkmark.circle").font(.caption) }
                    Button("Play from beginning") { repository.removeProgress(for: item); onPlay() }
                        .font(.subheadline)
                }
            } else {
                Label("Playback unavailable", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

private struct EntertainmentEpisodeBrowser: View {
    let series: EntertainmentItem
    @Binding var selectedSeason: Int?
    let onPlay: (EntertainmentItem) -> Void
    private let repository = EntertainmentRepository.shared
    private var seasons: [EntertainmentSeason] { repository.seasonsBySeries[series.id] ?? [] }
    private var selected: EntertainmentSeason? { seasons.first { $0.number == selectedSeason } ?? seasons.first }
    private var recommendedEpisode: EntertainmentItem? {
        let episodes = seasons.flatMap(\.episodes)
        let watched = episodes.filter { repository.watchProgress(for: $0) != nil }.sorted {
            (repository.watchProgress(for: $0)?.lastWatched ?? .distantPast) > (repository.watchProgress(for: $1)?.lastWatched ?? .distantPast)
        }
        guard let last = watched.first, let state = repository.watchProgress(for: last) else { return nil }
        if !state.completed, last.isPlayable { return last }
        guard state.completed, let index = episodes.firstIndex(where: { $0.id == last.id }) else { return nil }
        return episodes.dropFirst(index + 1).first { $0.isPlayable && $0.episodeNumber != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let recommendation = recommendedEpisode {
                Text("Continue Series").font(.title2.bold())
                Text(recommendation.title).font(.headline)
                EntertainmentPlayButton(item: recommendation) { onPlay(recommendation) }
            }
            if seasons.isEmpty {
                Text("No available episodes have been returned by this source.").foregroundStyle(.secondary)
            } else {
                Picker("Season", selection: $selectedSeason) {
                    ForEach(seasons) { season in
                        Text("Season \(season.number)").tag(Optional(season.number))
                    }
                }
                if let selected {
                    ForEach(selected.episodes) { episode in
                        VStack(alignment: .leading, spacing: 10) {
                            if let number = episode.episodeNumber { Text("Episode \(number)").font(.caption).foregroundStyle(.secondary) }
                            Text(episode.title).font(.headline)
                            if let image = episode.metadata.poster {
                                CachedImage(url: image) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
                                    .frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            if let runtime = episode.metadata.runtimeMinutes { Text("\(runtime) min").font(.caption) }
                            if let overview = episode.metadata.overview { Text(overview).font(.subheadline) }
                            EntertainmentPlayButton(item: episode) { onPlay(episode) }
                        }
                        .padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .onChange(of: seasons.map(\.number), initial: true) { _, numbers in
            if selectedSeason == nil || !numbers.contains(selectedSeason ?? -1) { selectedSeason = numbers.first }
        }
        .task(id: selected?.id) {
            if let selected { await repository.enrichSeason(selected, series: series) }
        }
    }
}

struct EntertainmentPlaybackPresentation: Identifiable {
    let item: EntertainmentItem
    let source: EntertainmentSource
    let channel: Channel
    var id: String { source.id }
}

/// Native on-demand controls drive the same PlaybackController and AVPlayer as live TV.
struct EntertainmentPlayerView: View {
    let presentation: EntertainmentPlaybackPresentation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = BannerAppEnvironment.shared.playbackController
    private let repository = EntertainmentRepository.shared
    @State private var failure: String?
    @State private var lastPosition: Double = 0

    var body: some View {
        NavigationStack {
            VideoPlayer(player: playback.player)
                .background(.black)
                .navigationTitle(presentation.item.title)
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
                .overlay {
                    if let failure {
                        VStack(spacing: 12) {
                            Text(failure)
                            Button("Retry") { start() }
                        }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if playback.showsBufferingIndicator { ProgressView() }
                }
        }
        .onAppear { start() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                saveProgress()
            }
        }
        .onDisappear {
            saveProgress()
            playback.onFailure = nil
            playback.onItemReady = nil
            if playback.channel?.id == presentation.channel.id { playback.stop() }
        }
    }

    private func start() {
        failure = nil
        let saved = repository.watchProgress(for: presentation.item)
        let position = saved?.completed == false ? saved?.position ?? 0 : 0
        lastPosition = position
        playback.onFailure = { _ in
            saveProgress()
            failure = String(localized: "This media could not be played. Check the connection or try another source.")
        }
        playback.load(presentation.channel, onDemand: true, resumePosition: position)
    }

    private func saveProgress() {
        guard playback.channel?.id == presentation.channel.id else { return }
        let position = playback.player.currentTime().seconds
        guard position.isFinite, position > 0, playback.currentItem?.status == .readyToPlay else { return }
        lastPosition = position
        if let progress = EntertainmentProgress.recording(contentID: presentation.item.progressID, variant: presentation.source.id,
            position: position, duration: playback.currentItem?.duration.seconds) { repository.record(progress) }
    }
}
