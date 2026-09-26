import SwiftUI

/// Compact but clear (Step 22): incoming and outgoing players are always distinct
/// slots (`playerID` = on, `secondaryPlayerID` = off) — never mapped to the same player.
struct SoccerSubstitutionEventView: View {
    let event: SoccerMatchEvent
    let minuteDisplay: String
    let teamAbbr: String
    let directory: [String: SoccerPlayerReference]

    var body: some View {
        // Not combined into one accessibility element: the incoming and outgoing
        // players are each an independently-activatable `SoccerPlayerLink`. An
        // overridden combined label reads well but silently strips VoiceOver users'
        // ability to open either profile, so each link keeps its own explicit label
        // instead (Step 69).
        HStack(spacing: 12) {
            Text(minuteDisplay).frame(width: 44, alignment: .trailing).foregroundStyle(Theme.textSecondary).font(.subheadline)
                .accessibilityLabel("\(minuteDisplay) minute")
            Image(systemName: "arrow.left.arrow.right").font(.caption).foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                SoccerPlayerLink(playerID: event.playerID, directory: directory) { name in
                    Text("↑ \(name)").font(.caption).foregroundStyle(Theme.upcoming)
                }.accessibilityLabel("\(nameFor(event.playerID)) coming on")
                SoccerPlayerLink(playerID: event.secondaryPlayerID, directory: directory) { name in
                    Text("↓ \(name)").font(.caption).foregroundStyle(Theme.textSecondary)
                }.accessibilityLabel("\(nameFor(event.secondaryPlayerID)) going off")
            }
            Spacer()
            Text(teamAbbr).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private func nameFor(_ playerID: String?) -> String { playerID.flatMap { directory[$0]?.fullName } ?? "Unknown player" }
}
