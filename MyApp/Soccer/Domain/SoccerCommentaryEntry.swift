import Foundation

/// One live-text commentary entry. `id` is synthesized (the provider supplies no
/// entry ID) and `minuteDisplay` is the provider's raw, sometimes-blank minute label
/// — never reformatted into a guessed match-clock value.
nonisolated struct SoccerCommentaryEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let timestamp: Date?
    let minuteDisplay: String?
    let text: String
    let rawType: String?
}
