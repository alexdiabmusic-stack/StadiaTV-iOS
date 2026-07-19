import SwiftUI
import Combine
import SafariServices

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
            .sheet(item: $presentedArticle) { article in
                if let url = article.url {
                    SafariView(url: url)
                        .ignoresSafeArea()
                }
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
                    .font(.system(size: 44))
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
                            if article.url != nil {
                                presentedArticle = article
                            }
                        }
                    }
                }
                .padding(16)
            }
            .refreshable {
                if let league = selectedLeague {
                    await viewModel.loadIfNeeded(league: league, force: true)
                } else {
                    await viewModel.load(leagues: prefs.followedLeagues)
                }
            }
        }
    }

    private var emptyText: String {
        if let league = selectedLeague {
            return "ESPN did not return news for \(league.name)."
        }
        return "ESPN did not return news for your followed leagues."
    }
}

/// In-app browser so articles never bounce out to Safari.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
final class NewsViewModel: ObservableObject {
    /// Articles cached per league id so filter switches don't refetch.
    @Published private(set) var articlesByLeague: [String: [ESPNArticle]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadingLeagueIDs: Set<String> = []

    private let service = ESPNService()

    func isLoadingLeague(_ league: League) -> Bool {
        loadingLeagueIDs.contains(league.id) || isLoading
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
        return unique
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            .prefix(40)
            .map { $0 }
    }

    func load(leagues: [League]) async {
        isLoading = true
        await withTaskGroup(of: (String, [ESPNArticle]).self) { group in
            for league in leagues {
                group.addTask {
                    (league.id, await self.fetch(league: league))
                }
            }
            for await (id, articles) in group {
                articlesByLeague[id] = articles
            }
        }
        isLoading = false
    }

    /// Fetches a single league on demand (used by filter chips outside the followed set).
    func loadIfNeeded(league: League, force: Bool = false) async {
        if !force, articlesByLeague[league.id]?.isEmpty == false { return }
        guard !loadingLeagueIDs.contains(league.id) else { return }
        loadingLeagueIDs.insert(league.id)
        defer { loadingLeagueIDs.remove(league.id) }
        articlesByLeague[league.id] = await fetch(league: league)
    }

    private func fetch(league: League) async -> [ESPNArticle] {
        // Only the site feed is league-specific. ESPN's "Now" feed ignores its
        // league parameter and returns global headlines, which made every
        // filter show the same stories under a different tag.
        (try? await service.news(for: league, limit: 20)) ?? []
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
