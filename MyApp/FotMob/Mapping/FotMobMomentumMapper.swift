import Foundation

/// Maps `content.momentum.main.data` into `[SoccerMomentumSample]` (Step 25).
/// Verified live 2026-09-24. Never labelled as a win-probability model in the UI —
/// just FotMob's own relative attacking-pressure value per minute.
nonisolated enum FotMobMomentumMapper {
    static func samples(_ raw: FotMobValue) -> [SoccerMomentumSample] {
        raw["content"]["momentum"]["main"]["data"].array.compactMap { entry -> SoccerMomentumSample? in
            guard let minute = entry["minute"].int, let value = entry["value"].double else { return nil }
            return SoccerMomentumSample(minute: minute, value: value)
        }
    }
}
