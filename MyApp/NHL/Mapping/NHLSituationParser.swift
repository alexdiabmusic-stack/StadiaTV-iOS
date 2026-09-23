import Foundation

nonisolated struct NHLSituationParser: Equatable, Sendable {
    let awayGoalie: Bool
    let awaySkaters: Int
    let homeSkaters: Int
    let homeGoalie: Bool
    init?(_ code: String?) {
        guard let code, code.count == 4 else { return nil }
        let digits = code.compactMap(\.wholeNumberValue)
        guard digits.count == 4, (0...1).contains(digits[0]), (0...1).contains(digits[3]),
              (3...6).contains(digits[1]), (3...6).contains(digits[2]) else { return nil }
        awayGoalie = digits[0] == 1; awaySkaters = digits[1]
        homeSkaters = digits[2]; homeGoalie = digits[3] == 1
    }
    func label(scoringHome: Bool) -> String {
        let own = scoringHome ? homeSkaters : awaySkaters
        let other = scoringHome ? awaySkaters : homeSkaters
        return "\(own)-on-\(other)"
    }
}
