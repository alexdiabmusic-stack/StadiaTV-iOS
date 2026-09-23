import Foundation
import Observation

@MainActor @Observable
final class NHLGameCenterViewModel {
    private(set) var snapshot: HockeyGameCenterSnapshot?
    private(set) var errors: [String: String] = [:]
    private(set) var isRefreshing = false
    private(set) var showingCache = false
    var selectedTab: NHLGameTab = .overview
    private let service: any NHLGameCenterServing
    private let cache: NHLGameCenterCache
    private var generation = UUID()
    private var retryAfter: Date?
    private var failureCount = 0
    init(service: any NHLGameCenterServing = NHLGameCenterService(), cache: NHLGameCenterCache = .shared) {
        self.service = service; self.cache = cache
    }
    func run(gameID: Int, active: Bool) async {
        let token = UUID()
        generation = token
        isRefreshing = false
        if snapshot?.gameID != gameID {
            snapshot = nil; errors = [:]; failureCount = 0; retryAfter = nil
            let cached = await cache.load(gameID)
            guard token == generation, !Task.isCancelled else { return }
            snapshot = cached ?? HockeyGameCenterSnapshot(gameID: gameID)
            showingCache = cached != nil
        }
        guard active else { isRefreshing = false; return }
        repeat {
            await refresh(gameID: gameID, token: token)
            guard token == generation, !Task.isCancelled else { return }
            if snapshot?.game?.status == .final { return }
            let delay = max(pollInterval, retryAfter?.timeIntervalSinceNow ?? 0)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        } while !Task.isCancelled
    }
    func retry() async {
        guard let id = snapshot?.gameID else { return }
        await refresh(gameID: id, token: generation)
    }
    private func refresh(gameID: Int, token: UUID) async {
        guard !isRefreshing, retryAfter.map({ $0 > Date() }) != true else { return }
        isRefreshing = true
        defer { if token == generation { isRefreshing = false } }
        do {
            let update = try await service.fetch(gameID: gameID)
            guard token == generation, snapshot?.gameID == gameID, !Task.isCancelled else { return }
            guard let old = snapshot else { return }
            snapshot = NHLGameCenterReducer.apply(update, to: old)
            errors = update.errors; retryAfter = update.retryAfter
            failureCount = update.errors.isEmpty ? 0 : min(4, failureCount + 1)
            showingCache = snapshot?.game != nil && snapshot?.fetchedAt == old.fetchedAt
            if let snapshot { await cache.save(snapshot) }
        } catch is CancellationError { }
        catch {
            guard token == generation, snapshot?.gameID == gameID, !Task.isCancelled else { return }
            errors["plays"] = error.localizedDescription; failureCount = min(4, failureCount + 1)
            showingCache = snapshot?.game != nil
        }
    }
    var pollInterval: TimeInterval {
        let base: TimeInterval
        if snapshot?.game?.status == .live {
            base = snapshot?.game?.intermission == true ? 30 : selectedTab == .plays ? 10 : 18
        } else { base = 90 }
        return max(base, failureCount > 0 ? min(120, pow(2, Double(failureCount)) * 5) : 0)
    }
}
nonisolated enum NHLGameTab: String, CaseIterable, Identifiable {
    case overview = "Overview", plays = "Play-by-Play", boxscore = "Box Score", stats = "Stats"
    var id: String { rawValue }
}
