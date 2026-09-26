import Foundation

/// Maps the FotMob live ticker (Steps 14, 26) into `[SoccerCommentaryEntry]`. Never
/// guesses the ticker URL when `matchDetails` already supplies one — this payload
/// never has (verified live 2026-09-24: `liveticker.ltcUrl` is always null), so
/// `ltcURL` derives it from the documented pattern
/// (`data.fotmob.com/webcl/ltc/gsm/{fotmobMatchId}_{lang}.json.gz`), gated on a
/// non-empty `langs` list and only attempted when one exists. The lang code
/// embedded in `langs` is NOT the bare `"en"` the docs describe — it's `"en_gen"`
/// (verified live 2026-09-24); the bare code 403s. If FotMob has no ticker file for
/// a match, the fetch itself 403s/404s and the caller degrades to structured
/// events only (Step 26) — this mapper never fabricates a ticker.
nonisolated enum FotMobCommentaryMapper {
    /// `fotmobMatchID` — the FotMob match id, not the official LaLiga one; the
    /// ticker file lives entirely in FotMob's own ID space.
    static func ltcURL(fotmobMatchID: String, matchDetails raw: FotMobValue) -> String? {
        let langs = raw["content"]["liveticker"]["langs"].string?.split(separator: ",").map(String.init) ?? []
        guard let lang = langs.first(where: { $0.hasPrefix("en") }) ?? langs.first else { return nil }
        return "https://data.fotmob.com/webcl/ltc/gsm/\(fotmobMatchID)_\(lang).json.gz"
    }

    static func entries(_ data: Data) -> [SoccerCommentaryEntry]? {
        guard let decompressed = FotMobGZip.decompress(data),
              let value = try? JSONDecoder().decode(FotMobValue.self, from: decompressed) else { return nil }
        return value["Events"].array.compactMap { entry -> SoccerCommentaryEntry? in
            guard let id = entry["MessageId"].string, let text = entry["Description"].string else { return nil }
            let elapsed = entry["Elapsed"].int
            let plus = entry["ElapsedPlus"].int ?? -1
            let minuteDisplay = elapsed.map { plus > 0 ? "\($0)+\(plus)'" : "\($0)'" }
            return SoccerCommentaryEntry(id: id, timestamp: nil, minuteDisplay: minuteDisplay, text: text, rawType: entry["IncidentCode"].string)
        }
    }
}
