import SwiftUI
import Combine

struct SearchView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel = SearchViewModel()
    @State private var query = ""
    @State private var playingChannel: Channel?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchResults: [Match] {
        guard !trimmedQuery.isEmpty else { return [] }
        return viewModel.matches.filter { match in
            [match.name, match.shortName, match.league.name, match.home.displayName, match.away.displayName, match.broadcasts.joined(separator: " ")]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var channelResults: [Channel] {
        guard !trimmedQuery.isEmpty else { return [] }
        return playlists.allChannels.filter { channel in
            [channel.name, channel.group ?? "", channel.playlistName]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var articleResults: [ESPNArticle] {
        guard !trimmedQuery.isEmpty else { return [] }
        return viewModel.articles.filter { article in
            [article.headline, article.description, article.league.name]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Search")
            .navigationDestination(for: Match.self) { match in
                MatchDetailView(match: match)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Teams, leagues, channels, news")
            .sheet(item: $playingChannel) { channel in
                PlayerView(channel: channel)
            }
        }
        .tint(Theme.accent)
        .task(id: prefs.followedLeagues.map(\.id).joined(separator: ",")) {
            await viewModel.load(leagues: prefs.followedLeagues)
        }
    }

    @ViewBuilder private var content: some View {
        if trimmedQuery.isEmpty {
            idleState
        } else if matchResults.isEmpty && channelResults.isEmpty && articleResults.isEmpty {
            emptyState
        } else {
            resultsList
        }
    }

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(Theme.accent)
            Text("Search matches, channels, and ESPN news")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            FlowLayout(spacing: 8) {
                ForEach(["NBA", "NFL", "Premier League", "ESPN", "UFC"], id: \.self) { suggestion in
                    Button(suggestion) { query = suggestion }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(Theme.textSecondary)
            Text("No results for \"\(trimmedQuery)\"")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !matchResults.isEmpty {
                    SearchSectionTitle(title: "Matches", count: matchResults.count)
                    ForEach(matchResults.prefix(8)) { match in
                        NavigationLink(value: match) { MatchRow(match: match) }
                            .buttonStyle(.plain)
                    }
                }

                if !channelResults.isEmpty {
                    SearchSectionTitle(title: "Channels", count: channelResults.count)
                    ForEach(channelResults.prefix(12)) { channel in
                        ChannelListRow(channel: channel) { playingChannel = channel }
                    }
                }

                if !articleResults.isEmpty {
                    SearchSectionTitle(title: "News", count: articleResults.count)
                    ForEach(articleResults.prefix(10)) { article in
                        SearchArticleRow(article: article) {
                            if let url = article.url { openURL(url) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var matches: [Match] = []
    @Published private(set) var articles: [ESPNArticle] = []

    private let service = ESPNService()

    func load(leagues: [League]) async {
        var loadedMatches: [Match] = []
        var loadedArticles: [ESPNArticle] = []

        await withTaskGroup(of: SearchLoadResult.self) { group in
            for league in leagues {
                group.addTask {
                    async let matches = self.service.scoreboards(for: league, starting: Date(), days: 7)
                    async let articles = self.service.news(for: league, limit: 6)
                    return SearchLoadResult(
                        matches: (try? await matches) ?? [],
                        articles: (try? await articles) ?? []
                    )
                }
            }
            for await result in group {
                loadedMatches.append(contentsOf: result.matches)
                loadedArticles.append(contentsOf: result.articles)
            }
        }

        matches = Dictionary(grouping: loadedMatches, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.date < $1.date }
        articles = Dictionary(grouping: loadedArticles, by: \.id)
            .compactMap { $0.value.first }
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
    }
}

private struct SearchLoadResult {
    let matches: [Match]
    let articles: [ESPNArticle]
}

private struct SearchSectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.footnote.weight(.bold))
        .foregroundStyle(Theme.textSecondary)
    }
}

private struct SearchArticleRow: View {
    let article: ESPNArticle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "newspaper.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(article.league.name)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}
