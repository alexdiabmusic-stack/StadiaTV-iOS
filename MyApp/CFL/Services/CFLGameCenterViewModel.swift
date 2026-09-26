import Foundation
import Observation

/// Polling is deliberately less aggressive than NFL's: `echo.pims.cfl.ca` exposes only
/// score/status/clock (verified live, no down-by-down state), so polling faster than the
/// data can actually change would just waste requests.
@MainActor @Observable final class CFLGameCenterViewModel {
    private(set) var game: CFLGameState?
    private(set) var error: String?
    private(set) var cached = false
    var tab = "Overview"
    private var generation = UUID()
    private let service: any CFLGameCenterServing
    init(service: any CFLGameCenterServing = CFLGameCenterService()) { self.service = service }
    func run(id: String, date: Date, active: Bool) async {
        let generation = UUID(); self.generation = generation
        if game?.id != id {
            game = nil; error = nil
            let saved = await CFLGameCache.shared.load(id)
            guard self.generation == generation, !Task.isCancelled else { return }
            game = saved; cached = saved != nil
        }
        guard active else { return }
        var failures = 0
        repeat {
            do {
                let details = tab == "Plays"
                let updated = try await service.load(gameID: id, date: date, previous: game, details: details)
                guard self.generation == generation, !Task.isCancelled, updated.id == id else { return }
                game = updated; error = nil; cached = false; failures = 0
                await CFLGameCache.shared.save(updated)
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription; failures += 1
            }
            guard self.generation == generation, !Task.isCancelled else { return }
            if game?.status.polls == false { return }
            let interval: TimeInterval
            switch game?.status {
            case .live: interval = 15
            case .halftime: interval = 30
            case .delayed, .suspended: interval = 45
            default: interval = (game?.start.timeIntervalSinceNow ?? date.timeIntervalSinceNow) > 1800 ? 180 : 45
            }
            do { try await Task.sleep(for: .seconds(max(interval, failures > 0 ? min(300, pow(2, Double(min(failures, 5))) * 10) : 0))) }
            catch { return }
        } while !Task.isCancelled
    }
}
