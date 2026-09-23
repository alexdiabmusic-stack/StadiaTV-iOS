import Foundation

nonisolated enum MLBPlayDescriptionBuilder {
    static func humanize(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
    static func title(_ raw: MLBValue) -> String {
        raw["event"].string.map(humanize) ?? raw["eventType"].string.map(humanize) ?? "Plate appearance"
    }
    static func description(_ raw: MLBValue, batter: BaseballPlayerReference?) -> String {
        raw["description"].string ?? [batter?.name, title(raw)].compactMap { $0 }.joined(separator: " · ")
    }
}
