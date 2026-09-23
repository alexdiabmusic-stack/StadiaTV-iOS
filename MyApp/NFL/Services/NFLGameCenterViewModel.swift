import Foundation
import Observation

@MainActor @Observable final class NFLGameCenterViewModel {
    private(set) var game: NFLGameState?
    private(set) var error: String?
    private(set) var cached = false
    var tab = "Overview"
    private var generation = UUID()
    private let service: any NFLGameCenterServing
    init(service: any NFLGameCenterServing = NFLGameCenterService()) { self.service = service }
    func run(id: String, date: Date, active: Bool) async {
        let generation = UUID(); self.generation = generation
        if game?.id != id {
            game = nil; error = nil
            let saved = await NFLGameCache.shared.load(id)
            guard self.generation == generation, !Task.isCancelled else { return }
            game = saved; cached = saved != nil
        }
        guard active else { return }
        var failures = 0, lastDetails = Date.distantPast
        repeat {
            do {
                let details = game == nil || Date().timeIntervalSince(lastDetails) >= 12
                var updated: NFLGameState
                var detailsFailed = false
                do {
                    updated = try await service.load(gameID: id, date: date, previous: game, details: details)
                } catch {
                    // A rich drive-package failure must not starve lightweight score updates.
                    guard details, game != nil else { throw error }
                    updated = try await service.load(gameID: id, date: date, previous: game, details: false)
                    detailsFailed = true
                }
                if updated.status == .final && (!details || detailsFailed) {
                    updated = try await service.load(gameID: id, date: date, previous: updated, details: true)
                }
                guard self.generation == generation, !Task.isCancelled, updated.id == id else { return }
                game = updated; error = detailsFailed ? "Play-by-play is temporarily unavailable." : nil; cached = false; failures = detailsFailed ? failures + 1 : 0
                if details && !detailsFailed { lastDetails = Date() }
                await NFLGameCache.shared.save(updated)
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription; failures += 1
            }
            guard self.generation == generation, !Task.isCancelled else { return }
            if game?.status.polls == false { return }
            let interval: TimeInterval
            switch game?.status {
            case .live: interval = 6
            case .halftime: interval = 25
            case .delayed, .suspended: interval = 45
            default: interval = (game?.start.timeIntervalSinceNow ?? date.timeIntervalSinceNow) > 1800 ? 180 : 45
            }
            do { try await Task.sleep(for: .seconds(max(interval, failures > 0 ? min(300, pow(2, Double(min(failures, 5))) * 10) : 0))) }
            catch { return }
        } while !Task.isCancelled
    }
}
