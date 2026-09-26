import SwiftUI

/// Moderate-emphasis compact event (Step 20/23). Uses icon + text label together —
/// never color alone — so it reads correctly under color-blindness/high-contrast.
struct SoccerCardEventView: View {
    let event: SoccerMatchEvent
    let minuteDisplay: String
    let teamAbbr: String
    let directory: [String: SoccerPlayerReference]

    private var cardColor: Color { (event.type == .redCard || event.type == .secondYellow) ? .red : Theme.starting }
    private var cardLabel: String {
        switch event.type {
        case .redCard: return "Red card"
        case .secondYellow: return "Second yellow card"
        default: return "Yellow card"
        }
    }
    private var playerName: String { event.playerID.flatMap { directory[$0]?.fullName } ?? "Unknown player" }

    var body: some View {
        HStack(spacing: 12) {
            Text(minuteDisplay).frame(width: 44, alignment: .trailing).foregroundStyle(Theme.textSecondary).font(.subheadline)
            RoundedRectangle(cornerRadius: 2).fill(cardColor).frame(width: 11, height: 15)
            VStack(alignment: .leading, spacing: 1) {
                SoccerPlayerLink(playerID: event.playerID, directory: directory) { name in
                    Text(name).font(.subheadline).foregroundStyle(Theme.textPrimary)
                }
                Text("\(cardLabel) • \(teamAbbr)").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cardLabel), \(playerName), \(teamAbbr), \(minuteDisplay) minute.")
    }
}
