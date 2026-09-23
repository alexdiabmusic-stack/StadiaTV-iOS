import SwiftUI

struct NFLPlaysView: View {
    let game: NFLGameState
    @State private var filter = "All"
    @State private var expanded = Set<String>()
    @State private var atLiveEdge = true
    @State private var unseen = 0
    private let filters = ["All", "Scoring", "Turnovers", "Penalties"]
    private func visible(_ play: NFLPlay) -> Bool {
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
                            NFLDriveView(drive: drive, plays: game.plays.filter { $0.driveSequence == drive.sequence && visible($0) },
                                team: [game.home, game.away].first { $0.id == drive.teamID },
                                expanded: Binding(get: { expanded.contains(drive.id) }, set: { if $0 { expanded.insert(drive.id) } else { expanded.remove(drive.id) } }))
                        }
                        let unassigned = game.plays.filter { ($0.driveSequence ?? 0) == 0 && visible($0) }
                        if !unassigned.isEmpty { ForEach(unassigned.reversed()) { NFLPlayRow(play: $0) } }
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
struct NFLDriveView: View {
    let drive: NFLDrive
    let plays: [NFLPlay]
    let team: NFLTeamState?
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("\(team?.abbreviation ?? "") DRIVE").font(.headline); Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    Text([drive.startQuarter.map { $0 > 4 ? "OT \($0 - 4)" : "Q\($0)" }, drive.playCount.map { "\($0) plays" }, drive.yards.map { "\($0) yards" }, drive.timeOfPossession].compactMap { $0 }.joined(separator: " • ")).font(.subheadline)
                    if let result = drive.result { Text(result.uppercased()).font(.subheadline.bold()) }
                    if let start = drive.startField, let end = drive.endField { Text("\(start) → \(end)").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityHint("Show or hide drive plays")
            if expanded { ForEach(plays.reversed()) { NFLPlayRow(play: $0) } }
        }
    }
}
struct NFLPlayRow: View {
    let play: NFLPlay
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: play.scoring ? "american.football.fill" : play.turnover ? "arrow.uturn.backward" : play.penalty ? "flag.fill" : "circle.fill")
                Text(play.type.label.uppercased()).font(.caption.bold()); Spacer(); Text(play.clock ?? "").monospacedDigit()
            }
            if let down = play.down, (1...4).contains(down) {
                Text("\([1: "1st", 2: "2nd", 3: "3rd", 4: "4th"][down] ?? "") & \(play.goalToGo ? "Goal" : play.distance.map(String.init) ?? "–") • \(play.field ?? "")").font(.caption).foregroundStyle(.secondary)
            }
            Text(play.text).font(play.scoring ? .headline : .body).fixedSize(horizontal: false, vertical: true)
            if play.participants.contains(where: { [3, 4, 5].contains($0.rawStatType ?? -1) }) { Text("FIRST DOWN").font(.caption.bold()) }
            if play.turnover { Label("Turnover", systemImage: "arrow.uturn.backward").font(.caption.bold()) }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(play.scoring ? Theme.surfaceElevated : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) { if play.scoring { RoundedRectangle(cornerRadius: 2).fill(Theme.accessibleAccent).frame(width: 3) } }
            .accessibilityElement(children: .combine)
            #if os(tvOS)
            .focusable()
            #endif
    }
}
