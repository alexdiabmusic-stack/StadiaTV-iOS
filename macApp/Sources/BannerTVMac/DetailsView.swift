import SwiftUI

/// What the sources sheet is choosing a stream for.
struct SourceTarget: Identifiable {
    let id = UUID()
    let ref: TitleRef
    let videoId: String
    let title: String
    let subtitle: String?
    let next: Episode?
    var upcoming: [Episode] = []
    var season: Int? = nil
    var episode: Int? = nil
    var startAt: Double? = nil
    /// When set, the first direct source from this add-on starts automatically (used for "next episode").
    var autoPickAddon: String? = nil
}

struct DetailsView: View {
    @StateObject private var model: DetailsModel
    @EnvironmentObject private var router: Router

    init(ref: TitleRef) { _model = StateObject(wrappedValue: DetailsModel(ref: ref)) }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text(model.ref.name).font(.jb(16)).foregroundStyle(Theme.textSecondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 12) {
                    Text("Details unavailable").font(.jb(26, .bold))
                    Text("None of your installed add-ons has details for \(model.ref.name).").font(.jb(15)).foregroundStyle(Theme.textSecondary)
                    Button("Try Again") { model.load() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 44))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let details):
                DetailsContent(details: details)
            }
        }
        .background(Theme.background)
        .task { model.load() }
    }
}

private struct DetailsContent: View {
    let details: TitleDetails
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var data: UserDataModel
    @State private var season: Int
    @State private var expanded = false

    init(details: TitleDetails) {
        self.details = details
        _season = State(initialValue: details.seasons.first(where: { $0 > 0 }) ?? details.seasons.first ?? 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    hero(height: min(max(proxy.size.height * 0.78, 520), 720))
                    VStack(alignment: .leading, spacing: 26) {
                        actions
                        metaRow
                        crew
                        if let blurb = details.blurb { overview(blurb) }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, Theme.gutter).padding(.top, 8)
                    if details.isSeries { episodesSection.padding(.top, 34) }
                    if !details.cast.isEmpty { castSection.padding(.top, 34) }
                }
                .padding(.bottom, 70)
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear { if DebugHarness.pressPlay { playPrimary() } }
    }

    // MARK: Hero

    private func hero(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: details.backdrop).frame(maxWidth: .infinity).frame(height: height).clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.4), location: 0), .init(color: .clear, location: 0.22),
                                   .init(color: Theme.background.opacity(0.5), location: 0.7), .init(color: Theme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                if let logo = details.logo {
                    AsyncImage(url: logo) { phase in
                        if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) }
                        else { Text(details.ref.name).font(.jb(48, .bold)) }
                    }
                    .frame(maxWidth: 520, maxHeight: 170)
                } else {
                    Text(details.ref.name).font(.jb(48, .bold)).multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 760)
                }
                if !details.genres.isEmpty {
                    Text(details.genres.prefix(3).joined(separator: "  •  ")).font(.jb(18)).foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.bottom, 22).padding(.horizontal, Theme.gutter)
        }
        .frame(height: height)
    }

    // MARK: Actions and facts

    private var actions: some View {
        HStack(spacing: 12) {
            Button { playPrimary() } label: { Label(primaryLabel, systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 56))
            Button { data.setSaved(details, saved: !data.isSaved(details.ref)) } label: {
                Image(systemName: data.isSaved(details.ref) ? "checkmark" : "plus")
            }
            .buttonStyle(CircleButtonStyle(filled: data.isSaved(details.ref), size: 56)).help(data.isSaved(details.ref) ? "Remove from My List" : "Add to My List")
            if !details.isSeries {
                let watched = data.isWatched(contentId: details.ref.id, season: nil, episode: nil)
                Button { data.setWatched(details.ref, title: details.ref.name, season: nil, episode: nil, watched: !watched) } label: {
                    Image(systemName: watched ? "eye.fill" : "eye")
                }
                .buttonStyle(CircleButtonStyle(filled: false, size: 56)).help(watched ? "Mark as unwatched" : "Mark as watched")
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 16) {
            if let y = details.year { Text(y).font(.jb(18, .bold)) }
            if let r = details.runtime { Text(r).font(.jb(18, .bold)) }
            if let a = details.ageRating {
                Text(a).font(.jb(14, .semibold)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.4), lineWidth: 1))
            }
            if let r = details.rating {
                HStack(spacing: 6) { Text("IMDb").foregroundStyle(Theme.textSecondary); Text(r).foregroundStyle(Theme.imdb) }.font(.jb(18, .bold))
            }
        }
    }

    @ViewBuilder private var crew: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !details.directors.isEmpty { creditLine("Director:", details.directors.joined(separator: ", ")) }
            if !details.writers.isEmpty { creditLine("Writer:", details.writers.prefix(4).joined(separator: ", ")) }
        }
    }

    private func creditLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.jb(16, .semibold)).foregroundStyle(Theme.textMuted)
            Text(value).font(.jb(16))
        }
    }

    private func overview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.jb(16)).lineSpacing(5).lineLimit(expanded ? nil : 4)
            if text.count > 220 {
                Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Text(expanded ? "Show Less ▴" : "Show More ▾").font(.jb(15, .semibold)).foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Playing

    private var firstEpisode: Episode? {
        details.episodes.filter { $0.season > 0 }.min { ($0.season, $0.number) < ($1.season, $1.number) } ?? details.episodes.first
    }

    /// The episode to continue with: what Continue Watching holds for this series, otherwise the first one.
    private var seriesTarget: Episode? {
        if let card = data.continueCards.first(where: { $0.ref.key == details.ref.key }),
           let e = details.episodes.first(where: { $0.id == card.videoId }) { return e }
        return firstEpisode
    }

    private var movieVideoId: String { details.defaultVideoId ?? details.ref.id }

    private var primaryLabel: String {
        if details.isSeries, let e = seriesTarget {
            let resuming = data.resumePosition(videoId: e.id) != nil
            return (resuming ? "Resume" : "Play") + " S\(e.season) E\(e.number)"
        }
        if data.isWatched(contentId: details.ref.id, season: nil, episode: nil) { return "Watch Again" }
        return data.resumePosition(videoId: movieVideoId) != nil ? "Resume" : "Play"
    }

    private func playPrimary() {
        if details.isSeries, let e = seriesTarget { choose(e) }
        else {
            router.sourceTarget = SourceTarget(ref: details.ref, videoId: movieVideoId, title: details.ref.name, subtitle: nil, next: nil,
                                               startAt: data.resumePosition(videoId: movieVideoId))
        }
    }

    private func choose(_ episode: Episode) {
        let all = details.episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        let now = Date()
        let later = all.firstIndex(of: episode).map { Array(all.suffix(from: $0 + 1)).filter { $0.season > 0 && $0.available && ($0.released ?? .distantPast) <= now } } ?? []
        router.sourceTarget = SourceTarget(ref: details.ref, videoId: episode.id, title: details.ref.name,
                              subtitle: "S\(episode.season) E\(episode.number)  \(episode.title)", next: later.first, upcoming: later, season: episode.season, episode: episode.number,
                              startAt: data.resumePosition(videoId: episode.id))
    }

    // MARK: Episodes and cast

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Episodes").font(.jb(24, .semibold)).padding(.horizontal, Theme.gutter)
            if details.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(details.seasons, id: \.self) { s in Chip(title: s == 0 ? "Specials" : "Season \(s)", selected: s == season) { season = s } }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
            }
            VStack(spacing: 12) {
                ForEach(details.episodes(in: season)) { episode in
                    Button { choose(episode) } label: {
                        EpisodeRow(episode: episode,
                                   watched: data.isWatched(contentId: details.ref.id, season: episode.season, episode: episode.number),
                                   fraction: data.fraction(contentId: details.ref.id, season: episode.season, episode: episode.number))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        let watched = data.isWatched(contentId: details.ref.id, season: episode.season, episode: episode.number)
                        Button(watched ? "Mark as Unwatched" : "Mark as Watched") {
                            data.setWatched(details.ref, title: episode.title, season: episode.season, episode: episode.number, watched: !watched)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Cast")
            HShelf(spacing: 22) {
                ForEach(details.cast.prefix(24)) { person in
                    VStack(spacing: 8) {
                        AsyncImage(url: person.photo) { phase in
                            if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                            else { Image(systemName: "person.fill").font(.system(size: 34)).foregroundStyle(Theme.textMuted) }
                        }
                        .frame(width: 104, height: 104).background(Theme.surface).clipShape(Circle())
                        Text(person.name).font(.jb(14, .semibold)).lineLimit(2).multilineTextAlignment(.center)
                        if let role = person.role { Text(role).font(.jb(12)).foregroundStyle(Theme.textMuted).lineLimit(1) }
                    }
                    .frame(width: 118)
                }
            }
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    let watched: Bool
    let fraction: Double?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RemoteImage(url: episode.thumbnail)
                Image(systemName: watched ? "checkmark.circle.fill" : "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
                if let f = fraction, f > 0.01, f < 0.9 {
                    VStack { Spacer(); GeometryReader { g in
                        ZStack(alignment: .leading) { Color.white.opacity(0.25); Color.white.frame(width: g.size.width * f) }
                    }.frame(height: 4) }
                }
            }
            .frame(width: 216, height: 122).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(episode.number). \(episode.title)").font(.jb(17, .semibold)).lineLimit(1)
                    Spacer()
                    if let m = episode.runtimeMinutes { Text("\(m)m").foregroundStyle(Theme.textMuted).font(.jb(14)) }
                }
                if let o = episode.overview { Text(o).font(.jb(14)).foregroundStyle(Theme.textSecondary).lineLimit(3) }
                if !episode.available || (episode.released ?? .distantPast) > Date() {
                    Text(episode.released.map { "Releases \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Not released")
                        .font(.jb(13, .semibold)).foregroundStyle(Theme.accentStart)
                }
            }
        }
        .padding(12)
        .background(hovering ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusPoster + 4, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
