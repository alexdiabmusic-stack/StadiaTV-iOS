import SwiftUI

/// Lineups tab (Steps 24–28). Both teams side-by-side when width allows; a
/// home/away toggle on iPhone. `nil` lineups render "not announced yet" — never an
/// error state, since PulseLive legitimately returns no lineup before kickoff.
struct SoccerLineupsView: View {
    let homeLineup: SoccerLineup?
    let awayLineup: SoccerLineup?
    let wide: Bool
    @State private var selectedSide = 0

    var body: some View {
        if homeLineup == nil && awayLineup == nil {
            ContentUnavailableView("Lineups not yet announced", systemImage: "person.3", description: Text("Lineups have not been announced yet."))
        } else if wide {
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    teamColumn(homeLineup, fallbackName: "Home")
                    teamColumn(awayLineup, fallbackName: "Away")
                }.padding()
            }
        } else {
            VStack(spacing: 0) {
                Picker("Team", selection: $selectedSide) {
                    Text(homeLineup?.team.shortName ?? "Home").tag(0)
                    Text(awayLineup?.team.shortName ?? "Away").tag(1)
                }.pickerStyle(.segmented).padding()
                ScrollView { teamColumn(selectedSide == 0 ? homeLineup : awayLineup, fallbackName: selectedSide == 0 ? "Home" : "Away") }
            }
        }
    }

    @ViewBuilder private func teamColumn(_ lineup: SoccerLineup?, fallbackName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lineup {
                HStack {
                    Text(lineup.team.name).font(.headline)
                    Spacer()
                    if let formation = lineup.formation?.raw { Text(formation).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                }
                SoccerFormationPitchView(lineup: lineup)
                if let manager = lineup.managerName { Text("Manager: \(manager)").font(.caption).foregroundStyle(Theme.textSecondary) }
                Text("SUBSTITUTES").font(.caption.bold()).foregroundStyle(Theme.textSecondary).padding(.top, 8)
                ForEach(lineup.substitutes) { player in
                    SoccerPlayerLink(playerID: player.reference.id, directory: [player.reference.id: player.reference]) { name in
                        HStack {
                            Text(player.shirtNumber ?? "-").frame(width: 28); Text(name); Spacer()
                            if let rating = player.rating { Text(String(format: "%.1f", rating)).font(.caption.bold()).foregroundStyle(Theme.accessibleAccent).accessibilityLabel("FotMob Rating \(String(format: "%.1f", rating))") }
                            if let position = player.position { Text(position).font(.caption).foregroundStyle(Theme.textSecondary) }
                        }
                    }.padding(.vertical, 4)
                }
            } else {
                ContentUnavailableView("\(fallbackName) lineup not announced", systemImage: "person.3")
            }
        }.padding().frame(minWidth: 280, maxWidth: .infinity)
    }
}
