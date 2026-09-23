import SwiftUI

struct MLBPlayByPlayView: View {
    let plays: [BaseballAtBat]
    let game: BaseballGame?
    let league: League
    @State private var visible: [BaseballAtBat] = []
    @State private var atLiveEdge = true
    @State private var scoringOnly = false
    @State private var selected: String?
    @FocusState private var focused: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var pending: Int { Set(plays.map(\.id)).subtracting(visible.map(\.id)).count }
    private var filtered: [BaseballAtBat] { (scoringOnly ? visible.filter(\.isScoringPlay) : visible).reversed() }
    private var sectionKeys: [String] { var seen = Set<String>(); return filtered.compactMap { seen.insert($0.inningLabel).inserted ? $0.inningLabel : nil } }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("All plays") { scoringOnly = false }
                Button("Scoring") { scoringOnly = true }
            }.buttonStyle(.bordered).padding(.horizontal)
            if plays.isEmpty {
                ContentUnavailableView("No plays yet", systemImage: "baseball", description: Text("Play-by-play will appear when the game begins."))
            } else {
                HStack(alignment: .top, spacing: 20) {
                    timeline
                    #if os(tvOS)
                    if let play = plays.first(where: { $0.id == (focused ?? selected) }) ?? plays.last {
                        ScrollView { MLBAtBatRow(play: play, game: game, league: league, expandedByDefault: true) }.frame(maxWidth: 520)
                    }
                    #endif
                }
            }
        }
        .onAppear { visible = plays }
        .onChange(of: plays) { _, new in if atLiveEdge { visible = new } }
    }
    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 1).id("live")
                    ForEach(sectionKeys, id: \.self) { key in
                        Section {
                            ForEach(filtered.filter { $0.inningLabel == key }) { play in
                                #if os(tvOS)
                                Button { selected = play.id } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label(play.resultTitle, systemImage: play.isScoringPlay ? "baseball.fill" : "circle")
                                        Text(play.batter?.name ?? "Plate appearance")
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                                }.focused($focused, equals: play.id).id(play.id)
                                #else
                                MLBAtBatRow(play: play, game: game, league: league).id(play.id)
                                #endif
                            }
                        } header: {
                            Text(key.uppercased()).font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .leading).padding().background(Theme.background)
                        }
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < 60
            } action: { _, live in
                atLiveEdge = live
                if live { visible = plays }
            }
            .overlay(alignment: .bottom) {
                if !atLiveEdge {
                    Button {
                        visible = plays
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("live", anchor: .top) }
                    } label: { Label(pending > 0 ? "\(pending) NEW PLAYS" : "JUMP TO LIVE", systemImage: "arrow.up").padding().background(Theme.surfaceElevated, in: Capsule()) }
                    .padding()
                }
            }
        }
    }
}
