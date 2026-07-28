import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @StateObject private var viewModel = NewsViewModel()
    @State private var selectedLeagueID: String?
    @Environment(\.openURL) private var openURL

    private var filterLeagues: [League] {
        let followed = prefs.followedLeagues
        let followedIDs = Set(followed.map(\.id))
        return followed + League.all.filter { !followedIDs.contains($0.id) }
    }

    private var selectedLeague: League? {
        selectedLeagueID.flatMap { id in League.all.first { $0.id == id } }
    }

    private var displayedArticles: [ESPNArticle] {
        viewModel.articles(for: selectedLeague)
    }

    private var isLoadingCurrent: Bool {
        if let league = selectedLeague { return viewModel.isLoadingLeague(league) }
        return viewModel.isLoading
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    leagueFilterBar
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandMark() }
            }
        }
        .tint(Theme.accent)
        .task(id: prefs.followedLeagues.map(\.id).joined()) {
            await viewModel.load(leagues: prefs.followedLeagues)
        }
        .task(id: selectedLeagueID ?? "") {
            if let league = selectedLeague {
                await viewModel.loadIfNeeded(league: league)
            }
        }
    }

    private var leagueFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", isSelected: selectedLeagueID == nil) {
                    withAnimation(.snappy) { selectedLeagueID = nil }
                }
                ForEach(filterLeagues) { league in
                    filterChip(title: league.shortName, isSelected: selectedLeagueID == league.id) {
                        withAnimation(.snappy) { selectedLeagueID = league.id }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
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
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingCurrent && displayedArticles.isEmpty {
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
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "newspaper.fill")
                    Text("NEWS & HIGHLIGHTS")
                        .font(.caption.weight(.heavy))
                    Spacer()
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ForEach(displayedArticles) { article in
                    Button {
                        if let url = article.url { openURL(url) }
                    } label: {
                        DiscoverArticleRow(article: article)
                    }
                    .buttonStyle(.plain)
                    .disabled(article.url == nil)

                    Divider()
                        .padding(.horizontal, 20)
                }
            }
        }
        .refreshable {
            if let league = selectedLeague {
                await viewModel.loadIfNeeded(league: league, force: true)
            } else {
                await viewModel.load(leagues: prefs.followedLeagues)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "newspaper")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
            Text("No news yet.")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Follow leagues in Settings to see the latest headlines here.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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
            Spacer()
        }
    }
}

private struct DiscoverArticleRow: View {
    let article: ESPNArticle

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(article.league.shortName)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    if let type = article.type, !type.isEmpty, type != "Story" {
                        Text("·")
                            .foregroundStyle(Theme.textSecondary)
                        Text(type.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let date = article.published {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Text(article.headline)
                    .font(.system(size: 15, weight: .semibold))
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
            }

            if let imgURL = article.imageURL {
                AsyncImage(url: imgURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Theme.surfaceElevated
                    }
                }
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
