import Foundation

/// Maps `/v1/matches/{id}/commentary`. Verified live 2026-09-23: the feed returns a
/// duplicate entry per language (English and Spanish observed, same timestamp/type)
/// with no per-entry language tag to filter on — only the pagination cursor embeds a
/// `lang_id`. Deduping on (timestamp, type) collapses those language duplicates while
/// still keeping genuinely distinct moments that happen to share a type. `time` can
/// be a bare space (`" "`) rather than absent, so it's trimmed before being treated
/// as empty.
nonisolated enum EPLCommentaryMapper {
    static func entries(_ raw: EPLValue, matchID: String) -> [SoccerCommentaryEntry] {
        var seenKeys = Set<String>()
        var out: [SoccerCommentaryEntry] = []
        for (index, entry) in raw["data"].array.enumerated() {
            guard let text = entry["comment"].string, !text.isEmpty else { continue }
            let timestampRaw = entry["timestamp"].string
            let type = entry["type"].string
            let dedupeKey = "\(timestampRaw ?? "")|\(type ?? "")"
            guard !seenKeys.contains(dedupeKey) else { continue }
            seenKeys.insert(dedupeKey)
            let minute = entry["time"].string?.trimmingCharacters(in: .whitespaces)
            out.append(SoccerCommentaryEntry(id: "\(matchID)|\(timestampRaw ?? "-")|\(type ?? "-")|\(index)",
                timestamp: EPLDate.parseCommentaryTimestamp(timestampRaw), minuteDisplay: (minute?.isEmpty ?? true) ? nil : minute, text: text, rawType: type))
        }
        return out
    }
}
