import Combine
import SwiftUI
import WebKit

// MARK: - ViewModel

@MainActor
final class HighlightsViewModel: ObservableObject {
    @Published var matches: [Match] = []
    @Published var selectedMatch: Match?
    @Published var highlights: [YouTubeVideoItem] = []
    @Published var isLoadingMatches = false
    @Published var isLoadingHighlights = false

    private let espnService = ESPNService()
    private var highlightTask: Task<Void, Never>?

    var supportedMatches: [Match] {
        matches.filter { YouTubeService.supportedLeaguePaths[$0.league.path] != nil }
    }

    func loadMatches(for leagues: [League]) async {
        let supported = leagues.filter { YouTubeService.supportedLeaguePaths[$0.path] != nil }
        guard !supported.isEmpty else {
            matches = []
            selectedMatch = nil
            highlights = []
            return
        }
        isLoadingMatches = true
        let service = espnService
        var all: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in supported.prefix(5) {
                group.addTask { (try? await service.scoreboard(for: league)) ?? [] }
            }
            for await result in group { all += result }
        }
        // Prioritize final > live > pre so recently-finished games appear first
        matches = all.sorted { statePriority($0) < statePriority($1) }
        isLoadingMatches = false
        let current = selectedMatch
        if current == nil || supportedMatches.first(where: { $0.id == current?.id }) == nil {
            if let first = supportedMatches.first { selectMatch(first) }
        }
    }

    func selectMatch(_ match: Match) {
        guard YouTubeService.shared != nil else { return }
        selectedMatch = match
        highlights = []
        highlightTask?.cancel()
        isLoadingHighlights = true
        highlightTask = Task { @MainActor [weak self] in
            guard let self, let service = YouTubeService.shared else {
                self?.isLoadingHighlights = false
                return
            }
            let items = await service.fetchHighlights(for: match)
            guard !Task.isCancelled else { return }
            self.highlights = items
            self.isLoadingHighlights = false
        }
    }

    private func statePriority(_ match: Match) -> Int {
        switch match.state {
        case .final: return 0
        case .live:  return 1
        case .pre:   return 2
        }
    }
}

// MARK: - Section

struct HighlightsSection: View {
    let leagues: [League]
    @StateObject private var viewModel = HighlightsViewModel()
    @State private var playingItem: YouTubeVideoItem?

    var body: some View {
        if YouTubeService.shared != nil {
            sectionContent
                .task(id: supportedLeagueIds) {
                    await viewModel.loadMatches(for: leagues)
                }
                .sheet(item: $playingItem) { item in
                    YouTubePlayerSheet(item: item)
                }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        if viewModel.isLoadingMatches && viewModel.matches.isEmpty {
            highlightsShell {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    .frame(height: 100)
            }
        } else if !viewModel.supportedMatches.isEmpty {
            highlightsShell {
                gamePickerRow
                videoRow
            }
        }
    }

    private func highlightsShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            content()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(Theme.accent)
            Text("HIGHLIGHTS")
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 4)
    }

    private var gamePickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.supportedMatches) { match in
                    MatchChip(match: match, isSelected: viewModel.selectedMatch?.id == match.id)
                        .onTapGesture { viewModel.selectMatch(match) }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private var videoRow: some View {
        if viewModel.isLoadingHighlights {
            HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                .frame(height: 160)
        } else if viewModel.highlights.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.45))
                    Text("No highlights found")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .frame(height: 120)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(viewModel.highlights) { item in
                        HighlightVideoCard(item: item)
                            .onTapGesture { playingItem = item }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var supportedLeagueIds: String {
        leagues
            .filter { YouTubeService.supportedLeaguePaths[$0.path] != nil }
            .map(\.id).sorted().joined(separator: ",")
    }
}

// MARK: - Match Chip

private struct MatchChip: View {
    let match: Match
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(match.shortName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                .lineLimit(1)
            stateLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.accent : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Theme.hairline)
        )
    }

    @ViewBuilder private var stateLabel: some View {
        switch match.state {
        case .live:
            Text("LIVE")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Theme.live)
        case .final, .pre:
            Text(match.statusDetail)
                .font(.caption2)
                .foregroundStyle(isSelected ? .white.opacity(0.72) : Theme.textSecondary)
        }
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
        .frame(width: 180, height: 101)   // 16 : 9
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
