import SwiftUI

struct NFLPlaysView: View {
    let game: NFLGameState
    @State private var filter = "All"
    @State private var expanded = Set<String>()
    @State private var atLiveEdge = true
    @State private var unseen = 0
    private let filters = ["All", "Scoring", "Turnovers", "Penalties"]
    private func visible(_ play: FootballPlay) -> Bool {
        switch filter { case "Scoring": play.scoring; case "Turnovers": play.turnover; case "Penalties": play.penalty; default: true }
    }
    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack { ForEach(filters, id: \.self) { value in
                    Button(value) { filter = value }.buttonStyle(.bordered).tint(value == filter ? Theme.accessibleAccent : .secondary).frame(minHeight: 44)
                } }.padding(.horizontal)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: 1).id("live").onAppear { atLiveEdge = true; unseen = 0 }.onDisappear { atLiveEdge = false }
                        if game.plays.isEmpty {
                            ContentUnavailableView("No plays yet", systemImage: "american.football", description: Text("Play-by-play will appear when the game begins."))
                        }
                        ForEach(game.drives.reversed()) { drive in
                            FootballDriveView(drive: drive, plays: game.plays.filter { $0.driveSequence == drive.sequence && visible($0) },
                                team: [game.home, game.away].first { $0.id == drive.teamID },
                                expanded: Binding(get: { expanded.contains(drive.id) }, set: { if $0 { expanded.insert(drive.id) } else { expanded.remove(drive.id) } }))
                        }
                        let unassigned = game.plays.filter { ($0.driveSequence ?? 0) == 0 && visible($0) }
                        if !unassigned.isEmpty { ForEach(unassigned.reversed()) { FootballPlayRow(play: $0) } }
                    }.padding()
                }.overlay(alignment: .bottom) {
                    if unseen > 0 { Button("↑ \(unseen) NEW PLAYS") { withAnimation { proxy.scrollTo("live", anchor: .top) }; unseen = 0 }.buttonStyle(.borderedProminent).padding() }
                }
                .onChange(of: game.plays.map(\.id)) { old, new in
                    let added = Set(new).subtracting(old).count
                    if !atLiveEdge { unseen += added }
                }
            }
        }
        .onAppear { if let drive = game.currentDrive { expanded.insert(drive.id) } }
        .onChange(of: game.currentDrive?.id) { _, id in if let id { expanded.insert(id) } }
    }
}
