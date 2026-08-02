import SwiftUI
import Combine

struct NewsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @StateObject private var viewModel = NewsViewModel()
    @State private var selectedLeagueID: String?
    @State private var presentedArticle: ESPNArticle?

    /// Filter options: followed leagues first, then the rest of the catalog.
    private var filterLeagues: [League] {
        let followed = prefs.followedLeagues
        let followedIDs = Set(followed.map(\.id))
        return followed + League.all.filter { !followedIDs.contains($0.id) }
    }

    private var selectedLeague: League? {
        selectedLeagueID.flatMap { id in League.all.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterBar
                    content
                }
            }
            .navigationTitle("News")
            .searchToolbar()
            .navigationDestination(item: $presentedArticle) { article in
                ArticleReaderView(article: article)
            }
        }
        .tint(Theme.accent)
        .task(id: prefs.followedLeagues.map(\.id).joined(separator: ",")) {
            await viewModel.load(leagues: prefs.followedLeagues)
        }
        .task(id: selectedLeagueID) {
            if let league = selectedLeague {
                await viewModel.loadIfNeeded(league: league)
            }
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", isSelected: selectedLeagueID == nil) {
                    selectedLeagueID = nil
                }
                ForEach(filterLeagues) { league in
                    filterChip(title: league.shortName, isSelected: selectedLeagueID == league.id) {
                        selectedLeagueID = league.id
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    private var displayedArticles: [ESPNArticle] {
        viewModel.articles(for: selectedLeague)
    }

    @ViewBuilder private var content: some View {
        let isLoadingSelection = selectedLeague.map { viewModel.isLoadingLeague($0) } ?? viewModel.isLoading
        if isLoadingSelection && displayedArticles.isEmpty {
            Spacer()
            ProgressView().tint(Theme.accent)
            Spacer()
        } else if displayedArticles.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "newspaper")
                    .font(.system(size: Theme.scaled(44)))
                    .foregroundStyle(Theme.textSecondary)
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task {
                        if let league = selectedLeague {
                            await viewModel.loadIfNeeded(league: league, force: true)
                        } else {
                            await viewModel.load(leagues: prefs.followedLeagues)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(32)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(displayedArticles) { article in
                        NewsArticleCard(article: article) {
                            presentedArticle = article
                        }
                    }

                    if viewModel.hasMore(for: selectedLeague) {
                        if viewModel.isLoadingMore {
                            ProgressView()
                                .tint(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        } else {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    Task { await viewModel.loadMore(league: selectedLeague) }
                                }
                        }
                    }
                }
                .padding(16)
            }
            #if !os(tvOS)
            .refreshable {
                if let league = selectedLeague {
                    await viewModel.loadIfNeeded(league: league, force: true)
                } else {
                    await viewModel.load(leagues: prefs.followedLeagues)
                }
            }
            #endif
        }
    }

    private var emptyText: String {
        if let league = selectedLeague {
            return "ESPN did not return news for \(league.name)."
        }
        return "ESPN did not return news for your followed leagues."
    }
}


@MainActor
final class NewsViewModel: ObservableObject {
    /// Articles cached per league id so filter switches don't refetch.
    @Published private(set) var articlesByLeague: [String: [ESPNArticle]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadingLeagueIDs: Set<String> = []
    @Published private(set) var isLoadingMore = false

    private let service = ESPNService()
    private var pagesByLeague: [String: Int] = [:]   // last page fetched per league (1-indexed)
    private var exhaustedLeagues: Set<String> = []   // leagues with no more pages
    private var followedLeagueIDs: [String] = []     // kept so loadMore("All") knows which leagues to page

    func isLoadingLeague(_ league: League) -> Bool {
        loadingLeagueIDs.contains(league.id) || isLoading
    }

    func hasMore(for league: League?) -> Bool {
        if let league { return !exhaustedLeagues.contains(league.id) }
        return exhaustedLeagues.count < followedLeagueIDs.count
    }

    /// Articles for one league, or every loaded league merged when nil.
    func articles(for league: League?) -> [ESPNArticle] {
        let pool: [ESPNArticle]
        if let league {
            pool = articlesByLeague[league.id] ?? []
        } else {
            pool = articlesByLeague.values.flatMap { $0 }
        }
        // De-dupe by id, then by headline so the same story from both feeds collapses.
        let byID = Dictionary(grouping: pool, by: \.id).compactMap { $0.value.first }
        let unique = Dictionary(grouping: byID, by: { $0.headline.lowercased() }).compactMap { $0.value.first }
        return unique.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
    }

    func load(leagues: [League]) async {
        pagesByLeague = [:]
        exhaustedLeagues = []
        followedLeagueIDs = leagues.map(\.id)
        isLoading = true
        await withTaskGroup(of: (String, [ESPNArticle]).self) { group in
            for league in leagues {
                group.addTask {
                    (league.id, await self.fetch(league: league, page: 1))
                }
            }
            for await (id, articles) in group {
                articlesByLeague[id] = articles
                pagesByLeague[id] = 1
            }
        }
        isLoading = false
    }

    /// Fetches a single league on demand (used by filter chips outside the followed set).
    func loadIfNeeded(league: League, force: Bool = false) async {
        if !force, articlesByLeague[league.id]?.isEmpty == false { return }
        if !force, loadingLeagueIDs.contains(league.id) { return }
        loadingLeagueIDs.insert(league.id)
        defer { loadingLeagueIDs.remove(league.id) }
        let articles = await fetch(league: league, page: 1)
        articlesByLeague[league.id] = articles
        pagesByLeague[league.id] = 1
        exhaustedLeagues.remove(league.id)
    }

    /// Loads the next page of articles, appending to the existing set.
    func loadMore(league: League?) async {
        guard !isLoading && !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let targets: [String]
        if let league {
            guard !exhaustedLeagues.contains(league.id) else { return }
            targets = [league.id]
        } else {
            targets = followedLeagueIDs.filter { !exhaustedLeagues.contains($0) }
            guard !targets.isEmpty else { return }
        }

        let leaguesById = Dictionary(uniqueKeysWithValues: League.all.map { ($0.id, $0) })
        await withTaskGroup(of: (String, [ESPNArticle]).self) { group in
            for id in targets {
                guard let lg = leaguesById[id] else { continue }
                let nextPage = (pagesByLeague[id] ?? 1) + 1
                group.addTask {
                    (id, await self.fetch(league: lg, page: nextPage))
                }
            }
            for await (id, newArticles) in group {
                let nextPage = (pagesByLeague[id] ?? 1) + 1
                if newArticles.isEmpty {
                    exhaustedLeagues.insert(id)
                } else {
                    articlesByLeague[id, default: []].append(contentsOf: newArticles)
                    pagesByLeague[id] = nextPage
                }
            }
        }
    }

    private func fetch(league: League, page: Int) async -> [ESPNArticle] {
        // Only the site feed is league-specific. ESPN's "Now" feed ignores its
        // league parameter and returns global headlines, which made every
        // filter show the same stories under a different tag.
        (try? await service.news(for: league, limit: 50, page: page)) ?? []
    }
}

private struct NewsArticleCard: View {
    let article: ESPNArticle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: article.imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "newspaper.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 86, height: 86)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(article.league.shortName)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Theme.accent)
                        if article.isPremium {
                            Text("ESPN+")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(hex: 0xE0A83D), in: Capsule())
                        }
                        if let type = article.type, !type.isEmpty, type != "Story" {
                            Text(type.uppercased())
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let published = article.published {
                            Text(relativeDate(published))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Text(article.headline)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    if !article.description.isEmpty {
                        Text(article.description)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    if let byline = article.byline, !byline.isEmpty {
                        Text(byline)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
