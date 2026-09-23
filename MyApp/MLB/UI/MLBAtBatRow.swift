import SwiftUI

struct MLBAtBatRow: View {
    let play: BaseballAtBat
    let game: BaseballGame?
    let league: League
    var expandedByDefault = false
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Image(systemName: play.isScoringPlay ? "baseball.fill" : "circle").foregroundStyle(play.isScoringPlay ? Theme.accessibleAccent : Theme.textSecondary)
                Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1)
            }.frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(play.resultTitle).font(play.isScoringPlay ? .headline : .subheadline.bold())
                    Spacer()
                    if play.isScoringPlay { Image(systemName: "star.fill").accessibilityLabel("Scoring play") }
                    if !play.isComplete { Text("LIVE").font(.caption.bold()) }
                }
                if let batter = play.batter { MLBPlayerLink(player: batter, league: league) }
                Text(play.resultDescription).font(.subheadline)
                if play.isScoringPlay {
                    ForEach(play.runners.filter { $0.scored }) { runner in
                        Text("\(runner.runner?.name ?? "Runner") scores").font(.subheadline)
                    }
                    if let away = play.awayScore, let home = play.homeScore {
                        Text("\(game?.away.abbreviation ?? "Away") \(away) · \(game?.home.abbreviation ?? "Home") \(home)").font(.headline.monospacedDigit())
                    }
                }
                if let hit = play.events.last(where: { $0.hitDistance != nil || $0.exitVelocity != nil }) {
                    Text([hit.hitDistance.map { String(format: "%.0f ft", $0) }, hit.exitVelocity.map { String(format: "%.1f mph", $0) }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if !play.events.isEmpty {
                    if !expandedByDefault { Button { expanded.toggle() } label: {
                        Label(expanded || expandedByDefault ? "Hide pitches and actions" : "View pitches and actions", systemImage: expanded || expandedByDefault ? "chevron.up" : "chevron.down")
                            .font(.subheadline).frame(minHeight: 44)
                    }
                    }
                    if expanded || expandedByDefault { MLBPitchSequenceView(events: play.events) }
                }
            }.padding(play.isScoringPlay ? 16 : 8)
                .background(play.isScoringPlay ? Theme.surfaceElevated : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }.padding(.horizontal).padding(.vertical, 6)
    }
}
struct MLBPitchSequenceView: View {
    let events: [BaseballPlayEvent]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.isPitch ? "\(event.pitchNumber.map(String.init) ?? "–"). \(event.pitchTypeDescription ?? "Pitch") · \(event.callDescription ?? event.description)" : event.description)
                        .font(.subheadline)
                    if let speed = event.startSpeed { Text("\(speed, specifier: "%.1f") mph").font(.caption).foregroundStyle(.secondary) }
                    if let location = event.coordinates { MLBPitchLocationView(location: location).frame(width: 100, height: 110) }
                }
            }
        }
    }
}
struct MLBPitchLocationView: View {
    let location: BaseballPitchCoordinates
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: size.width * 0.25, y: size.height * 0.2, width: size.width * 0.5, height: size.height * 0.6)
            context.stroke(Path(rect), with: .color(.secondary), lineWidth: 1)
            // pX/pZ are feet at the plate. Plate width is 17 inches.
            let x = size.width / 2 + location.plateX / (17.0 / 12) * rect.width
            let y = rect.maxY - (location.plateZ - location.zoneBottom) / (location.zoneTop - location.zoneBottom) * rect.height
            let dot = CGRect(x: min(size.width - 7, max(0, x - 3)), y: min(size.height - 7, max(0, y - 3)), width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(Theme.accessibleAccent))
        }.accessibilityLabel("Pitch location, \(location.plateX, specifier: "%.1f") feet horizontally, \(location.plateZ, specifier: "%.1f") feet above ground")
    }
}
