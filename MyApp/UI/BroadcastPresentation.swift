import Foundation

/// Presentation-only cleanup. Source metadata and matching identities remain intact.
enum BroadcastPresentation {
    static func name(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: #"[★☆❖◆◇|]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw : cleaned
    }

    static func category(_ raw: String) -> String {
        let cleaned = name(raw).replacingOccurrences(
            of: #"^(AF|EU|AS|NA|SA|OC)\s+"#, with: "", options: .regularExpression)
        return cleaned == cleaned.uppercased() && cleaned.count > 4
            ? cleaned.localizedCapitalized : cleaned
    }

    static func networks(_ values: [String]) -> String {
        var seen = Set<String>()
        return values.map(name).filter { seen.insert($0.lowercased()).inserted }
            .joined(separator: " · ")
    }

    static func status(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["", "ingame", "in game", "in progress", "live"].contains(value.lowercased()) {
            return String(localized: "Game in progress")
        }
        return value
    }

    static func isHD(_ name: String) -> Bool {
        let tokens = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return !tokens.isDisjoint(with: ["hd", "fhd", "uhd", "4k", "720", "720p", "1080", "1080p", "2160p"])
    }
}
