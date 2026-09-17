import SwiftUI
import Combine

// MARK: - Red Zone & Live Fantasy Alerts

struct FantasyRedZoneAlert: Identifiable, Equatable, Sendable {
    let id: String
    let player: FantasyPlayer
    let matchup: FantasyMatchup?
    let title: String
    let message: String
    let isRedZone: Bool
    let isTouchdown: Bool
    let timestamp: Date
    let channel: Channel?

    init(
        id: String = UUID().uuidString,
        player: FantasyPlayer,
        matchup: FantasyMatchup? = nil,
        title: String,
        message: String,
        isRedZone: Bool = false,
        isTouchdown: Bool = false,
        timestamp: Date = Date(),
        channel: Channel? = nil
    ) {
        self.id = id
        self.player = player
        self.matchup = matchup
        self.title = title
        self.message = message
        self.isRedZone = isRedZone
        self.isTouchdown = isTouchdown
        self.timestamp = timestamp
        self.channel = channel
    }
}

// MARK: - Fantasy Live Tracker Engine

@MainActor
final class FantasyLiveTrackerEngine: ObservableObject {
    static let shared = FantasyLiveTrackerEngine()

    @Published private(set) var activeAlerts: [FantasyRedZoneAlert] = []
    @Published private(set) var recentAlert: FantasyRedZoneAlert?
    @Published var showToastAlert = false

    private var dismissTask: Task<Void, Never>?
    private var knownRedZonePlayerIDs: Set<String> = []

    init() {}

    func processLiveGames(
        playerGames: [FantasyPlayerGame],
        matchup: FantasyMatchup?,
        channels: [Channel] = []
    ) {
        for pg in playerGames {
            guard pg.isFantasyStarter, let match = pg.event, match.state == .live else { continue }

            let statusDetail = match.statusDetail.lowercased()
            let isRedZone = statusDetail.contains("red zone") || statusDetail.contains("inside 20") || statusDetail.contains("goal") || (match.liveContext.football?.isRedZone == true)
            let playerID = pg.id

            if isRedZone && !knownRedZonePlayerIDs.contains(playerID) {
                knownRedZonePlayerIDs.insert(playerID)
                let channel = pg.matchedChannel?.channel

                let alert = FantasyRedZoneAlert(
                    player: pg.fantasyPlayer,
                    matchup: matchup,
                    title: "⚡ RED ZONE ALERT",
                    message: "\(pg.fantasyPlayer.fullName) (\(pg.fantasyPlayer.teamAbbreviation ?? "")) drive inside 20yd line!",
                    isRedZone: true,
                    isTouchdown: false,
                    channel: channel
                )
                triggerAlert(alert)
            } else if !isRedZone {
                knownRedZonePlayerIDs.remove(playerID)
            }
        }
    }

    func triggerAlert(_ alert: FantasyRedZoneAlert) {
        activeAlerts.insert(alert, at: 0)

        // Keep last 10 alerts
        if activeAlerts.count > 10 {
            activeAlerts = Array(activeAlerts.prefix(10))
        }

        recentAlert = alert
        withAnimation(.spring(duration: 0.35)) {
            showToastAlert = true
        }

        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showToastAlert = false
            }
        }
    }

    func dismissCurrentAlert() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            showToastAlert = false
        }
    }
}

// MARK: - Red Zone Toast View

struct FantasyRedZoneToastView: View {
    let alert: FantasyRedZoneAlert
    let onWatchChannel: ((Channel) -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(alert.isTouchdown ? Theme.live : Theme.accent)
                    .frame(width: 36, height: 36)
                Image(systemName: alert.isTouchdown ? "trophy.fill" : "bolt.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(alert.title)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(alert.isTouchdown ? Theme.live : Theme.accent)
                    Spacer()
                    Text("NOW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }

                Text(alert.message)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }

            if let channel = alert.channel, let onWatchChannel {
                Button {
                    onWatchChannel(channel)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.caption2.weight(.bold))
                        Text("Watch")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(alert.isTouchdown ? Theme.live : Theme.accent, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
        .frame(maxWidth: 360)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Fantasy Matchup Sidebar View

struct FantasyMatchupSidebarView: View {
    @EnvironmentObject private var fantasyStore: FantasyStore
    let onWatchChannel: (Channel) -> Void
    let onClose: () -> Void

    @State private var selectedTab: SidebarTab = .matchup

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case matchup = "Matchup"
        case liveStarters = "Live Starters"
        case redZoneFeed = "Red-Zone Feed"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            tabSelector

            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .matchup:
                        matchupCard
                        if let matchup = fantasyStore.matchup {
                            FantasyWinProbabilityChartView(
                                userPoints: matchup.userTeam.effectivePoints ?? 0.0,
                                opponentPoints: matchup.opponentTeam?.effectivePoints ?? 0.0,
                                liveStartersCount: fantasyStore.playerGames.filter(\.isFantasyStarter).count
                            )
                        }
                        if !fantasyStore.playerGames.isEmpty {
                            FantasyPlayerPaceWidget(
                                playerGames: fantasyStore.playerGames.filter(\.isFantasyStarter)
                            )
                        }
                        startersSection
                    case .liveStarters:
                        liveStartersList
                    case .redZoneFeed:
                        redZoneFeedList
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 320)
        .background(.black.opacity(0.92))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                Text("FANTASY TRACKER")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.surfaceElevated)
    }

    private var tabSelector: some View {
        HStack(spacing: 4) {
            ForEach(SidebarTab.allCases) { tab in
                Button {
                    withAnimation(.snappy) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(selectedTab == tab ? .white : Theme.textSecondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(selectedTab == tab ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var matchupCard: some View {
        VStack(spacing: 12) {
            if let matchup = fantasyStore.matchup {
                HStack {
                    teamScoreBlock(
                        name: matchup.userTeam.team?.displayName ?? "My Team",
                        points: matchup.userTeam.effectivePoints,
                        isUser: true
                    )

                    Text("VS")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Theme.textSecondary)

                    teamScoreBlock(
                        name: matchup.opponentTeam?.team?.displayName ?? "Opponent",
                        points: matchup.opponentTeam?.effectivePoints,
                        isUser: false
                    )
                }

                // Win projection bar
                if let myPts = matchup.userTeam.effectivePoints, let oppPts = matchup.opponentTeam?.effectivePoints {
                    let total = max(myPts + oppPts, 1.0)
                    let userRatio = myPts / total
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: geo.size.width * CGFloat(userRatio))
                            Rectangle()
                                .fill(Color.gray.opacity(0.4))
                        }
                    }
                    .frame(height: 6)
                    .clipShape(Capsule())
                }
            } else {
                Text("No active matchup linked")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func teamScoreBlock(name: String, points: Double?, isUser: Bool) -> some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isUser ? Theme.accent : .white)
                .lineLimit(1)
            Text(points.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                .font(.title3.weight(.black).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var startersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STARTERS")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)

            let starters = fantasyStore.playerGames.filter { $0.isFantasyStarter }
            if starters.isEmpty {
                Text("No fantasy starters loaded")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(starters) { game in
                    playerRow(game: game)
                }
            }
        }
    }

    private var liveStartersList: some View {
        VStack(alignment: .leading, spacing: 10) {
            let liveGames = fantasyStore.playerGames.filter { $0.gameState == .live }
            if liveGames.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(Theme.textSecondary)
                    Text("No fantasy starters live right now")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(liveGames) { game in
                    playerRow(game: game)
                }
            }
        }
    }

    private var redZoneFeedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            let alerts = FantasyLiveTrackerEngine.shared.activeAlerts
            if alerts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.slash")
                        .font(.title2)
                        .foregroundStyle(Theme.textSecondary)
                    Text("No red-zone alerts yet")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(alerts) { alert in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(alert.title)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Text(alert.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(alert.message)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)

                        if let channel = alert.channel {
                            Button {
                                onWatchChannel(channel)
                            } label: {
                                Label("Watch Channel", systemImage: "play.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                    .padding(10)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                }
            }
        }
    }

    private func playerRow(game: FantasyPlayerGame) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if game.gameState == .live {
                        Circle()
                            .fill(Theme.live)
                            .frame(width: 6, height: 6)
                    }
                    Text(game.fantasyPlayer.fullName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Text([game.fantasyPlayer.position, game.fantasyPlayer.teamAbbreviation, game.lineupPosition].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if let pts = game.fantasyPoints {
                Text("\(pts, specifier: "%.1f") pts")
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }

            if let channel = game.matchedChannel?.channel {
                Button {
                    onWatchChannel(channel)
                } label: {
                    Image(systemName: "tv.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Watch \(channel.name)")
            }
        }
        .padding(8)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Fantasy Win Probability Chart View

struct FantasyWinProbabilityChartView: View {
    let userPoints: Double
    let opponentPoints: Double
    let liveStartersCount: Int

    private var winProbability: Double {
        let diff = userPoints - opponentPoints
        let rawProb = 1.0 / (1.0 + exp(-diff / 12.0))
        return min(max(rawProb, 0.05), 0.95)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WIN PROBABILITY")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(winProbability >= 0.5 ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(String(format: "%.0f%% Chance", winProbability * 100))
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(winProbability >= 0.5 ? Color.green : Color.red)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((winProbability >= 0.5 ? Color.green : Color.red).opacity(0.15))
                .clipShape(Capsule())
            }

            Canvas { ctx, size in
                let width = size.width
                let height = size.height

                var gridPath = Path()
                gridPath.move(to: CGPoint(x: 0, y: height / 2))
                gridPath.addLine(to: CGPoint(x: width, y: height / 2))
                ctx.stroke(gridPath, with: .color(Color.white.opacity(0.1)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                let pointsCount = 10
                var trendPath = Path()
                var fillPath = Path()

                fillPath.move(to: CGPoint(x: 0, y: height))

                for i in 0..<pointsCount {
                    let progress = CGFloat(i) / CGFloat(pointsCount - 1)
                    let x = progress * width
                    let stepProb = 0.5 + (CGFloat(winProbability) - 0.5) * (progress * progress)
                    let y = height * (1.0 - stepProb)

                    if i == 0 {
                        trendPath.move(to: CGPoint(x: x, y: y))
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        trendPath.addLine(to: CGPoint(x: x, y: y))
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                fillPath.addLine(to: CGPoint(x: width, y: height))
                fillPath.closeSubpath()

                let gradient = Gradient(colors: [
                    (winProbability >= 0.5 ? Color.green : Color.red).opacity(0.3),
                    (winProbability >= 0.5 ? Color.green : Color.red).opacity(0.0)
                ])

                ctx.fill(fillPath, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
                ctx.stroke(trendPath, with: .color(winProbability >= 0.5 ? Color.green : Color.red), lineWidth: 2)
            }
            .frame(height: 50)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Fantasy Player Pace Widget

struct FantasyPlayerPaceWidget: View {
    let playerGames: [FantasyPlayerGame]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PLAYER PACE PROJECTIONS")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .clipShape(Capsule())
            }

            ForEach(playerGames.prefix(4)) { pg in
                let current = pg.fantasyPoints ?? 0.0
                let proj = pg.projectedPoints ?? 12.0
                let diff = current - (proj * 0.6)
                let isOnPace = diff >= 0

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pg.fantasyPlayer.fullName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(pg.fantasyPlayer.position ?? "FLEX")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(Theme.accent)
                            if let team = pg.fantasyPlayer.teamAbbreviation {
                                Text("• \(team)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f", current))
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.white)
                            Text(String(format: "/ %.1f proj", proj))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }

                        HStack(spacing: 2) {
                            Image(systemName: isOnPace ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(isOnPace ? .green : .orange)
                            Text(isOnPace ? "On Pace" : "Behind Pace")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isOnPace ? .green : .orange)
                        }
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
