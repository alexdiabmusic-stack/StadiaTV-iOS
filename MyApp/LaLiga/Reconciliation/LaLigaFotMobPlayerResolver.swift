import Foundation

/// Optional player reconciliation (Step 18). Matches an official squad player to
/// a FotMob lineup slot on the *same team* using normalized full name + shirt
/// number — never assumes La Liga's `opta_id` and FotMob's player id share any
/// numbering. Ambiguous matches (more than one candidate, or none) stay
/// unresolved rather than guessed; confirmed matches are cached via
/// `SoccerProviderMappingStore` so the same player is never re-resolved every poll.
nonisolated enum LaLigaFotMobPlayerResolver {
    static func resolve(officialPlayer: SoccerRosterPlayer, fotmobCandidates: [SoccerLineupPlayer]) -> String? {
        let targetName = normalizedName(officialPlayer.reference.fullName)
        let matches = fotmobCandidates.filter { candidate in
            normalizedName(candidate.reference.fullName) == targetName &&
            (officialPlayer.shirtNumber == nil || candidate.shirtNumber == nil || officialPlayer.shirtNumber == candidate.shirtNumber)
        }
        guard matches.count == 1 else { return nil }
        return matches[0].reference.id
    }

    private static func normalizedName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
