import SwiftUI

/// Optional Shots tab (Step 24). Only reached when a provider actually populates
/// `SoccerGameCentreSnapshot.shots` and opts into `.shots` via `SoccerGameCentreView`'s
/// `availableTabs:` — EPL/MLS never reach this view. Markers: ● goal, ○ saved, ×
/// missed, ▣ blocked. xG only ever shown when the provider supplied it for that shot
/// (Step 15) — never estimated here.
struct SoccerShotMapView: View {
    let shots: [SoccerShot]
    let homeAbbr: String
    let awayAbbr: String
    let homeTeamID: String?
    let awayTeamID: String?
    @State private var filter: Filter = .all
    @State private var selectedShot: SoccerShot?

    private enum Filter: Hashable { case all, home, away }

    private var filteredShots: [SoccerShot] {
        switch filter {
        case .all: return shots
        case .home: return shots.filter { $0.teamID == homeTeamID }
        case .away: return shots.filter { $0.teamID == awayTeamID }
        }
    }

    var body: some View {
        if shots.isEmpty {
            ContentUnavailableView("No shot data yet", systemImage: "nosign", description: Text("A shot map will appear once shots are recorded."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filterBar
                    pitch
                    legend
                }.padding()
            }
            .sheet(item: $selectedShot) { detail($0) }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterButton("All", .all)
            if homeTeamID != nil { filterButton(homeAbbr, .home) }
            if awayTeamID != nil { filterButton(awayAbbr, .away) }
            Spacer()
        }
    }

    private func filterButton(_ title: String, _ value: Filter) -> some View {
        Button(title) { filter = value }
            .buttonStyle(.bordered)
            .tint(filter == value ? Theme.accessibleAccent : Theme.textTertiary)
            .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    private var pitch: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.09, green: 0.32, blue: 0.15))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3)))
                    .overlay(Rectangle().fill(.white.opacity(0.3)).frame(width: 1))
                ForEach(filteredShots) { shot in
                    marker(for: shot).position(position(for: shot, in: geometry.size))
                }
            }
        }
        .aspectRatio(1.5, contentMode: .fit)
    }

    /// Home shots plot attacking rightward, away shots mirrored to attack leftward —
    /// a rendering choice for a single shared pitch, not a claim about the provider's
    /// own coordinate convention. The mapper that produced `shot.x`/`shot.y` preserves
    /// the provider's raw values verbatim; only this view's layout mirrors them.
    private func position(for shot: SoccerShot, in size: CGSize) -> CGPoint {
        let rawX = (shot.x ?? 50) / 100
        let rawY = (shot.y ?? 50) / 100
        let x = shot.teamID == awayTeamID ? (1 - rawX) : rawX
        return CGPoint(x: x * size.width, y: rawY * size.height)
    }

    private func marker(for shot: SoccerShot) -> some View {
        Button { selectedShot = shot } label: {
            symbol(for: shot.outcome).font(.caption.bold())
                .foregroundStyle(shot.teamID == homeTeamID ? Color.yellow : Color.cyan)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: shot))
    }

    private func symbol(for outcome: SoccerShotOutcome) -> Text {
        switch outcome {
        case .goal: return Text("●")
        case .saved: return Text("○")
        case .missed: return Text("×")
        case .blocked: return Text("▣")
        case .unknown: return Text("?")
        }
    }

    private func outcomeLabel(_ outcome: SoccerShotOutcome) -> String {
        switch outcome {
        case .goal: return "Goal"
        case .saved: return "Shot saved"
        case .missed: return "Shot missed"
        case .blocked: return "Shot blocked"
        case .unknown(let raw): return raw
        }
    }

    private func accessibilityLabel(for shot: SoccerShot) -> String {
        var label = shot.playerReference.fullName
        if let minute = shot.minute { label += ", \(minute) minutes" }
        label += ", \(outcomeLabel(shot.outcome))"
        if let xg = shot.expectedGoals { label += ", expected goals \(String(format: "%.2f", xg))" }
        return label
    }

    private func detail(_ shot: SoccerShot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shot.playerReference.fullName).font(.headline)
            if let minute = shot.minute { Text("\(minute)'").font(.subheadline).foregroundStyle(Theme.textSecondary) }
            Text(outcomeLabel(shot.outcome)).font(.subheadline)
            if let xg = shot.expectedGoals { Text("xG \(String(format: "%.2f", xg))").font(.subheadline).foregroundStyle(Theme.textSecondary) }
            if let situation = shot.situation { Text(situation).font(.caption).foregroundStyle(Theme.textTertiary) }
        }.padding()
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem("●", "Goal"); legendItem("○", "Saved"); legendItem("×", "Missed"); legendItem("▣", "Blocked")
        }.font(.caption).foregroundStyle(Theme.textSecondary)
    }

    private func legendItem(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 4) { Text(symbol).bold(); Text(label) }
    }
}
