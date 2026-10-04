#if !os(tvOS)
import SwiftUI

/// The game a deep link points at, identified the way notifications and URLs name it.
struct DeepLinkMatchTarget: Identifiable, Equatable {
    let leagueID: String
    let matchID: String
    /// The game's start, when the link knows it.
    let date: Date?

    var id: String { "\(leagueID)|\(matchID)" }
}

/// Fetches the match a notification or URL refers to and shows its detail screen in a sheet.
struct DeepLinkMatchSheet: View {
    let target: DeepLinkMatchTarget

    @Environment(\.dismiss) private var dismiss

    private enum LoadState {
        case loading
        case loaded(Match)
        case failed
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loaded(let match):
                NavigationStack {
                    MatchDetailView(match: match)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            case .loading:
                placeholder {
                    ProgressView().tint(Theme.accent)
                    Text("Loading game…")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failed:
                placeholder {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Couldn't load this game.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Dismiss") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
        }
        .tint(Theme.accent)
        .task { await load() }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16, content: content)
        }
    }

    /// The day the link names first, then today, then the days around it, which catches a game
    /// that moved or a link without a date.
    private func load() async {
        guard let league = League.all.first(where: { $0.id == target.leagueID }) else {
            state = .failed
            return
        }
        let repository = SportsRepository.shared
        let anchor = target.date ?? Date()

        if let match = await findMatch(in: { try await repository.legacyScoreboard(for: league, on: anchor) }) {
            state = .loaded(match)
            return
        }
        if target.date != nil,
           let match = await findMatch(in: { try await repository.legacyScoreboard(for: league, on: Date()) }) {
            state = .loaded(match)
            return
        }
        let start = Calendar.current.date(byAdding: .day, value: -2, to: anchor) ?? anchor
        if let match = await findMatch(in: { try await repository.legacyScoreboards(for: league, starting: start, days: 5) }) {
            state = .loaded(match)
            return
        }
        state = .failed
    }

    private func findMatch(in fetch: () async throws -> [Match]) async -> Match? {
        (try? await fetch())?.first { $0.id == target.matchID }
    }
}
#endif
