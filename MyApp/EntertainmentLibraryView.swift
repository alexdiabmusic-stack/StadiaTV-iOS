import SwiftUI
import AVKit

struct EntertainmentLibraryView: View {
    var fixedKind: EntertainmentKind? = nil
    @EnvironmentObject private var playlists: PlaylistStore
    private let repository = EntertainmentRepository.shared
    @State private var query = ""
    @State private var sourceID = ""
    @State private var releaseYear = ""
    @State private var availableOnly = false
    @State private var years: [Int] = []
    @State private var recommended: [EntertainmentItem] = []
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
                if fixedKind != nil && query.isEmpty && !watchlistOnly && category.isEmpty && genre.isEmpty {
                    if let featured = recommended.first { CompleteHero(item: featured) }
                    CompleteContentRail(title: "Explore Your Library", items: Array(recommended.dropFirst()), showsProgress: false)
                }
                if !continuing.isEmpty {
                    Text("Continue Watching").font(.title2.bold())
                    ForEach(continuing) { item in
                        NavigationLink(value: item.seriesID ?? item.id) {
                            EntertainmentLibraryRow(item: item, progress: repository.watchProgress(for: item))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from Continue Watching", role: .destructive) { repository.hideFromContinueWatching(item) }
                        }
                    }
                }
                if fixedKind == nil { Picker("Content type", selection: $kind) {
                    Text("Movies").tag(EntertainmentKind.movie)
                    Text("TV Shows").tag(EntertainmentKind.series)
                }
                .pickerStyle(.segmented) }
                if repository.isRefreshing && results.isEmpty && repository.sourceErrors.isEmpty {
                    ProgressView("Loading your library…").frame(maxWidth: .infinity).padding()
                } else if results.isEmpty {
                    ContentUnavailableView("No titles found", systemImage: "film", description:
                        Text("Your library shows movies and series from your connected sources. Add a supported source in Settings or change your filters."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)], spacing: 22) {
                        ForEach(results) { item in
                            NavigationLink(value: item.id) {
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
        .navigationDestination(for: String.self) { EntertainmentDetailView(itemID: $0) }
        .navigationTitle(fixedKind == .movie ? "Movies" : fixedKind == .series ? "Series" : "Library")
        .searchable(text: $query, prompt: "Search your library")
        .toolbar {
            Menu {
                Toggle("Watchlist", isOn: $watchlistOnly)
                Toggle("Available Only", isOn: $availableOnly)
                Picker("Source", selection: $sourceID) {
                    Text("All Sources").tag("")
                    ForEach(playlists.playlists) { Text($0.name).tag($0.id.uuidString) }
                }
                Picker("Release Year", selection: $releaseYear) {
                    Text("All Years").tag("")
                    ForEach(years, id: \.self) { Text(String($0)).tag(String($0)) }
                }
                NavigationLink("Watchlist & History") { EntertainmentCollectionsView() }
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
        .task(id: "\(repository.revision)|\(query)|\(kind.rawValue)|\(watchlistOnly)|\(recentFirst)|\(category)|\(genre)|\(sourceID)|\(releaseYear)|\(availableOnly)|\(repository.userStateRevision)") {
            await updateResults()
        }
    }

    private func refresh(force: Bool) async {
        await repository.sync(playlists: playlists.playlists, channels: playlists.allChannels, force: force)
    }

    private func updateResults() async {
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        let items = repository.catalog
        let selectedSource = sourceID, selectedYear = releaseYear, onlyAvailable = availableOnly
        let progress = repository.progress
        let hidden = repository.hiddenContinueWatching
        let episodes = repository.seasonsBySeries.values.flatMap { $0.flatMap(\.episodes) }
        let watchlist = repository.watchlist
        let query = query, kind = fixedKind ?? kind, only = watchlistOnly, newest = recentFirst, category = category, genre = genre
        let result = await Task.detached(priority: .userInitiated) {
            let key = EntertainmentMatching.normalized(query)
            let matches = items.filter {
                $0.kind == kind && (!only || watchlist.contains($0.id)) &&
                (selectedSource.isEmpty || $0.sources.contains { $0.sourceID.uuidString == selectedSource }) &&
                (selectedYear.isEmpty || $0.metadata.year.map(String.init) == selectedYear) &&
                (!onlyAvailable || $0.isPlayable || ($0.kind == .series && $0.sources.contains { $0.availability == .available })) &&
                (category.isEmpty || $0.sources.contains { $0.category == category }) &&
                (genre.isEmpty || $0.metadata.genres.contains(genre)) &&
                (key.isEmpty || EntertainmentMatching.normalized($0.title + " " + $0.metadata.genres.joined(separator: " ")).contains(key))
            }.sorted {
                if newest, $0.addedAt != $1.addedAt { return ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let categories = Set(items.flatMap { $0.sources.compactMap(\.category) }).sorted()
            let continuing = (items + episodes).filter {
                guard (kind == .movie ? $0.kind == .movie : $0.kind == .episode),
                      let state = progress[$0.progressID] ?? progress[$0.id] else { return false }
                return !hidden.contains($0.progressID) && !state.completed && state.position > 0 && $0.isPlayable
            }.sorted { ((progress[$0.progressID] ?? progress[$0.id])?.lastWatched ?? .distantPast) > ((progress[$1.progressID] ?? progress[$1.id])?.lastWatched ?? .distantPast) }
            let recommendations = EntertainmentDiscovery.recommendations(items: matches, kind: kind,
                progress: progress, watchlist: watchlist, excluding: Set(continuing.map(\.id)), limit: 8)
            return (matches, categories, Array(continuing.prefix(10)), Set(items.flatMap { $0.metadata.genres }).sorted(),
                Set(items.compactMap { $0.metadata.year }).sorted(by: >), recommendations)
        }.value
        guard !Task.isCancelled else { return }
        results = result.0; categories = result.1; continuing = result.2; genres = result.3; years = result.4; recommended = result.5
    }
}

struct EntertainmentPosterCard: View {
    let item: EntertainmentItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedImage(url: item.metadata.poster) { image in image.resizable().scaledToFit() } placeholder: {
                Rectangle().fill(Theme.surface).overlay {
                    Image(systemName: item.kind == .movie ? "film" : "tv").font(.largeTitle).foregroundStyle(Theme.accent)
                }
            }
            .aspectRatio(item.kind == .episode ? 16 / 9 : 2 / 3, contentMode: .fit)
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

struct EntertainmentLibraryRow: View {
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
                        if item.kind != .series {
                            Button(repository.watchProgress(for: item)?.completed == true ? "Mark Unwatched" : "Mark Watched") {
                                if repository.watchProgress(for: item)?.completed == true { repository.removeProgress(for: item) }
                                else { repository.markWatched(item) }
                            }
                        }
                        if loading { ProgressView() }
                    }
                    if item.kind != .series {
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
                ForEach(choice.sources.filter { $0.availability == .available && $0.container?.isEmpty == false }) { source in
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
        let sources = item.sources.filter { $0.availability == .available && $0.container?.isEmpty == false }
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
                if let rating = item.metadata.contentRating { Text(rating) }
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
        EntertainmentDiscovery.nextEpisode(seriesID: series.id,
            episodes: seasons.flatMap(\.episodes), progress: repository.progress)
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
                        Text("Season \(season.number) · \(season.episodes.filter(\.isPlayable).count) available").tag(Optional(season.number))
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
    @State private var presentation: EntertainmentPlaybackPresentation
    @State private var nextEpisode: EntertainmentItem?
    @State private var changingEpisode = false
    @State private var choosingAlternative = false
    @EnvironmentObject private var playlists: PlaylistStore
    @AppStorage("banner.playback.autoplayEpisodes.v1") private var autoplay = false

    init(presentation: EntertainmentPlaybackPresentation) {
        _presentation = State(initialValue: presentation)
    }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = BannerAppEnvironment.shared.playbackController
    private let repository = EntertainmentRepository.shared
    @State private var failure: String?
    @State private var lastPosition: Double = 0
    @Environment(\.scenePhase) private var scenePhase

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
                            if presentation.item.sources.contains(where: { $0.id != presentation.source.id && $0.availability == .available && $0.container?.isEmpty == false }) {
                                Button("Choose Another Source") { choosingAlternative = true }
                            }
                        }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if let nextEpisode {
                        VStack(spacing: 12) {
                            Text("Up Next").font(.headline)
                            Text(nextEpisode.title)
                            Button("Play Next Episode") { Task { await playNext(nextEpisode) } }
                                .disabled(changingEpisode)
                        }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if playback.showsBufferingIndicator { ProgressView() }
                }
        }
        .confirmationDialog("Choose Another Source", isPresented: $choosingAlternative) {
            ForEach(presentation.item.sources.filter { $0.id != presentation.source.id && $0.availability == .available && $0.container?.isEmpty == false }) { source in
                Button(playlists.playlists.first(where: { $0.id == source.sourceID })?.name ?? String(localized: "Source")) {
                    Task { await switchSource(source) }
                }
            }
        }
        .onAppear { start() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveProgress() } }
        .onChange(of: playback.state) { _, state in
            if state == .paused { saveProgress() }
            if state == .ended {
                saveProgress()
                if let seriesID = presentation.item.seriesID {
                    nextEpisode = EntertainmentDiscovery.nextEpisode(seriesID: seriesID,
                        episodes: repository.seasonsBySeries[seriesID]?.flatMap(\.episodes) ?? [],
                        progress: repository.progress)
                }
            }
        }
        .task(id: nextEpisode?.id) {
            if autoplay, scenePhase == .active, let nextEpisode { await playNext(nextEpisode) }
        }
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

    private func switchSource(_ source: EntertainmentSource) async {
        guard !changingEpisode else { return }
        changingEpisode = true
        defer { changingEpisode = false }
        saveProgress()
        do {
            let channel = try await repository.channel(for: presentation.item, source: source,
                playlists: playlists.playlists, channels: playlists.allChannels)
            guard !Task.isCancelled else { return }
            presentation = EntertainmentPlaybackPresentation(item: presentation.item, source: source, channel: channel)
            start()
        } catch {
            failure = String(localized: "This source could not be opened. Choose another source or try again.")
        }
    }

    private func playNext(_ episode: EntertainmentItem) async {
        guard !changingEpisode else { return }
        changingEpisode = true
        defer { changingEpisode = false }
        let sources = episode.sources.filter { $0.availability == .available && $0.container?.isEmpty == false }
        guard let source = sources.first(where: { $0.sourceID == presentation.source.sourceID }) ?? sources.first else { return }
        do {
            let channel = try await repository.channel(for: episode, source: source,
                playlists: playlists.playlists, channels: playlists.allChannels)
            guard !Task.isCancelled else { return }
            saveProgress()
            presentation = EntertainmentPlaybackPresentation(item: episode, source: source, channel: channel)
            nextEpisode = nil
            start()
        } catch {
            failure = String(localized: "The next episode could not be opened. Please try again from the series.")
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
            position: position, duration: playback.currentItem?.duration.seconds) { repository.record(progress, item: presentation.item) }
    }
}
