import SwiftUI

/// Step 42: if no `CFLLivePlayProvider` is wired in (the disclosed default this pass),
/// `game.plays`/`game.drives` are simply empty and this shows the unavailable message —
/// it activates automatically the moment a verified provider starts populating them,
/// with no other code change needed.
struct CFLPlaysView: View {
    let game: CFLGameState
    @State private var expanded = Set<String>()
    var body: some View {
        if game.plays.isEmpty && game.drives.isEmpty {
            ContentUnavailableView("Play-by-play unavailable", systemImage: "american.football",
                description: Text("Detailed play-by-play is currently unavailable."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(game.drives.reversed()) { drive in
                        FootballDriveView(drive: drive, plays: game.plays.filter { $0.driveSequence == drive.sequence },
                            team: [game.home, game.away].first { $0.id == drive.teamID },
                            expanded: Binding(get: { expanded.contains(drive.id) }, set: { if $0 { expanded.insert(drive.id) } else { expanded.remove(drive.id) } }))
                    }
                    let unassigned = game.plays.filter { ($0.driveSequence ?? 0) == 0 }
                    if !unassigned.isEmpty { ForEach(unassigned.reversed()) { FootballPlayRow(play: $0) } }
                }.padding()
            }
        }
    }
}
