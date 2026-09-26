import Foundation

/// Maps MLS's `match_status` field to canonical `SoccerMatchStatus`. Only
/// `"scheduled"` and `"finalWhistle"` were directly observed live (2026-09-23, one
/// completed regular-season match); every in-play/extra-time/stoppage value below is
/// inferred from MLS's own camelCase naming convention (matching `game_section`'s
/// `"firstHalf"`/`"secondHalf"` from `key_events`) and kept case-insensitive so a
/// close-but-not-identical real value still resolves correctly. Anything genuinely
/// unrecognized decodes to `.unknown(raw)` rather than crashing or being dropped —
/// never inferred from `data_status` (`"postmatch"`/`"live"`), which is a separate
/// freshness marker preserved verbatim on `SoccerMatch.dataStatus`.
nonisolated enum MLSStatusMapper {
    static func status(matchStatus raw: String?) -> SoccerMatchStatus {
        guard let raw, !raw.isEmpty else { return .scheduled }
        switch raw.lowercased() {
        case "scheduled", "prematch": return .scheduled
        case "finalwhistle", "fulltime", "postmatch": return .fullTime
        case "firsthalf": return .firstHalf
        case "halftime", "halftimebreak": return .halftime
        case "secondhalf": return .secondHalf
        case "extrafirsthalf", "firsthalfextra": return .extraFirstHalf
        case "extrahalftime", "halftimeextra": return .extraHalftime
        case "extrasecondhalf", "secondhalfextra": return .extraSecondHalf
        case "penalties", "penaltyshootout", "penalty": return .penalties
        default: break
        }
        let lower = raw.lowercased()
        if lower.contains("postpon") { return .postponed }
        if lower.contains("suspend") { return .suspended }
        if lower.contains("abandon") { return .abandoned }
        if lower.contains("delay") { return .delayed }
        if lower.contains("cancel") { return .cancelled }
        if lower.contains("pre") { return .pregame }
        return .unknown(raw)
    }
}
