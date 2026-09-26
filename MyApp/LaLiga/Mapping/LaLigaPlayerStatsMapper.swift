import Foundation

/// Maps `/api/v1/subscriptions/{slug}/players/stats` rows (Step 9 — ~100 distinct
/// Opta metrics per player as `{name, stat}` pairs, verified live 2026-09-24) into
/// `[StatValue]` for `AthleteOverview`. `LaLigaProvider.playerOverview` only calls
/// this when a player page is actually opened and caches the result — the full
/// league catalogue is never fetched on every Game Centre open (Step 9).
nonisolated enum LaLigaPlayerStatsMapper {
    /// Finds one player's row within a page of the season stats list, joining on
    /// `opta_id` — never the row's own `id`, which is only meaningful within this
    /// endpoint's own numbering (Step 6).
    static func find(_ raw: LaLigaValue, optaID: String) -> LaLigaValue? {
        raw["player_stats"].array.first { $0["opta_id"].string == optaID }
    }

    static func statValues(_ row: LaLigaValue) -> [StatValue] {
        row["stats"].array.compactMap { entry -> StatValue? in
            guard let name = entry["name"].string, let value = entry["stat"].double else { return nil }
            return StatValue(label: name, displayName: humanize(name), value: formatted(value))
        }.sorted { $0.label < $1.label }
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// Stat names are snake_case (`goal_assists`, `shots_on_target_inc_goals`) —
    /// unlike EPL's camelCase Opta keys, so this splits on `_` rather than casing.
    private static func humanize(_ key: String) -> String {
        key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
