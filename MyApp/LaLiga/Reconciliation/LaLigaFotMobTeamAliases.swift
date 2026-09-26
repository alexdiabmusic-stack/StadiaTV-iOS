import Foundation

/// Normalizes La Liga club names for cross-provider matching (Step 17). Official
/// names skew formal ("Futbol Club Barcelona"); FotMob's skew casual and
/// sometimes drop diacritics entirely (verified live 2026-09-24: official
/// "Deportivo Alavés" vs FotMob "Deportivo Alaves"). This strips diacritics,
/// punctuation, and casing, then applies a small explicit alias table for clubs
/// whose names differ structurally, not just cosmetically (Athletic Club ↔
/// Athletic Bilbao). This is only the first-pass signal for
/// `LaLigaFotMobMatchResolver` — once a mapping is confirmed it's cached by
/// `SoccerProviderMappingStore` and this table is never consulted again for that pair.
nonisolated enum LaLigaFotMobTeamAliases {
    private static let aliases: [String: String] = [
        "athletic club": "athletic bilbao",
        "futbol club barcelona": "barcelona",
        "fc barcelona": "barcelona",
        "real madrid club de futbol": "real madrid",
        "club atletico de madrid": "atletico madrid",
        "atletico de madrid": "atletico madrid",
        "real club deportivo espanyol de barcelona": "espanyol",
        "rcd espanyol": "espanyol",
        "real sociedad de futbol": "real sociedad",
        "villarreal club de futbol": "villarreal",
        "real club celta de vigo": "celta vigo",
        "sevilla futbol club": "sevilla",
        "real betis balompie": "real betis",
        "real club deportivo de a coruna": "deportivo",
        "rc deportivo": "deportivo",
        "cadiz club de futbol": "cadiz",
        "rayo vallecano de madrid": "rayo vallecano",
        "getafe club de futbol": "getafe",
        "levante union deportiva": "levante",
        "real club deportivo mallorca": "mallorca",
        "rcd mallorca": "mallorca",
        "girona futbol club": "girona",
        "elche club de futbol": "elche",
        "club atletico osasuna": "osasuna",
        "ca osasuna": "osasuna",
    ]

    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        let cleanedScalars = folded.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        return aliases[collapsed] ?? collapsed
    }
}
