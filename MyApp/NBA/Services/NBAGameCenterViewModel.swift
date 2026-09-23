import Foundation
import Observation

@MainActor @Observable
final class NBAGameCenterViewModel {
    private(set) var snapshot: BasketballGameSnapshot?
    private(set) var errors: [String: String] = [:]
    private(set) var showingCache = false
    private(set) var isRefreshing = false
    var selectedTab: NBAGameTab = .overview
    private let service: any NBAGameCenterServing
    private let cache: NBAGameCenterCache
    private var generation = UUID()
    private var failures = 0
    private var retryAfter: Date?

    init(service: any NBAGameCenterServing = NBAGameCenterService(), cache: NBAGameCenterCache = .shared) {
        self.service = service; self.cache = cache
    }

    /// True only when every populated error this cycle is a persistent host block —
    /// in that case a Retry button is futile and the UI should say so plainly.
    var isBlocked: Bool {
        !errors.isEmpty && errors.values.allSatisfy { $0.localizedCaseInsensitiveContains("isn't available on this network") }
    }

    // The view's keyed structured task owns and cancels the only polling loop.
    func run(gameID: NBAProviderGameID, active: Bool, seed: BasketballGame? = nil, fullRefresh: Bool = true) async {
        let token = UUID(); generation = token; isRefreshing = false
        if snapshot?.gameID != gameID {
            snapshot = BasketballGameSnapshot(gameID: gameID, game: seed); errors = [:]; failures = 0; retryAfter = nil
            let cached = await cache.load(gameID)
            guard generation == token, !Task.isCancelled else { return }
            if let cached { snapshot = cached; showingCache = true }
        }
        guard active else { return }
        var full = fullRefresh || snapshot?.game == nil
        var lastFullRefresh = full ? Date.distantPast : Date()
        repeat {
            if let retryAfter, retryAfter > Date() {
                do { try await Task.sleep(for: .seconds(retryAfter.timeIntervalSinceNow)) } catch { return }
            }
            if Date().timeIntervalSince(lastFullRefresh) >= 120 { full = true }
            isRefreshing = true
            do {
                let update = try await service.fetch(gameID: gameID, tab: selectedTab, full: full)
                guard generation == token, snapshot?.gameID == gameID, !Task.isCancelled, let old = snapshot else { return }
                if update.boxGame != nil { lastFullRefresh = Date() }
                snapshot = NBAGameCenterReducer.apply(update, to: old)
                errors = update.errors; retryAfter = update.retryAfter
                showingCache = snapshot?.fetchedAt == old.fetchedAt
                failures = update.errors.isEmpty ? 0 : min(5, failures + 1)
                full = snapshot?.game == nil || (showingCache && update.errors.isEmpty)
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

    /// End-of-quarter is detected from the newest play first (the clock can be nil
    /// in some payloads) and falls back to a zero clock second.
    private var isEndOfQuarter: Bool {
        if snapshot?.plays.last?.type == .periodEnd { return true }
        if let clock = snapshot?.game?.gameClock { return clock <= 0 }
        return false
    }

    var pollInterval: TimeInterval {
        let base: TimeInterval
        switch snapshot?.game?.status {
        case .live:
            let period = snapshot?.game?.period ?? 0, regulation = snapshot?.game?.regulationPeriods ?? 4
            let clock = snapshot?.game?.gameClock ?? .infinity
            if isEndOfQuarter { base = 20 }
            else if period >= regulation, clock <= 120 { base = 8 }
            else { base = 12 }
        case .halftime: base = 60
        case .pregame: base = 60
        case .scheduled: base = (snapshot?.game?.start.timeIntervalSinceNow ?? 0) > 3600 ? 300 : 60
        case .delayed, .suspended: base = 30
        default: base = 60
        }
        return max(base, failures > 0 ? min(300, pow(2, Double(failures)) * 10) : 0)
    }
}
