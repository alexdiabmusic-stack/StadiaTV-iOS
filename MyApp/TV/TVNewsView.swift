#if os(tvOS)
import SwiftUI

struct TVNewsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @StateObject private var viewModel = NewsViewModel()
    @State private var selectedLeagueID: String?
    @State private var selectedArticle: ESPNArticle?

    private var filterLeagues: [League] {
        let followed = prefs.followedLeagues
        let ids = Set(followed.map(\.id))
        return followed + League.all.filter { !ids.contains($0.id) }
    }

    private var selectedLeague: League? {
        selectedLeagueID.flatMap { id in League.all.first { $0.id == id } }
    }

    private var displayedArticles: [ESPNArticle] {
        viewModel.articles(for: selectedLeague)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterChips
                    Divider().background(Theme.hairline)
                    content
                }
            }
            .navigationTitle("News")
            .navigationDestination(for: ESPNArticle.self) { article in
                TVArticleDetailView(article: article)
            }
        }
        .tint(Theme.accent)
        .task(id: prefs.followedLeagues.map(\.id).joined()) {
            await viewModel.load(leagues: prefs.followedLeagues)
        }
        .task(id: selectedLeagueID) {
            if let league = selectedLeague { await viewModel.loadIfNeeded(league: league) }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                filterChip(title: "All", id: nil)
                ForEach(filterLeagues) { league in
                    filterChip(title: league.shortName, id: league.id)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 14)
        }
    }

    private func filterChip(title: String, id: String?) -> some View {
        let selected = selectedLeagueID == id
        return Button { selectedLeagueID = id } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(selected ? .white : Theme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(selected ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        let isLoadingSelection = selectedLeague.map { viewModel.isLoadingLeague($0) } ?? viewModel.isLoading
        if isLoadingSelection && displayedArticles.isEmpty {
            ProgressView().tint(Theme.accent).scaleEffect(2).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedArticles.isEmpty {
            TVEmptyState(systemImage: "newspaper", title: "No Articles", subtitle: "No news found for this selection.")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360, maximum: 420), spacing: 24)],
                    spacing: 24
                ) {
                    ForEach(displayedArticles) { article in
                        NavigationLink(value: article) {
                            TVArticleCard(article: article, width: 380)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
            }
        }
    }
}

// MARK: - Article Detail View

private struct TVArticleDetailView: View {
    let article: ESPNArticle

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let url = article.imageURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 480)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Text(article.league.name.uppercased())
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Theme.accent)

                    Text(article.headline)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)

                    if !article.description.isEmpty {
                        Text(article.description)
                            .font(.title3)
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(6)
                    }

                    if let byline = article.byline, !byline.isEmpty {
                        Text(byline)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    }

                    if let date = article.published {
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Text("Open ESPN on your iPhone or iPad for the full story.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(60)
            }
        }
        .navigationTitle(article.league.shortName)
    }
}

extension ESPNArticle: Hashable {
    public static func == (lhs: ESPNArticle, rhs: ESPNArticle) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
#endif
