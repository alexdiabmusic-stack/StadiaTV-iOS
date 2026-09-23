import SwiftUI

struct NFLCalendarView: View {
    @State private var season: Int
    @State private var stage: NFLSeasonType
    @State private var week: Int
    @State private var choices: [NFLWeekChoice] = []
    @State private var matches: [Match] = []
    @State private var error: String?
    @State private var loading = true
    @State private var revision = 0
    private let provider = NFLProvider()
    init(week: NFLWeek) {
        _season = State(initialValue: week.season); _stage = State(initialValue: week.seasonType); _week = State(initialValue: week.week)
    }
    var body: some View {
        List {
            Section {
                Picker("Season", selection: $season) {
                    ForEach((Calendar.current.component(.year, from: .now) - 10)...Calendar.current.component(.year, from: .now), id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("Stage", selection: $stage) {
                    Text("Preseason").tag(NFLSeasonType.preseason)
                    Text("Regular season").tag(NFLSeasonType.regular)
                    Text("Postseason").tag(NFLSeasonType.postseason)
                }
                if !choices.isEmpty { Picker("Week", selection: $week) { ForEach(choices) { Text($0.label).tag($0.id) } } }
            }
            if loading { ProgressView("Loading NFL schedule") }
            if let error { Text(error); Button("Retry") { revision += 1 } }
            ForEach(matches) { match in
                NavigationLink {
                    #if os(tvOS)
                    TVMatchDetailView(match: match)
                    #else
                    MatchDetailView(match: match)
                    #endif
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(match.shortName).font(.headline)
                        Text(match.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        Text(match.statusDetail).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            if !loading, matches.isEmpty, error == nil { Text("No games available for this week.") }
        }.navigationTitle("NFL calendar & results")
        .task(id: "\(season):\(stage.rawValue):\(week):\(revision)") {
            loading = true; error = nil; matches = []
            do {
                let weeks = try await provider.weeks(season: season, type: stage)
                guard !Task.isCancelled else { return }
                choices = weeks
                guard weeks.contains(where: { $0.id == week }) else {
                    if let first = weeks.first { week = first.id } else { loading = false }
                    return
                }
                let games = try await provider.weekSchedule(NFLWeek(season: season, seasonType: stage, week: week))
                guard !Task.isCancelled else { return }
                matches = games; loading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }
    }
}
