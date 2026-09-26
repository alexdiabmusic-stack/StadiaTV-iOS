import SwiftUI

/// Dispatches to the right visual weight for each event type (Step 20). Routine/
/// unrecognized event types render as a plain compact row rather than being dropped,
/// so an unmapped future provider value never disappears silently.
struct SoccerEventRow: View {
    let event: SoccerMatchEvent
    let match: SoccerMatch?
    let directory: [String: SoccerPlayerReference]

    private var teamAbbr: String { match?.side(for: event.teamID)?.team.abbreviation ?? "" }

    // Case-insensitive: EPL's raw period marker is PascalCase ("FirstHalf"); MLS's
    // is camelCase ("firstHalf") — both mean the same thing, so this compares
    // loosely rather than assuming one provider's exact casing convention.
    private var minuteDisplay: String {
        guard let minute = event.minute else { return "" }
        if event.period?.caseInsensitiveCompare("FirstHalf") == .orderedSame, minute > 45 { return "45+\(minute - 45)'" }
        if event.period?.caseInsensitiveCompare("SecondHalf") == .orderedSame, minute > 90 { return "90+\(minute - 90)'" }
        return "\(minute)'"
    }

    var body: some View {
        switch event.type {
        case .goal, .ownGoal, .penaltyGoal:
            SoccerGoalEventView(event: event, minuteDisplay: minuteDisplay, teamAbbr: teamAbbr, directory: directory)
        case .yellowCard, .secondYellow, .redCard:
            SoccerCardEventView(event: event, minuteDisplay: minuteDisplay, teamAbbr: teamAbbr, directory: directory)
        case .substitution:
            SoccerSubstitutionEventView(event: event, minuteDisplay: minuteDisplay, teamAbbr: teamAbbr, directory: directory)
        case .missedPenalty, .varEvent, .periodStart, .halftime, .periodEnd, .unknown,
             .shotSaved, .shotBlocked, .shotOffTarget, .woodwork, .corner, .offside, .foul, .penaltyWon, .penaltySaved:
            genericRow
        }
    }

    private var genericRow: some View {
        HStack {
            Text(minuteDisplay).frame(width: 44, alignment: .trailing).foregroundStyle(Theme.textSecondary)
            Text(label).font(.subheadline)
            Spacer()
            Text(teamAbbr).foregroundStyle(Theme.textSecondary)
        }.padding(.horizontal).padding(.vertical, 8)
        // No interactive children here, so combining is safe and reads as one coherent phrase.
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch event.type {
        case .missedPenalty: return "Missed penalty"
        case .varEvent: return "VAR review"
        case .periodStart: return "Period start"
        case .halftime: return "Half time"
        case .periodEnd: return "Period end"
        case .shotSaved: return "Shot saved"
        case .shotBlocked: return "Shot blocked"
        case .shotOffTarget: return "Shot off target"
        case .woodwork: return "Hit the woodwork"
        case .corner: return "Corner"
        case .offside: return "Offside"
        case .foul: return "Foul"
        case .penaltyWon: return "Penalty won"
        case .penaltySaved: return "Penalty saved"
        case .unknown(let raw): return raw
        default: return ""
        }
    }
}
