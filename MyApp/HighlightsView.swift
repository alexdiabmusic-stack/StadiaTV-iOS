import Combine
import SwiftUI
import WebKit

// MARK: - Recent Sports Highlights

@MainActor
final class RecentSportsHighlightsViewModel: ObservableObject {
    @Published var clips: [MatchHighlight] = []
    @Published var isLoading = false

    func load(leagues: [League]) async {
        let limitedLeagues = Array(leagues.prefix(8))
        guard !limitedLeagues.isEmpty else {
            clips = []
            return
        }

        isLoading = true
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var finishedMatches: [Match] = []

        await withTaskGroup(of: [Match].self) { group in
            for league in limitedLeagues {
                group.addTask {
                    let matches = (try? await SportsRepository.shared.legacyScoreboards(for: league, starting: startDate, days: 8)) ?? []
                    return matches.filter { $0.state == .final }
                }
            }

            for await matches in group {
                finishedMatches.append(contentsOf: matches)
            }
        }

        let recentMatches = finishedMatches
            .sorted { $0.date > $1.date }
            .prefix(10)

        var loadedClips: [MatchHighlight] = []
        await withTaskGroup(of: [MatchHighlight].self) { group in
            for match in recentMatches {
                group.addTask {
                    (try? await SportsRepository.shared.legacyGameSummary(for: match))?.highlights ?? []
                }
            }

            for await matchClips in group {
                loadedClips.append(contentsOf: matchClips)
            }
        }

        var seen = Set<String>()
        clips = loadedClips.filter { clip in
            seen.insert(clip.id).inserted
        }
        .prefix(12)
        .map { $0 }
        isLoading = false
    }
}

struct RecentSportsHighlightsSection: View {
    let leagues: [League]
    @StateObject private var viewModel = RecentSportsHighlightsViewModel()

    var body: some View {
        sectionContent
            .task(id: leagueCacheKey) {
                await viewModel.load(leagues: leagues)
            }
    }

    @ViewBuilder private var sectionContent: some View {
        if viewModel.isLoading && viewModel.clips.isEmpty {
            highlightsShell {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    .frame(height: 150)
            }
        } else if !viewModel.clips.isEmpty {
            highlightsShell { clipRow }
        }
    }

    private func highlightsShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text("SPORTS HIGHLIGHTS")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("RECENT")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 4)

            content()
        }
    }

    private var clipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(viewModel.clips) { clip in
                    HighlightCard(clip: clip)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var leagueCacheKey: String {
        leagues.map(\.id).sorted().joined(separator: ",")
    }
}

// MARK: - Top Highlights

@MainActor
final class TopHighlightsViewModel: ObservableObject {
    @Published var items: [YouTubeVideoItem] = []
    @Published var isLoading = false

    func load(leagues: [League]) async {
        guard let service = YouTubeService.shared else { return }
        let keys = leagues.compactMap { YouTubeService.supportedLeaguePaths[$0.path] }
        guard !keys.isEmpty else { items = []; return }
        isLoading = true
        var all: [YouTubeVideoItem] = []
        await withTaskGroup(of: [YouTubeVideoItem].self) { group in
            for key in keys {
                group.addTask { await service.fetchLatestHighlights(leagueKey: key) }
            }
            for await result in group { all += result }
        }
        items = all.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        isLoading = false
    }
}

struct TopHighlightsSection: View {
    let leagues: [League]
    @StateObject private var viewModel = TopHighlightsViewModel()
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var playingItem: YouTubeVideoItem?
    @State private var showPaywall = false

    var body: some View {
        if YouTubeService.shared != nil {
            sectionContent
                .task(id: supportedLeagueKeys) {
                    await viewModel.load(leagues: leagues)
                }
                .sheet(item: $playingItem) { item in
                    YouTubePlayerSheet(item: item)
                }
                .sheet(isPresented: $showPaywall) {
                    PaywallView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            highlightsShell {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    .frame(height: 160)
            }
        } else if !viewModel.items.isEmpty {
            highlightsShell { videoRow }
        }
    }

    private func highlightsShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
                Text("TOP HIGHLIGHTS").foregroundStyle(Theme.textSecondary)
                Spacer()
                if !entitlements.isPremium {
                    HStack(spacing: 4) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: 0xFFCC00))
                        Text("VIP")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: 0xFFCC00))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(hex: 0xFFCC00).opacity(0.15), in: Capsule())
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 4)
            content()
        }
    }

    private var videoRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(viewModel.items) { item in
                    lockedCard(item: item)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func lockedCard(item: YouTubeVideoItem) -> some View {
        ZStack(alignment: .top) {
            HighlightVideoCard(item: item)
                .blur(radius: entitlements.isPremium ? 0 : 3)
                .saturation(entitlements.isPremium ? 1 : 0.35)

            if !entitlements.isPremium {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.55))
                    .frame(width: 180, height: 101)
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xFFCC00))
                            Text("VIP ONLY")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.white)
                                .tracking(0.5)
                        }
                    }
            }
        }
        .onTapGesture {
            if entitlements.isPremium {
                playingItem = item
            } else {
                showPaywall = true
            }
        }
    }

    private var supportedLeagueKeys: String {
        leagues.compactMap { YouTubeService.supportedLeaguePaths[$0.path] }.sorted().joined(separator: ",")
    }
}

// MARK: - Team Highlights

@MainActor
final class TeamHighlightsViewModel: ObservableObject {
    @Published var items: [YouTubeVideoItem] = []
    @Published var isLoading = false

    func load(teams: [FavoriteTeam]) async {
        guard let service = YouTubeService.shared else { return }
        let pairs = teams.compactMap { team -> (String, String)? in
            guard let leagueKey = YouTubeService.supportedLeaguePaths[team.leaguePath] else { return nil }
            return (team.abbreviation.lowercased(), leagueKey)
        }
        guard !pairs.isEmpty else { items = []; return }
        isLoading = true
        var all: [YouTubeVideoItem] = []
        await withTaskGroup(of: [YouTubeVideoItem].self) { group in
            for (teamKey, leagueKey) in pairs {
                group.addTask { await service.fetchHighlights(teamKey: teamKey, leagueKey: leagueKey) }
            }
            for await result in group { all += result }
        }
        items = all.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        isLoading = false
    }
}

struct TeamHighlightsSection: View {
    let favoriteTeams: [FavoriteTeam]
    @StateObject private var viewModel = TeamHighlightsViewModel()
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var playingItem: YouTubeVideoItem?
    @State private var showPaywall = false

    private var supportedTeams: [FavoriteTeam] {
        favoriteTeams.filter { YouTubeService.supportedLeaguePaths[$0.leaguePath] != nil }
    }

    var body: some View {
        if YouTubeService.shared != nil && !supportedTeams.isEmpty {
            sectionContent
                .task(id: teamCacheKey) {
                    await viewModel.load(teams: supportedTeams)
                }
                .sheet(item: $playingItem) { item in
                    YouTubePlayerSheet(item: item)
                }
                .sheet(isPresented: $showPaywall) {
                    PaywallView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            highlightsShell {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    .frame(height: 160)
            }
        } else if !viewModel.items.isEmpty {
            highlightsShell { videoRow }
        }
    }

    private func highlightsShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill").foregroundStyle(Theme.accent)
                Text("YOUR TEAM HIGHLIGHTS").foregroundStyle(Theme.textSecondary)
                Spacer()
                if !entitlements.isPremium {
                    HStack(spacing: 4) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: 0xFFCC00))
                        Text("VIP")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: 0xFFCC00))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(hex: 0xFFCC00).opacity(0.15), in: Capsule())
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 4)
            content()
        }
    }

    private var videoRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(viewModel.items) { item in
                    lockedCard(item: item)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func lockedCard(item: YouTubeVideoItem) -> some View {
        ZStack(alignment: .top) {
            HighlightVideoCard(item: item)
                .blur(radius: entitlements.isPremium ? 0 : 3)
                .saturation(entitlements.isPremium ? 1 : 0.35)

            if !entitlements.isPremium {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.55))
                    .frame(width: 180, height: 101)
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xFFCC00))
                            Text("VIP ONLY")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.white)
                                .tracking(0.5)
                        }
                    }
            }
        }
        .onTapGesture {
            if entitlements.isPremium {
                playingItem = item
            } else {
                showPaywall = true
            }
        }
    }

    private var teamCacheKey: String {
        supportedTeams.map { "\($0.leaguePath)-\($0.abbreviation)" }.sorted().joined(separator: ",")
    }
}

// MARK: - Video Card

private struct HighlightVideoCard: View {
    let item: YouTubeVideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                sourceBadge
            }
        }
        .frame(width: 180)
    }

    private var thumbnailView: some View {
        AsyncImage(url: item.thumbnailURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Theme.surfaceElevated.overlay {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.5))
                }
            }
        }
        .frame(width: 180, height: 101)   // 16:9
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(6)
        }
    }

    private var sourceBadge: some View {
        Text(item.source.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(sourceColor.opacity(0.15), in: Capsule())
    }

    private var sourceColor: Color {
        switch item.source {
        case .league: Theme.accent
        case .home:   .blue
        case .away:   .green
        case .team:   .orange
        }
    }
}

// MARK: - Player Sheet

struct YouTubePlayerSheet: View {
    let item: YouTubeVideoItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            YouTubeEmbedView(videoId: item.videoId)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Embedded player

struct YouTubeEmbedView: UIViewRepresentable {
    let videoId: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        let url = URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
