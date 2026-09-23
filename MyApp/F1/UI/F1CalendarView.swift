import SwiftUI

/// Jolpica supplies both future discovery and navigation to archived sessions.
struct F1CalendarView: View {
    @State private var season = Calendar.current.component(.year, from: .now)
    @State private var meetings: [F1Meeting] = []
    @State private var error: String?
    @State private var revision = 0
    var body: some View {
        List {
            Section {
                Picker("Season", selection: $season) {
                    ForEach((Calendar.current.component(.year, from: .now) - 5)...Calendar.current.component(.year, from: .now), id: \.self) { year in Text(String(year)).tag(year) }
                }
            }
            if let error {
                Section { Text(error); Button("Retry") { revision += 1 } }
            } else if meetings.isEmpty { ProgressView("Loading calendar") }
            ForEach(meetings) { meeting in
                Section(meeting.name) {
                    ForEach(meeting.sessions) { session in
                        NavigationLink {
                            F1RaceCentreView(match: F1Provider.match(session)) { EmptyView() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) { Text(session.name); Text(session.circuit).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(session.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).multilineTextAlignment(.trailing)
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
        }.navigationTitle("Formula 1 calendar")
        .onChange(of: season) { _, _ in meetings = []; error = nil }
        .task(id: "\(season):\(revision)") {
            do {
                let result = try await F1CalendarService.shared.meetings(season: season)
                guard !Task.isCancelled else { return }
                meetings = result; error = result.isEmpty ? "Calendar unavailable for this season." : nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
