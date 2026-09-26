import SwiftUI

/// Centralizes "tap a player in the Game Centre -> open their profile" so every
/// event/lineup row navigates by the provider's real player ID (never a name
/// string) — mirrors `NBAPlayerLink`. Renders as plain text when no ID is known.
struct SoccerPlayerLink<Label: View>: View {
    let playerID: String?
    let directory: [String: SoccerPlayerReference]
    @ViewBuilder let label: (String) -> Label

    private var name: String { playerID.flatMap { directory[$0]?.fullName } ?? "Unknown player" }

    var body: some View {
        if let playerID {
            NavigationLink {
                PlayerDetailView(league: EPLLegacyMapper.league, athlete: EPLLegacyMapper.athlete(id: playerID, name: name))
            } label: { label(name) }
            .buttonStyle(.plain)
        } else {
            label(name)
        }
    }
}
