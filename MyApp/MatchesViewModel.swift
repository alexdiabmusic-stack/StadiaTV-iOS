import Foundation
import Combine

@MainActor
final class MatchesViewModel: ObservableObject {
    @Published var selectedLeague: League = League.all[0]
    @Published var matches: [Match] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service = ESPNService()
    private var refreshTask: Task<Void, Never>?

    var liveMatches: [Match] { matches.filter { $0.state == .live } }
    var upcomingMatches: [Match] {
        matches.filter { $0.state == .pre }.sorted { $0.date < $1.date }
    }
    var finishedMatches: [Match] {
        matches.filter { $0.state == .final }.sorted { $0.date > $1.date }
    }

    func load() async {
        isLoading = matches.isEmpty
        errorMessage = nil
        do {
            let result = try await service.scoreboard(for: selectedLeague)
            matches = result
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func selectLeague(_ league: League) {
        guard league != selectedLeague else { return }
        selectedLeague = league
        matches = []
        Task { await load() }
    }

    /// Refreshes live data on an interval while the view is on screen.
    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30s
                guard !Task.isCancelled else { break }
                await self?.load()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
