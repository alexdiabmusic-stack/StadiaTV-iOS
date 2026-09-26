import SwiftUI

/// Highest visual emphasis in the Timeline (Step 20-21). Only shows an assist or
/// penalty/own-goal label when the provider's structured fields actually supplied it.
struct SoccerGoalEventView: View {
    let event: SoccerMatchEvent
    let minuteDisplay: String
    let teamAbbr: String
    let directory: [String: SoccerPlayerReference]

    private var kindLabel: String {
        switch event.type {
        case .ownGoal: return "OWN GOAL"
        case .penaltyGoal: return "PENALTY GOAL"
        default: return "GOAL"
        }
    }
    private var assistName: String? { event.secondaryPlayerID.flatMap { directory[$0]?.fullName } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Not combined into one accessibility element: the scorer and assist are
            // each an independently-activatable `SoccerPlayerLink`. Combining would
            // collapse both into a single non-actionable announcement and silently
            // strip VoiceOver users' ability to open either profile (Step 69).
            Text(minuteDisplay).frame(width: 44, alignment: .trailing).foregroundStyle(Theme.textSecondary).font(.subheadline.bold())
                .accessibilityLabel("\(minuteDisplay) minute")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "soccerball").font(.subheadline).foregroundStyle(Theme.upcoming).accessibilityHidden(true)
                    Text("\(kindLabel) • \(teamAbbr)").font(.caption.bold()).foregroundStyle(Theme.textSecondary)
                }
                SoccerPlayerLink(playerID: event.playerID, directory: directory) { name in
                    Text(name).font(.subheadline.bold()).foregroundStyle(Theme.textPrimary)
                }
                if let assistName {
                    SoccerPlayerLink(playerID: event.secondaryPlayerID, directory: directory) { _ in
                        Text("Assist: \(assistName)").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}
