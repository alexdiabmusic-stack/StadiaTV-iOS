import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var articleLibrary: ArticleLibraryStore
    @EnvironmentObject private var podcastStore: PodcastStore
    @StateObject private var viewModel = NewsViewModel()
    @State private var selectedSport: DiscoverSportFilter = .forYou
    @State private var presentedArticle: ESPNArticle?
    @State private var showingPodcasts = false

    private var targetLeagues: [League] {
        switch selectedSport {
        case .forYou:
            return prefs.followedLeagues
        case .all:
            return League.all
        case .league(let shortName):
            return League.all.filter { $0.shortName == shortName }
        case .soccer:
            return League.all.filter { $0.group == .soccer }
        case .tennis:
            return League.all.filter { $0.group == .tennis }
        }
    }

    private var displayedArticles: [ESPNArticle] {
        viewModel.articles(for: nil)
            .filter { targetLeagues.contains($0.league) && !$0.isHighlight }
            .filter { !articleLibrary.isHidden($0) && !articleLibrary.isMuted($0) }
    }

    private var heroArticle: ESPNArticle? {
        displayedArticles.first
    }

    private var remainingArticles: [ESPNArticle] {
        Array(displayedArticles.dropFirst())
    }

    private var teamArticles: [ESPNArticle] {
        let teamTokens = prefs.favoriteTeams.flatMap { [$0.displayName.lowercased(), $0.abbreviation.lowercased()] }
        guard !teamTokens.isEmpty else { return [] }
        return remainingArticles.filter { article in
            let text = "\(article.headline) \(article.description)".lowercased()
            return teamTokens.contains { token in !token.isEmpty && text.contains(token) }
        }
        .prefix(4)
        .map { $0 }
    }

    private var latestArticles: [ESPNArticle] {
        let excluded = Set(([heroArticle].compactMap { $0 } + teamArticles).map(\.id))
        return remainingArticles.filter { !excluded.contains($0.id) }.prefix(24).map { $0 }
    }

    private var podcastFeeds: [PodcastCatalog.CatalogFeed] {
        podcastStore.catalogFeedsForFollowedSports(targetLeagues)
    }

    @ViewBuilder
    private var podcastCarouselSection: some View {
        if !podcastFeeds.isEmpty {
            PodcastCarousel(feeds: podcastFeeds, onShowAll: { showingPodcasts = true })
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    stickyFilters
                    content
                }
            }
            .navigationTitle("Discover")
            .searchToolbar()
            .navigationDestination(item: $presentedArticle) { article in
                ArticleReaderView(article: article)
            }
            .sheet(isPresented: $showingPodcasts) {
                PodcastBrowserView()
            }
        }
        .tint(Theme.accent)
        .task(id: prefs.followedLeagues.map(\.id).joined(separator: ",")) {
            await viewModel.load(leagues: prefs.followedLeagues)
        }
        .task(id: selectedSport.id) {
            await loadTargetLeaguesIfNeeded()
        }
    }

    private var stickyFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sports news and stories")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DiscoverSportFilter.allCases) { filter in
                        filterChip(title: filter.title, isSelected: selectedSport == filter) {
                            withAnimation(.snappy) { selectedSport = filter }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if viewModel.isLoading && displayedArticles.isEmpty {
            Spacer()
            ProgressView().tint(Theme.accent)
            Spacer()
        } else if displayedArticles.isEmpty {
            emptyState
        } else {
            articleList
        }
    }

    private var articleList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let heroArticle {
                    Button { open(article: heroArticle) } label: {
                        HeroArticleCard(
                            article: heroArticle,
                            isSaved: articleLibrary.isSaved(heroArticle),
                            onToggleSaved: { articleLibrary.toggleSaved(heroArticle) },
                            onHide: { articleLibrary.hide(heroArticle) },
                            onMute: { articleLibrary.muteSource(for: heroArticle) }
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !teamArticles.isEmpty {
                    DiscoverSectionHeader(title: "FROM YOUR TEAMS", actionTitle: "See All")
                    VStack(spacing: 0) {
                        ForEach(teamArticles) { article in
                            Button { open(article: article) } label: {
                                TeamNewsRow(
                                    article: article,
                                    isSaved: articleLibrary.isSaved(article),
                                    onToggleSaved: { articleLibrary.toggleSaved(article) },
                                    onHide: { articleLibrary.hide(article) },
                                    onMute: { articleLibrary.muteSource(for: article) }
                                )
                            }
                            .buttonStyle(.plain)
                            if article.id != teamArticles.last?.id { Divider().overlay(Theme.hairline) }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                }


                podcastCarouselSection

                if !latestArticles.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(latestArticles.enumerated()), id: \.element.id) { index, article in
                            Button { open(article: article) } label: {
                                if index.isMultiple(of: 3) {
                                    StandardArticleCard(
                                        article: article,
                                        isSaved: articleLibrary.isSaved(article),
                                        onToggleSaved: { articleLibrary.toggleSaved(article) },
                                        onHide: { articleLibrary.hide(article) },
                                        onMute: { articleLibrary.muteSource(for: article) }
                                    )
                                } else {
                                    CompactArticleRow(
                                        article: article,
                                        isSaved: articleLibrary.isSaved(article),
                                        onToggleSaved: { articleLibrary.toggleSaved(article) },
                                        onHide: { articleLibrary.hide(article) },
                                        onMute: { articleLibrary.muteSource(for: article) }
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            if article.id != latestArticles.last?.id { Divider().overlay(Theme.hairline) }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                }
            }
            .padding(20)
        }
        .refreshable {
            await refreshTargetLeagues()
        }
    }


    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "newspaper")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary.opacity(0.45))
            Text("No stories yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Try another sport or refresh the feed.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Button("Try Again") {
                Task { await refreshTargetLeagues() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Spacer()
        }
        .padding(32)
    }

    private func open(article: ESPNArticle) {
        presentedArticle = article
    }

    private func loadTargetLeaguesIfNeeded() async {
        for league in targetLeagues.prefix(selectedSport == .all ? 8 : targetLeagues.count) {
            await viewModel.loadIfNeeded(league: league)
        }
    }

    private func refreshTargetLeagues() async {
        let leagues = Array(targetLeagues.prefix(selectedSport == .all ? 8 : targetLeagues.count))
        await viewModel.load(leagues: leagues)
    }
}

private enum DiscoverSportFilter: Hashable, Identifiable, CaseIterable {
    case forYou
    case all
    case league(String)
    case soccer
    case tennis

    static let allCases: [DiscoverSportFilter] = [.forYou, .all, .league("NHL"), .league("MLB"), .league("NBA"), .soccer, .league("F1"), .tennis]

    var id: String { title }

    var title: String {
        switch self {
        case .forYou: "For You"
        case .all: "All"
        case .league(let shortName): shortName
        case .soccer: "Soccer"
        case .tennis: "Tennis"
        }
    }
}

private struct DiscoverSectionHeader: View {
    let title: String
    let actionTitle: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if let actionTitle {
                Text(actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct HeroArticleCard: View {
    let article: ESPNArticle
    let isSaved: Bool
    let onToggleSaved: () -> Void
    let onHide: () -> Void
    let onMute: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArticleImage(url: article.imageURL)
                .aspectRatio(16 / 9, contentMode: .fit)
            LinearGradient(
                colors: [.clear, .black.opacity(0.88)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(article.league.shortName)
                    if let badge = article.badgeText {
                        Text(badge)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(badge == "BREAKING" ? Theme.live : Theme.accent, in: Capsule())
                    }
                }
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)

                Text(article.headline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)


                Text(article.metadataLine(includeSource: true))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .contextMenu { ArticleContextActions(article: article, isSaved: isSaved, onToggleSaved: onToggleSaved, onHide: onHide, onMute: onMute) }
    }
}

private struct TeamNewsRow: View {
    let article: ESPNArticle
    let isSaved: Bool
    let onToggleSaved: () -> Void
    let onHide: () -> Void
    let onMute: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArticleImage(url: article.imageURL)
                .frame(width: 60, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(article.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(article.metadataLine(includeSource: false))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .contextMenu { ArticleContextActions(article: article, isSaved: isSaved, onToggleSaved: onToggleSaved, onHide: onHide, onMute: onMute) }
    }
}


private struct StandardArticleCard: View {
    let article: ESPNArticle
    let isSaved: Bool
    let onToggleSaved: () -> Void
    let onHide: () -> Void
    let onMute: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(article.metadataLine(includeSource: true))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(article.headline)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !article.description.isEmpty {
                    Text(article.description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            ArticleImage(url: article.imageURL)
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .contextMenu { ArticleContextActions(article: article, isSaved: isSaved, onToggleSaved: onToggleSaved, onHide: onHide, onMute: onMute) }
    }
}

private struct CompactArticleRow: View {
    let article: ESPNArticle
    let isSaved: Bool
    let onToggleSaved: () -> Void
    let onHide: () -> Void
    let onMute: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArticleImage(url: article.imageURL)
                .frame(width: 66, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(article.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(article.metadataLine(includeSource: false))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .contextMenu { ArticleContextActions(article: article, isSaved: isSaved, onToggleSaved: onToggleSaved, onHide: onHide, onMute: onMute) }
    }
}

private struct ArticleImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Theme.surfaceElevated.overlay {
                    Image(systemName: "newspaper.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.55))
                }
            }
        }
        .clipped()
    }
}

private struct ArticleContextActions: View {
    let article: ESPNArticle
    let isSaved: Bool
    let onToggleSaved: () -> Void
    let onHide: () -> Void
    let onMute: () -> Void

    var body: some View {
        Button(action: onToggleSaved) {
            Label(isSaved ? "Remove Saved Article" : "Save Article", systemImage: isSaved ? "bookmark.slash" : "bookmark")
        }
        if let url = article.url {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button(action: onHide) { Label("Hide stories like this", systemImage: "eye.slash") }
        Button(action: onMute) { Label("Mute this source", systemImage: "speaker.slash") }
    }
}

private extension ESPNArticle {
    var sourceName: String {
        guard let byline, !byline.isEmpty else { return "ESPN" }
        return byline.replacingOccurrences(of: "ESPN", with: "ESPN")
    }

    var isHighlight: Bool {
        let text = "\(type ?? "") \(headline) \(categories.joined(separator: " "))".lowercased()
        return text.contains("highlight") || text.contains("video") || text.contains("media") || text.contains("play")
    }

    var badgeText: String? {
        let text = "\(type ?? "") \(headline) \(categories.joined(separator: " "))".lowercased()
        if text.contains("breaking") || text.contains("injury") || text.contains("trade") { return "BREAKING" }
        if text.contains("analysis") { return "ANALYSIS" }
        if text.contains("rumor") || text.contains("rumour") { return "RUMOUR" }
        if isHighlight { return "HIGHLIGHT" }
        return nil
    }


    var relativePublishedText: String {
        guard let published else { return "Just now" }
        let seconds = max(0, Int(Date().timeIntervalSince(published)))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        if hours < 48 { return "Yesterday" }
        let days = hours / 24
        return "\(days) days ago"
    }

    func metadataLine(includeSource: Bool) -> String {
        if includeSource {
            return "\(sourceName) · \(league.shortName) · \(relativePublishedText)"
        }
        return "\(league.shortName) · \(relativePublishedText)"
    }
}
