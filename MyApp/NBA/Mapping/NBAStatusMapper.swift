import Foundation

/// Normalizes NBA's `gameStatus` (1/2/3) + `gameStatusText` into the canonical
/// `BasketballGameStatus`. Text is matched first since it carries states the
/// numeric code can't express (postponed/delayed/suspended/halftime); numeric
/// code is the fallback. Unrecognized text never fails — it falls through to
/// `.unknown` rather than crashing or dropping the game.
nonisolated enum NBAStatusMapper {
    static func status(_ raw: NBAValue, now: Date = Date()) -> BasketballGameStatus {
        let text = (raw["gameStatusText"].string ?? "").lowercased()
        let code = raw["gameStatus"].int
        if text.contains("ppd") || text.contains("postpon") { return .postponed }
        if text.contains("cancel") { return .cancelled }
        if text.contains("suspend") { return .suspended }
        if text.contains("delay") { return .delayed }
        if text.contains("halftime") || text.contains("half time") { return .halftime }
        if text.contains("final") { return .final }
        switch code {
        case 3: return .final
        case 2: return .live
        case 1:
            if let start = NBASeason.parse(raw["gameTimeUTC"].string), start.timeIntervalSince(now) <= 3600 { return .pregame }
            return .scheduled
        default: break
        }
        return text.isEmpty ? .unknown : .scheduled
    }
}
