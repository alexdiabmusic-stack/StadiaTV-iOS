import SwiftUI

/// The soccer-specific score hero (Steps 45–48): largest emphasis on the score,
/// then club identity, then status/clock, with red-card counts and venue kept
/// subtle. Pregame never shows a fabricated "0–0".
struct SoccerScoreHeaderView: View {
    let match: SoccerMatch
    let homeLogo: URL?
    let awayLogo: URL?
    let hideScore: Bool

    private var isPregame: Bool { [.scheduled, .pregame].contains(match.status) }

    private var statusLabel: String {
        switch match.status {
        case .scheduled, .pregame: return match.kickoff.formatted(date: .abbreviated, time: .shortened)
        case .halftime: return "HALF TIME"
        case .fullTime: return "FULL TIME"
        case .postponed: return "POSTPONED"
        case .suspended: return "SUSPENDED"
        case .abandoned: return "ABANDONED"
        case .cancelled: return "CANCELLED"
        case .delayed: return "DELAYED"
        case .firstHalf, .secondHalf, .stoppageTime, .extraFirstHalf, .extraSecondHalf: return "LIVE • \(match.clock?.display ?? "")"
        case .extraHalftime: return "HALF TIME (ET)"
        case .penalties: return "PENALTIES"
        case .unknown(let raw): return raw.isEmpty ? "—" : raw
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(statusLabel).font(.subheadline.bold()).foregroundStyle(match.status.isLive ? Theme.live : Theme.textSecondary)
            HStack {
                teamColumn(name: match.home.team.name, logo: homeLogo)
                Spacer(minLength: 8)
                scoreOrVersus
                Spacer(minLength: 8)
                teamColumn(name: match.away.team.name, logo: awayLogo)
            }
            if match.home.redCards > 0 || match.away.redCards > 0 {
                HStack(spacing: 20) {
                    if match.home.redCards > 0 { redCardBadge(match.home.redCards) }
                    if match.away.redCards > 0 { redCardBadge(match.away.redCards) }
                }
            }
            if let ground = match.ground { Text(ground).font(.caption).foregroundStyle(Theme.textTertiary) }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var scoreOrVersus: some View {
        if isPregame {
            Text("vs").font(.title2.bold()).foregroundStyle(Theme.textSecondary)
        } else if hideScore {
            Text("–").font(.system(.largeTitle, weight: .bold))
        } else {
            Text("\(match.home.score ?? 0) – \(match.away.score ?? 0)").font(.system(.largeTitle, weight: .bold)).monospacedDigit()
        }
    }

    private func teamColumn(name: String, logo: URL?) -> some View {
        VStack(spacing: 6) {
            TeamLogo(url: logo, size: 44)
            Text(name).font(.subheadline.bold()).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: 110)
    }

    private func redCardBadge(_ count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.portrait.fill").font(.caption2).foregroundStyle(.red)
            Text("\(count)").font(.caption.bold())
        }
    }

    private var accessibilityLabel: String {
        guard !isPregame, !hideScore else { return "\(match.home.team.name) versus \(match.away.team.name), \(statusLabel)" }
        var label = "\(match.home.team.name) \(match.home.score ?? 0), \(match.away.team.name) \(match.away.score ?? 0). \(statusLabel)."
        if match.home.redCards > 0 { label += " \(match.home.team.name) have \(match.home.redCards) red card\(match.home.redCards == 1 ? "" : "s")." }
        if match.away.redCards > 0 { label += " \(match.away.team.name) have \(match.away.redCards) red card\(match.away.redCards == 1 ? "" : "s")." }
        return label
    }
}
