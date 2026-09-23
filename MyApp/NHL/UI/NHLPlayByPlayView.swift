import SwiftUI

private enum HockeyPlayFilter: String, CaseIterable, Identifiable {
    case all = "All", goals = "Goals", penalties = "Penalties", shots = "Shots", hits = "Hits"
    var id: String { rawValue }
    func includes(_ event: HockeyPlayEvent) -> Bool {
        switch self {
        case .all: return true
        case .goals: return event.eventType == .goal
        case .penalties: return event.eventType == .penalty || event.eventType == .delayedPenalty
        case .shots: return event.eventType.isShot
        case .hits: return event.eventType == .hit
        }
    }
}
private struct HockeyTimelinePeriod: Identifiable {
    let period: HockeyPeriod
    let events: [HockeyPlayEvent]
    var id: String { "\(period.number):\(period.kind.rawValue)" }
}
struct NHLPlayByPlayView: View {
    let events: [HockeyPlayEvent]
    let game: HockeyGame?
    let league: League
    @State private var filter: HockeyPlayFilter = .all
    @State private var atLiveEdge = true
    @State private var deferredIDs: Set<String> = []
    @State private var displayedEvents: [HockeyPlayEvent] = []
    @State private var selectedEventID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var periods: [HockeyTimelinePeriod] {
        let filtered = displayedEvents.filter { filter.includes($0) }
        let groups = Dictionary(grouping: filtered, by: \.period)
        return groups.keys.sorted { $0.number > $1.number }.map { period in
            HockeyTimelinePeriod(period: period, events: (groups[period] ?? []).reversed())
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(HockeyPlayFilter.allCases) { item in
                        Button { filter = item } label: {
                            Text(item.rawValue).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
                                .background(filter == item ? Theme.actionFill : Theme.surface, in: Capsule())
                                .foregroundStyle(filter == item ? Color.white : Theme.textPrimary)
                        }
                        #if os(tvOS)
                        .buttonStyle(.bordered)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .accessibilityAddTraits(filter == item ? [.isSelected] : [])
                    }
                }.padding()
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            HStack(alignment: .top, spacing: 36) {
                timeline.frame(maxWidth: .infinity)
                if let event = events.first(where: { $0.id == selectedEventID }) ?? events.last(where: { !$0.eventType.isBoundary }) {
                    ScrollView { NHLPlayEventRow(event: event, game: game, league: league) }.frame(maxWidth: .infinity)
                }
            }
            #else
            timeline
            #endif
        }
        .onChange(of: events, initial: true) { _, new in
            if atLiveEdge || displayedEvents.isEmpty {
                displayedEvents = new
                deferredIDs = []
            } else {
                let visibleIDs = Set(displayedEvents.map(\.id))
                displayedEvents = new.filter { visibleIDs.contains($0.id) }
                deferredIDs = Set(new.map(\.id)).subtracting(visibleIDs)
            }
        }
        .onChange(of: filter) { _, _ in
            displayedEvents = events
            deferredIDs = []
        }
    }
    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    Color.clear.frame(height: 1).id("live-edge")
                        .onScrollVisibilityChange { visible in
                            atLiveEdge = visible
                            if visible, !deferredIDs.isEmpty {
                                displayedEvents = events
                                deferredIDs = []
                            }
                        }
                    ForEach(periods) { section in
                        VStack(spacing: 12) {
                            Text(section.period.label.uppercased()).font(.subheadline.bold()).frame(maxWidth: .infinity)
                                .padding(.vertical, 12).background(Theme.surfaceElevated)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.events) { event in
                                if event.eventType.isBoundary {
                                    Text(event.title).font(.caption).foregroundStyle(Theme.textSecondary).padding(.vertical, 6)
                                } else {
                                    #if os(tvOS)
                                    Button {
                                        selectedEventID = event.id
                                    } label: {
                                        HStack {
                                            Image(systemName: event.eventType == .goal ? "circle.inset.filled" : "circle")
                                            VStack(alignment: .leading) {
                                                Text(event.title).font(.headline)
                                                Text(event.timeInPeriod ?? "").font(.subheadline.monospacedDigit())
                                            }
                                            Spacer()
                                        }.padding(18)
                                    }.buttonStyle(.card)
                                    #else
                                    NHLPlayEventRow(event: event, game: game, league: league)
                                    #endif
                                }
                            }
                        }
                    }
                    if periods.isEmpty {
                        Text(events.isEmpty ? "No plays yet.\nPlay-by-play will appear when the game begins." : "No plays match this filter.")
                            .multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary).padding(32)
                    }
                }.padding(.bottom, 64)
                    .animation(atLiveEdge && !reduceMotion ? .easeInOut(duration: 0.2) : nil, value: displayedEvents.count)
            }
            .overlay(alignment: .bottom) {
                if !deferredIDs.isEmpty {
                    Button {
                        displayedEvents = events
                        deferredIDs = []
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo("live-edge", anchor: .top) }
                    } label: {
                        Label("\(deferredIDs.count) new plays · Jump to live", systemImage: "arrow.up")
                            .padding().background(Theme.actionFill, in: Capsule()).foregroundStyle(.white)
                    }.buttonStyle(.plain).padding()
                }
            }
        }
    }
}
