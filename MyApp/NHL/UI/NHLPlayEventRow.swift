import SwiftUI

struct NHLPlayEventRow: View {
    let event: HockeyPlayEvent
    let game: HockeyGame?
    let league: League
    @State private var expanded = false
    private var team: HockeyTeam? { [game?.away, game?.home].compactMap { $0 }.first { $0.id == event.teamID } }
    private var prominent: Bool { event.eventType == .goal || event.eventType == .penalty }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: icon).font(prominent ? .title3 : .body)
                    .foregroundStyle(event.eventType == .goal ? Theme.accent : Theme.textSecondary)
                    .frame(width: 28, height: 32)
                    .accessibilityHidden(true)
                Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: prominent ? 12 : 6) {
                HStack {
                    Text(label).font(.caption.weight(.bold))
                    if let team {
                        if event.eventType == .goal { TeamLogo(url: team.logo, size: 24).accessibilityHidden(true) }
                        Text(team.abbreviation).font(.caption.weight(.semibold))
                    }
                    Spacer()
                    if let round = event.shootoutRound { Text("Round \(round)").font(.caption) }
                    else { Text(event.timeInPeriod ?? "").font(.caption.monospacedDigit()) }
                    if event.eventType == .goal, event.period.kind != .shootout, let a = event.awayScore, let h = event.homeScore {
                        Text("\(a)–\(h)").font(.headline.monospacedDigit()).padding(.horizontal, 8)
                            .background(Theme.surfaceElevated, in: Capsule())
                            .accessibilityLabel("\(game?.away.name ?? "Away") \(a), \(game?.home.name ?? "Home") \(h)")
                    }
                }.foregroundStyle(Theme.textSecondary)
                HStack(alignment: .top, spacing: 10) {
                    if event.eventType == .goal, let player = event.primaryPlayer, let url = player.headshot {
                        NavigationLink {
                            PlayerDetailView(league: league, athlete: NHLProvider.athlete(player))
                        } label: {
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "person.crop.circle") }
                                .frame(width: 56, height: 56)
                        }.accessibilityLabel("View \(player.name)")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if let player = event.primaryPlayer, player.name != "Unknown player" {
                            NavigationLink {
                                PlayerDetailView(league: league, athlete: NHLProvider.athlete(player))
                            } label: {
                                Text(event.title).font(prominent ? .headline : .body)
                                    .frame(minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                        } else {
                            Text(event.title).font(prominent ? .headline : .body)
                        }
                        if let subtitle = event.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                    }
                }
                if event.eventType == .goal, let total = event.scorerSeasonGoals {
                    Text("Season goal \(total)").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if event.eventType == .goal, !event.assistSeasonTotals.isEmpty {
                    Text(event.assists.map { player in
                        player.name + (event.assistSeasonTotals[player.id].map { " (\($0))" } ?? "")
                    }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Season assists. " + event.assists.map { player in
                        "\(player.name), \(event.assistSeasonTotals[player.id] ?? 0)"
                    }.joined(separator: ". "))
                }
                if event.eventType == .goal, let url = event.videoURL {
                    Link(destination: url) { Label("Watch goal", systemImage: "play.fill").font(.subheadline.bold()).frame(minHeight: 44) }
                }
                if expanded {
                    if let player = event.primaryPlayer, player.name != "Unknown player" {
                        NavigationLink("View \(player.name)") {
                            PlayerDetailView(league: league, athlete: NHLProvider.athlete(player))
                        }.frame(minHeight: 44)
                    }
                    if let x = event.xCoordinate, let y = event.yCoordinate {
                        NHLShotLocationView(x: x, y: y, defendingSide: event.homeTeamDefendingSide)
                    }
                }
                if event.primaryPlayer != nil || event.xCoordinate != nil {
                    Button(expanded ? "Hide details" : "Event details") { expanded.toggle() }
                        .font(.caption).frame(minHeight: 44)
                        .accessibilityLabel("\(expanded ? "Hide" : "Show") details for \(event.title)")
                }
            }
            .padding(prominent ? 14 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(prominent ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .leading) {
                if event.eventType == .goal { RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 12) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label), \(team?.name ?? ""). \(event.title). \(event.subtitle ?? ""). \(event.period.label), \(event.timeInPeriod ?? "")")
        #if os(tvOS)
        .padding(.vertical, 8)
        #endif
    }
    private var label: String {
        if event.period.kind == .shootout, event.shootoutRound != nil { return event.eventType == .goal ? "✓ SHOOTOUT GOAL" : "✕ SHOOTOUT ATTEMPT" }
        switch event.eventType {
        case .goal: return "GOAL"
        case .penalty: return "PENALTY"
        case .shot: return "SHOT"
        case .missedShot: return "MISSED SHOT"
        case .blockedShot: return "BLOCKED SHOT"
        case .hit: return "HIT"
        case .faceoff: return "FACEOFF"
        case .giveaway: return "GIVEAWAY"
        case .takeaway: return "TAKEAWAY"
        case .delayedPenalty: return "DELAYED PENALTY"
        case .stoppage: return "STOPPAGE"
        default: return "EVENT"
        }
    }
    private var icon: String {
        switch event.eventType {
        case .goal: return "circle.inset.filled"
        case .penalty, .delayedPenalty: return "exclamationmark.square"
        case .hit: return "burst"
        case .faceoff: return "circle.circle"
        case .shot, .missedShot, .blockedShot, .failedShot: return "scope"
        default: return "circle.fill"
        }
    }
}
struct NHLShotLocationView: View {
    let x: Double
    let y: Double
    let defendingSide: String?
    var body: some View {
        GeometryReader { proxy in
            // Normalize to a home-defends-left rink. Rotate both coordinates
            // together; reflecting just x would invert the rink handedness.
            let rotation = defendingSide == "right" ? -1.0 : 1.0
            ZStack {
                RoundedRectangle(cornerRadius: 32).fill(Color.white)
                RoundedRectangle(cornerRadius: 32).stroke(Color.gray, lineWidth: 2)
                Rectangle().fill(Color.red).frame(width: 2)
                HStack { Rectangle().fill(Color.blue).frame(width: 2); Spacer(); Rectangle().fill(Color.blue).frame(width: 2) }.padding(.horizontal, proxy.size.width * 0.375)
                Circle().stroke(Color.blue, lineWidth: 1).frame(width: proxy.size.height * 0.35)
                Circle().fill(Color.black).frame(width: 12, height: 12)
                    .position(x: (min(100, max(-100, x * rotation)) + 100) / 200 * proxy.size.width,
                              y: (42.5 - min(42.5, max(-42.5, y * rotation))) / 85 * proxy.size.height)
            }
        }
        .aspectRatio(200 / 85, contentMode: .fit)
        .frame(maxWidth: 380)
        .accessibilityLabel("Rink location, x \(Int(x)), y \(Int(y)). \(defendingSide == nil ? "Feed orientation" : "Home team defends left")")
    }
}
