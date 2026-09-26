import SwiftUI

/// Renders directly from `SoccerFormation.rows` — real provider structure (goalkeeper
/// row first, then each tactical line toward the opponent's goal) — never from
/// parsing the display string. Falls back to a plain starting-XI list when no
/// formation was supplied, rather than fabricating a pitch layout (Step 27).
struct SoccerFormationPitchView: View {
    let lineup: SoccerLineup

    /// The lineup's own players already carry full name info — no need for the
    /// match-wide player directory here, just a local lookup for `SoccerPlayerLink`.
    private var directory: [String: SoccerPlayerReference] {
        Dictionary(uniqueKeysWithValues: (lineup.starters + lineup.substitutes).map { ($0.reference.id, $0.reference) })
    }

    var body: some View {
        if let formation = lineup.formation, !formation.rows.isEmpty {
            GeometryReader { geometry in
                ZStack {
                    pitchBackground
                    VStack(spacing: 0) {
                        // rows[0] is the goalkeeper; render most-advanced line at the
                        // top (toward the opponent's goal) and the goalkeeper at the bottom.
                        ForEach(Array(formation.rows.reversed().enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 0) {
                                ForEach(row, id: \.self) { playerID in
                                    playerToken(playerID)
                                        .frame(maxWidth: .infinity)
                                }
                            }.frame(maxHeight: .infinity)
                        }
                    }.padding(.vertical, 16)
                }
            }
            .aspectRatio(0.68, contentMode: .fit)
        } else {
            fallbackList
        }
    }

    private var pitchBackground: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.09, green: 0.32, blue: 0.15))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3)))
            .overlay(Circle().strokeBorder(.white.opacity(0.3)).frame(width: 70, height: 70))
    }

    /// The pitch is a spatial diagram, not a text flow — growing these badges with
    /// Dynamic Type would overlap adjacent players and break the layout, so the
    /// badge size is intentionally fixed (a `minimumScaleFactor` guards the number
    /// itself against clipping). The real accessibility path for a low-vision/
    /// VoiceOver user is the full descriptive label below, not the visible glyph —
    /// every token carries name, position, and captaincy regardless of visual size.
    private func playerToken(_ playerID: String) -> some View {
        let player = lineup.starters.first { $0.reference.id == playerID }
        return SoccerPlayerLink(playerID: playerID, directory: directory) { _ in
            VStack(spacing: 2) {
                ZStack {
                    Circle().fill(.white)
                    Text(player?.shirtNumber ?? "-").font(.caption.bold()).foregroundStyle(.black).minimumScaleFactor(0.5).lineLimit(1)
                }.frame(width: 26, height: 26)
                Text(player?.reference.lastName ?? "").font(.caption2).foregroundStyle(.white).lineLimit(1)
                    .shadow(color: .black, radius: 2)
                if let rating = player?.rating {
                    Text(String(format: "%.1f", rating)).font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 4).background(Theme.accessibleAccent, in: Capsule())
                }
            }
        }
        .accessibilityLabel(tokenAccessibilityLabel(player))
    }

    private func tokenAccessibilityLabel(_ player: SoccerLineupPlayer?) -> String {
        guard let player else { return "Player" }
        var label = "Number \(player.shirtNumber ?? "unknown"), \(player.reference.fullName)"
        if let position = player.position { label += ", \(position)" }
        if player.isCaptain { label += ", captain" }
        if let rating = player.rating { label += ", FotMob Rating \(String(format: "%.1f", rating))" }
        return label
    }

    private var fallbackList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Formation not supplied — starting XI:").font(.caption).foregroundStyle(Theme.textSecondary)
            ForEach(lineup.starters) { player in
                SoccerPlayerLink(playerID: player.reference.id, directory: directory) { name in
                    HStack { Text(player.shirtNumber ?? "-").frame(width: 28); Text(name); Spacer() }
                }
            }
        }.padding()
    }
}
