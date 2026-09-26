import Foundation

/// Maps `/matches/{id}/commentary` into `SoccerCommentaryEntry`. MLS supplies a real
/// per-entry `event_id` (unlike PulseLive) plus a `version` counter that increments
/// when an entry is corrected — the shared reducer's identity-based replace-in-place
/// merge already handles that correctly with no extra field needed, since a later
/// poll's entry for the same id simply overwrites the earlier one.
nonisolated enum MLSCommentaryMapper {
    static func entries(_ raw: MLSValue, matchID: String) -> [SoccerCommentaryEntry] {
        raw["commentary"].array.compactMap { entry -> SoccerCommentaryEntry? in
            guard let eventID = entry["event_id"].string else { return nil }
            let text = entry["commentary"].string ?? ""
            guard !text.isEmpty else { return nil }
            let minute = entry["minute_of_play"].string?.trimmingCharacters(in: .whitespaces)
            return SoccerCommentaryEntry(id: "\(matchID)|\(eventID)", timestamp: MLSDate.parseISO8601(entry["event_time"].string),
                minuteDisplay: (minute?.isEmpty ?? true) ? nil : minute, text: text, rawType: entry["type"].string)
        }
    }
}
