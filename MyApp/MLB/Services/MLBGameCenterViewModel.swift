import Foundation
import Observation

@MainActor @Observable
final class MLBGameCenterViewModel {
    private(set) var snapshot: BaseballGameSnapshot?
    private(set) var errors: [String: String] = [:]
    private(set) var showingCache = false
    private(set) var isRefreshing = false
    var selectedTab: MLBGameTab = .overview
    private let service: any MLBGameCenterServing
    private let cache: MLBGameCenterCache
    private var generation = UUID()
    private var failures = 0
    private var retryAfter: Date?
    init(service: any MLBGameCenterServing = MLBGameCenterService(), cache: MLBGameCenterCache = .shared) {
        self.service = service; self.cache = cache
    }
    // The view's keyed structured task owns and cancels the only polling loop.
    func run(gamePk: Int, active: Bool, seed: BaseballGame? = nil, fullRefresh: Bool = true) async {
        let token = UUID(); generation = token; isRefreshing = false
        if snapshot?.gamePk != gamePk {
            snapshot = BaseballGameSnapshot(gamePk: gamePk, game: seed); errors = [:]; failures = 0; retryAfter = nil
            let cached = await cache.load(gamePk)
            guard generation == token, !Task.isCancelled else { return }
            if let cached { snapshot = cached; showingCache = true }
        }
        guard active else { return }
        var full = fullRefresh || snapshot?.game == nil
        var content = snapshot?.highlights.isEmpty ?? true
        var lastFullRefresh = full ? Date.distantPast : Date()
        repeat {
            if let retryAfter, retryAfter > Date() {
                do { try await Task.sleep(for: .seconds(retryAfter.timeIntervalSinceNow)) } catch { return }
            }
            if Date().timeIntervalSince(lastFullRefresh) >= 120 { full = true }
            isRefreshing = true
            do {
                let update = try await service.fetch(gamePk: gamePk, tab: selectedTab, full: full, includeContent: content && selectedTab == .overview)
                guard generation == token, snapshot?.gamePk == gamePk, !Task.isCancelled, let old = snapshot else { return }
                if update.feed != nil { lastFullRefresh = Date() }
                snapshot = MLBGameCenterReducer.apply(update, to: old)
                errors = update.errors; retryAfter = update.retryAfter
                showingCache = snapshot?.fetchedAt == old.fetchedAt
                failures = update.errors.isEmpty ? 0 : min(5, failures + 1)
                full = snapshot?.game == nil || (showingCache && update.errors.isEmpty)
                content = false
                if let snapshot { await cache.save(snapshot) }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                errors["overview"] = error.localizedDescription; failures = min(5, failures + 1); showingCache = true; full = true
            }
            guard generation == token, !Task.isCancelled else { return }
            isRefreshing = false
            if snapshot?.game?.status.stopsPolling == true { return }
            do { try await Task.sleep(for: .seconds(pollInterval)) } catch { return }
        } while !Task.isCancelled
    }
    var pollInterval: TimeInterval {
        let base: TimeInterval
        switch snapshot?.game?.status {
        case .live: base = snapshot?.line?.betweenInnings == true ? 25 : 10
        case .warmup: base = 25
        case .delayed, .suspended: base = 30
        case .scheduled, .pregame: base = (snapshot?.game?.start.timeIntervalSinceNow ?? 0) > 3600 ? 300 : 60
        default: base = 60
        }
        return max(base, failures > 0 ? min(300, pow(2, Double(failures)) * 10) : 0)
    }
}
