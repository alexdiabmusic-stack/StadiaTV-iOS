import Foundation
import Observation

/// Owns the single polling loop for one match's Soccer Game Centre, for any soccer
/// provider. Adaptive cadence per `SoccerPollingPolicy`: fast while live, slower
/// pregame/halftime, stopped entirely once the match reaches a state that
/// `stopsPolling`. A generation token discards any in-flight response that arrives
/// after the view has moved to a different match — this is the mechanism that
/// prevents a game-switch race from contaminating the wrong match's snapshot.
@MainActor @Observable
final class SoccerGameCentreViewModel {
    private(set) var snapshot: SoccerGameCentreSnapshot?
    private(set) var errors: [String: String] = [:]
    private(set) var showingCache = false
    private(set) var isRefreshing = false
    var selectedTab: SoccerGameTab = .overview
    private let service: any SoccerGameCentreServing
    private let cache: SoccerGameCentreCache
    private let pollingPolicy: SoccerPollingPolicy
    private var generation = UUID()
    private var failures = 0
    private var retryAfter: Date?

    init(service: any SoccerGameCentreServing, cache: SoccerGameCentreCache, pollingPolicy: SoccerPollingPolicy) {
        self.service = service
        self.cache = cache
        self.pollingPolicy = pollingPolicy
    }

    /// True only when every populated error this cycle is a persistent host block —
    /// a Retry button would be futile, so the UI should say so plainly instead.
    var isBlocked: Bool {
        !errors.isEmpty && errors.values.allSatisfy { $0.localizedCaseInsensitiveContains("isn't available on this network") }
    }

    func run(matchID: String, active: Bool, seed: SoccerMatch? = nil, fullRefresh: Bool = true) async {
        let token = UUID(); generation = token; isRefreshing = false
        if snapshot?.matchID != matchID {
            var fresh = SoccerGameCentreSnapshot(matchID: matchID)
            fresh.match = seed
            snapshot = fresh
            errors = [:]; failures = 0; retryAfter = nil
            let cached = await cache.load(matchID)
            guard generation == token, !Task.isCancelled else { return }
            if let cached { snapshot = cached; showingCache = true }
        }
        guard active else { return }
        var full = fullRefresh || snapshot?.match == nil
        var lastFullRefresh = full ? Date.distantPast : Date()
        repeat {
            if let retryAfter, retryAfter > Date() {
                do { try await Task.sleep(for: .seconds(retryAfter.timeIntervalSinceNow)) } catch { return }
            }
            if Date().timeIntervalSince(lastFullRefresh) >= pollingPolicy.fullRefreshInterval { full = true }
            isRefreshing = true
            do {
                guard let old = snapshot else { return }
                // Live polling always fetches the newest commentary page (cursor nil);
                // paging backward through older commentary is handled separately by
                // `loadMoreCommentary()`, which threads the snapshot's own cursor.
                let update = try await service.fetch(matchID: matchID, tab: selectedTab, full: full, lineupsLoaded: old.lineupsLoaded,
                    knownPlayers: old.playerDirectory, commentaryCursor: nil)
                guard generation == token, snapshot?.matchID == matchID, !Task.isCancelled else { return }
                if update.match != nil { lastFullRefresh = Date() }
                let merged = SoccerGameCentreReducer.apply(update, to: old)
                snapshot = merged
                errors = update.errors; retryAfter = update.retryAfter
                showingCache = merged.fetchedAt == old.fetchedAt
                failures = update.errors.isEmpty ? 0 : min(5, failures + 1)
                full = merged.match == nil || (showingCache && update.errors.isEmpty)
                await cache.save(merged)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                errors["overview"] = error.localizedDescription; failures = min(5, failures + 1); showingCache = true; full = true
            }
            guard generation == token, !Task.isCancelled else { return }
            isRefreshing = false
            if snapshot?.match?.status.stopsPolling == true { return }
            do { try await Task.sleep(for: .seconds(pollInterval)) } catch { return }
        } while !Task.isCancelled
    }

    /// Loads an older page of commentary on demand — a one-shot fetch outside the
    /// poll loop, merged into the same snapshot via the same reducer path.
    func loadMoreCommentary() async {
        guard let matchID = snapshot?.matchID, let cursor = snapshot?.commentaryNextCursor, let old = snapshot else { return }
        do {
            let update = try await service.fetch(matchID: matchID, tab: .commentary, full: false, lineupsLoaded: old.lineupsLoaded, knownPlayers: old.playerDirectory, commentaryCursor: cursor)
            guard snapshot?.matchID == matchID else { return }
            snapshot = SoccerGameCentreReducer.apply(update, to: old)
        } catch { errors["commentary"] = error.localizedDescription }
    }

    var pollInterval: TimeInterval {
        pollingPolicy.interval(for: snapshot?.match?.status, kickoff: snapshot?.match?.kickoff, failures: failures)
    }
}
