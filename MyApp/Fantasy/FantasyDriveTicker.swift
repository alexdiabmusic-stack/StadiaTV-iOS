import SwiftUI
import Combine

// MARK: - Fantasy Scoring Play Model

struct FantasyScoringPlay: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let player: FantasyPlayer
    let matchName: String
    let playText: String
    let pointsDelta: Double
    let isTouchdown: Bool
    let isRedZonePlay: Bool
    let timestamp: Date
    let channel: Channel?

    var formattedPoints: String {
        let prefix = pointsDelta >= 0 ? "+" : ""
        return String(format: "%@%.1f pts", prefix, pointsDelta)
    }
}

// MARK: - Fantasy Drive Ticker Engine

@MainActor
final class FantasyDriveTickerEngine: ObservableObject {
    static let shared = FantasyDriveTickerEngine()

    @Published private(set) var recentScoringPlays: [FantasyScoringPlay] = []
    @Published private(set) var currentDriveSummary: String?
    @Published private(set) var activeDrivePlay: MatchPlay?
    @Published private(set) var activeDriveChannel: Channel?
    @Published private(set) var activeDriveMatch: Match?

    private var processedPlayIDs: Set<String> = []

    init() {}

    func updateDriveData(
        playerGames: [FantasyPlayerGame],
        matches: [Match]
    ) {
        let starters = playerGames.filter { $0.isFantasyStarter }

        for pg in starters {
            guard let match = pg.event else { continue }
            let playList = match.liveContext.playByPlay

            // Check recent plays
            for play in playList.suffix(15) {
                guard !processedPlayIDs.contains(play.id) else { continue }

                // Check if play text involves player name
                let name = pg.fantasyPlayer.fullName
                let lastName = pg.fantasyPlayer.lastName ?? name.components(separatedBy: " ").last ?? name

                if play.text.localizedCaseInsensitiveContains(lastName) || play.text.localizedCaseInsensitiveContains(name) {
                    processedPlayIDs.insert(play.id)

                    let pos = pg.fantasyPlayer.position ?? "FLEX"
                    let ptsDelta = estimateFantasyPoints(for: play, position: pos)
                    let isTD = play.isScoringPlay || play.text.localizedCaseInsensitiveContains("touchdown")
                    let isRedZone = play.text.localizedCaseInsensitiveContains("red zone") || play.text.localizedCaseInsensitiveContains("goal")

                    let scoringPlay = FantasyScoringPlay(
                        id: play.id,
                        player: pg.fantasyPlayer,
                        matchName: match.shortName,
                        playText: play.text,
                        pointsDelta: ptsDelta,
                        isTouchdown: isTD,
                        isRedZonePlay: isRedZone,
                        timestamp: play.providerTimestamp ?? Date(),
                        channel: pg.matchedChannel?.channel
                    )

                    withAnimation(.spring(duration: 0.4)) {
                        recentScoringPlays.insert(scoringPlay, at: 0)
                        if recentScoringPlays.count > 10 {
                            recentScoringPlays.removeLast()
                        }
                    }
                }
            }

            // Check current active drive
            if let currentDrive = match.liveContext.drives.first(where: { $0.isCurrent }) {
                if let lastPlay = currentDrive.plays.last {
                    let team = currentDrive.teamAbbreviation ?? match.home.abbreviation
                    let summary = "\(team) Drive: \(currentDrive.summary ?? "\(currentDrive.plays.count) plays")"
                    self.currentDriveSummary = summary
                    self.activeDrivePlay = lastPlay
                    self.activeDriveChannel = pg.matchedChannel?.channel
                    self.activeDriveMatch = match
                }
            }
        }
    }

    private func estimateFantasyPoints(for play: MatchPlay, position: String) -> Double {
        if play.isScoringPlay || play.text.localizedCaseInsensitiveContains("touchdown") {
            if position.uppercased() == "QB" && play.text.localizedCaseInsensitiveContains("pass") {
                return 4.0
            }
            return 6.0
        }
        if play.text.localizedCaseInsensitiveContains("field goal") {
            return 3.0
        }
        if play.text.localizedCaseInsensitiveContains("pass") || play.text.localizedCaseInsensitiveContains("reception") {
            return 1.5
        }
        if play.text.localizedCaseInsensitiveContains("rush") || play.text.localizedCaseInsensitiveContains("run") {
            return 1.2
        }
        return 0.5
    }
}

// MARK: - Fantasy Drive Ticker Overlay View

struct FantasyDriveTickerOverlayView: View {
    @ObservedObject var engine = FantasyDriveTickerEngine.shared
    let onWatchChannel: ((Channel) -> Void)?

    @State private var isExpanded: Bool = true

    var body: some View {
        if !engine.recentScoringPlays.isEmpty || engine.currentDriveSummary != nil {
            VStack(alignment: .leading, spacing: 8) {
                // Header bar with expand toggle & live drive summary
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text("LIVE FANTASY TICKER")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())

                    if let driveSummary = engine.currentDriveSummary {
                        Text(driveSummary)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }

                    Spacer()

                    if let play = engine.recentScoringPlays.first, let ch = play.channel {
                        Button {
                            onWatchChannel?(ch)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tv.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Watch")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.yellow)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(6)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                // Expanded play-by-play ticker list
                if isExpanded {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(engine.recentScoringPlays) { play in
                                ScoringPlayCard(play: play, onWatch: {
                                    if let ch = play.channel {
                                        onWatchChannel?(ch)
                                    }
                                })
                            }
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Scoring Play Card

struct ScoringPlayCard: View {
    let play: FantasyScoringPlay
    let onWatch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Player avatar / position badge
            ZStack {
                Circle()
                    .fill(play.isTouchdown ? Color.green.opacity(0.3) : Color.white.opacity(0.15))
                    .frame(width: 32, height: 32)
                Text(play.player.position ?? "FLEX")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(play.isTouchdown ? .green : .white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(play.player.fullName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(play.formattedPoints)
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(play.pointsDelta >= 0 ? .green : .red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(play.pointsDelta >= 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        .clipShape(Capsule())
                }

                Text(play.playText)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }

            if play.channel != nil {
                Button(action: onWatch) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.black)
                        .padding(6)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
