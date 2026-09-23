import SwiftUI

struct NBAPlayByPlayView: View {
    let plays: [NBAPlayEvent]
    let game: BasketballGame?
    @State private var visible: [NBAPlayEvent] = []
    @State private var atLiveEdge = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var regulation: Int { game?.regulationPeriods ?? 4 }
    private var pending: Int { Set(plays.map(\.id)).subtracting(visible.map(\.id)).count }
    private var filtered: [NBAPlayEvent] { visible.reversed() }
    private var sectionKeys: [Int] {
        var seen = Set<Int>()
        return filtered.compactMap { seen.insert($0.period).inserted ? $0.period : nil }
    }
    var body: some View {
        Group {
            if plays.isEmpty {
                ContentUnavailableView("No plays yet", systemImage: "basketball", description: Text("Play-by-play will appear when the game begins."))
            } else {
                timeline
            }
        }
        .onAppear { visible = plays }
        .onChange(of: plays) { _, new in if atLiveEdge { visible = new } }
    }
    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 1).id("live")
                    ForEach(sectionKeys, id: \.self) { period in
                        Section {
                            ForEach(filtered.filter { $0.period == period }) { play in
                                NBAPlayRow(play: play).id(play.id)
                            }
                        } header: {
                            Text(NBADuration.periodLabel(period, regulation: regulation)).font(.subheadline.bold())
                                .frame(maxWidth: .infinity, alignment: .leading).padding().background(Theme.background)
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
