import SwiftUI

struct SportsProviderDiagnosticsView: View {
    #if DEBUG
    @State private var reachabilityResults: [NBAReachability.ProbeResult] = []
    @State private var isProbing = false
    #endif

    var body: some View {
        List {
            Section("Connected sports APIs") {
                Label("NHL · Direct on-device API", systemImage: "checkmark.circle")
                Label("Formula 1 · Live Timing + Jolpica", systemImage: "checkmark.circle")
                Label("MLB · Direct on-device StatsAPI", systemImage: "checkmark.circle")
                Label("NBA · Direct on-device stats.nba.com + CDN", systemImage: "checkmark.circle")
                Text("Scores, schedules, Game Centre, rosters, player statistics and standings.")
                    .foregroundStyle(.secondary)
            }
            Section("Other sports") {
                Text("No data provider configured. Additional APIs can be connected independently.")
            }
            #if DEBUG
            Section("NBA reachability (debug only)") {
                Button {
                    isProbing = true
                    Task {
                        reachabilityResults = await NBAReachability.probe()
                        isProbing = false
                    }
                } label: {
                    if isProbing { ProgressView() } else { Text("Probe cdn.nba.com / stats.nba.com") }
                }
                .disabled(isProbing)
                ForEach(reachabilityResults) { result in
                    LabeledContent(result.label, value: result.status)
                }
            }
            #endif
        }
        .navigationTitle("Sports Data")
    }
}
