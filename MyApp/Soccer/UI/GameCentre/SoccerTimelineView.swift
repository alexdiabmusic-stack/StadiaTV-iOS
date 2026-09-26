import SwiftUI

/// Match Timeline (Step 19): grouped by half, not a basketball-style possession
/// stream. Events arrive pre-sorted (timestamp, then minute, then provider-bucket
/// ordinal) from the reducer — this view only groups, it never re-sorts.
///
/// `wide` drives the two-column "Timeline | Match Context" layout used on iPad
/// (Step 67) and tvOS (Step 68). On tvOS, moving Siri Remote focus over a row
/// updates `focusedEventID`, and the context panel surfaces that event's own detail
/// above the running score/xG comparison — no touch-only gesture is required.
struct SoccerTimelineView: View {
    let snapshot: SoccerGameCentreSnapshot
    var wide: Bool = false
    @FocusState private var focusedEventID: String?
    @State private var filter: TimelineFilter = .all

    private enum TimelineFilter: String, CaseIterable, Identifiable {
        case all = "All", goals = "Goals", shots = "Shots", cards = "Cards", subs = "Subs", setPieces = "Set Pieces"
        var id: String { rawValue }
        func matches(_ type: SoccerEventType) -> Bool {
            switch self {
            case .all: return true
            case .goals: return [.goal, .ownGoal, .penaltyGoal, .missedPenalty, .penaltySaved, .penaltyWon].contains(type)
            case .shots: return [.goal, .ownGoal, .penaltyGoal, .shotSaved, .shotBlocked, .shotOffTarget, .woodwork].contains(type)
            case .cards: return [.yellowCard, .secondYellow, .redCard].contains(type)
            case .subs: return type == .substitution
            case .setPieces: return [.corner, .offside, .foul, .penaltyWon].contains(type)
            }
        }
    }

    private var isPregame: Bool { snapshot.match.map { [.scheduled, .pregame].contains($0.status) } ?? true }

    var body: some View {
        if isPregame {
            ContentUnavailableView("No events yet", systemImage: "clock", description: Text("Match events will appear after kickoff."))
        } else if snapshot.events.isEmpty {
            ContentUnavailableView("No events yet", systemImage: "sportscourt")
        } else if wide {
            HStack(spacing: 0) {
                VStack(spacing: 0) { filterBar; timelineList }
                Divider()
                matchContextPanel.frame(width: 320)
            }
        } else {
            VStack(spacing: 0) { filterBar; timelineList }
        }
    }

    /// Filter chips default to "All" so the clean default view (Step 9) is
    /// unaffected — this is purely an opt-in narrowing, never a default state change.
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(TimelineFilter.allCases) { option in
                    Button { filter = option } label: {
                        Text(option.rawValue).font(.caption.bold()).padding(.horizontal, 10).frame(minHeight: 32)
                            .background(filter == option ? Theme.surfaceElevated : .clear, in: Capsule())
                    }.buttonStyle(.bordered).accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }.padding(.horizontal).padding(.vertical, 4)
        }
    }

    private var timelineList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.events) { event in
                            SoccerEventRow(event: event, match: snapshot.match, directory: snapshot.playerDirectory)
                                #if os(tvOS)
                                .focusable()
                                .focused($focusedEventID, equals: event.id)
                                #endif
                            Divider().padding(.leading, 56)
                        }
                    } header: { sectionHeader(section.title) }
                }
            }.padding(.vertical)
        }
    }

    @ViewBuilder private var matchContextPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MATCH CONTEXT").font(.caption.bold()).foregroundStyle(Theme.textSecondary)
                if let focused = snapshot.events.first(where: { $0.id == focusedEventID }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FOCUSED EVENT").font(.caption2.bold()).foregroundStyle(Theme.textSecondary)
                        SoccerEventRow(event: focused, match: snapshot.match, directory: snapshot.playerDirectory)
                    }
                    Divider()
                }
                if let match = snapshot.match {
                    Text("\(match.home.team.abbreviation) \(match.home.score ?? 0) – \(match.away.score ?? 0) \(match.away.team.abbreviation)")
                        .font(.title3.bold())
                    Text(match.clock?.display ?? "").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                if let home = snapshot.homeStats, let away = snapshot.awayStats {
                    contextStat("xG", home.expectedGoals, away.expectedGoals)
                    contextStat("Possession", home.possession, away.possession)
                    contextStat("Shots", home.shots, away.shots)
                }
                Spacer()
            }.padding()
        }
    }

    private func contextStat(_ title: String, _ home: Double?, _ away: Double?) -> some View {
        Group {
            if let home, let away {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased()).font(.caption2).foregroundStyle(Theme.textSecondary)
                    Text("\(String(format: "%.2f", home)) – \(String(format: "%.2f", away))").font(.subheadline).monospacedDigit()
                }
            }
        }
    }

    private struct EventSection { let title: String; let events: [SoccerMatchEvent] }
    // Case-insensitive: EPL's raw period marker is PascalCase ("FirstHalf"); MLS's
    // `game_section` is camelCase ("firstHalf") — both group into the same section.
    private static func matches(_ period: String?, _ name: String) -> Bool { period?.caseInsensitiveCompare(name) == .orderedSame }
    private var sections: [EventSection] {
        let events = snapshot.events.filter { filter.matches($0.type) }
        let firstHalf = events.filter { Self.matches($0.period, "FirstHalf") }
        let secondHalf = events.filter { Self.matches($0.period, "SecondHalf") }
        let extraFirstHalf = events.filter { Self.matches($0.period, "firstHalfExtra") || Self.matches($0.period, "extraFirstHalf") }
        let extraSecondHalf = events.filter { Self.matches($0.period, "secondHalfExtra") || Self.matches($0.period, "extraSecondHalf") }
        let known = Set(firstHalf.map(\.id) + secondHalf.map(\.id) + extraFirstHalf.map(\.id) + extraSecondHalf.map(\.id))
        let other = events.filter { !known.contains($0.id) }
        var result: [EventSection] = []
        if !firstHalf.isEmpty { result.append(EventSection(title: "FIRST HALF", events: firstHalf)) }
        if !secondHalf.isEmpty { result.append(EventSection(title: "SECOND HALF", events: secondHalf)) }
        if !extraFirstHalf.isEmpty { result.append(EventSection(title: "EXTRA TIME — FIRST HALF", events: extraFirstHalf)) }
        if !extraSecondHalf.isEmpty { result.append(EventSection(title: "EXTRA TIME — SECOND HALF", events: extraSecondHalf)) }
        if !other.isEmpty { result.append(EventSection(title: "OTHER", events: other)) }
        return result
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity).padding(.vertical, 6).background(Theme.surfaceElevated)
            .accessibilityAddTraits(.isHeader)
    }
}
