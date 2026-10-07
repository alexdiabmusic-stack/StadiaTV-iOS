import SwiftUI

// Shared, cross-sport Game Detail components built on Theme tokens. Adopted by
// NHL and Basketball (NBA/WNBA) game centers; other sports keep their current
// layout for now but already benefit from PrimaryStreamCard/AlternateStreamsButton
// and the news relevance ranking via MatchDetailView's shared closures.

// MARK: - Status badge

struct GameStatusBadge: View {
    let status: GameStatusPresentation

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if status.isLive {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 6, height: 6)
                    .modifier(PulseEffect(active: status.kind == .live))
            }
            Text(status.text)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(status.isLive ? Theme.live : Theme.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityText)
    }
}

private struct PulseEffect: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 0.35 : 1)
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
            }
    }
}

// MARK: - Score hero

struct GameScoreHero: View {
    let league: String
    let status: GameStatusPresentation
    let away: GameHeroTeam
    let home: GameHeroTeam
    var awayDestination: () -> AnyView
    var homeDestination: () -> AnyView

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(league.uppercased())
                .font(Theme.Typography.overline)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)

            GameStatusBadge(status: status)

            HStack(spacing: Theme.Spacing.lg) {
                teamColumn(away, destination: awayDestination)
                centerScore
                teamColumn(home, destination: homeDestination)
            }
        }
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }

    @ViewBuilder private var centerScore: some View {
        if case .scheduled(let date) = status.kind {
            Text(date, style: .time)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 60)
        } else {
            Text("\(away.score ?? "–")–\(home.score ?? "–")")
                .font(.system(size: Theme.scaled(40), weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(minWidth: 70)
                .contentTransition(.numericText())
                .accessibilityLabel("\(away.name) \(away.score ?? "unknown"), \(home.name) \(home.score ?? "unknown")")
        }
    }

    private func teamColumn(_ team: GameHeroTeam, destination: () -> AnyView) -> some View {
        NavigationLink(destination: destination()) {
            VStack(spacing: Theme.Spacing.xxs) {
                TeamLogo(url: team.logo, size: Theme.scaled(56))
                    .accessibilityHidden(true)
                Text(team.abbreviation)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(team.isLeading ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if let metric = team.supportingMetric {
                    Text(metric)
                        .font(Theme.Typography.captionDigits)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(team.name)\(team.supportingMetric.map { ", \($0)" } ?? ""). Team roster")
    }
}

// MARK: - Tab bar

struct GameTabBar<Tab: Identifiable & RawRepresentable & Hashable>: View where Tab.RawValue == String {
    let tabs: [Tab]
    @Binding var selection: Tab

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.lg) {
                ForEach(tabs) { tab in
                    Button {
                        withAnimation(Theme.Motion.snappy) { selection = tab }
                    } label: {
                        VStack(spacing: Theme.Spacing.xxs) {
                            Text(tab.rawValue)
                                .font(Theme.Typography.callout.weight(selection == tab ? .bold : .regular))
                                .foregroundStyle(selection == tab ? Theme.textPrimary : Theme.textSecondary)
                            Capsule()
                                .fill(selection == tab ? Theme.accessibleAccent : .clear)
                                .frame(height: 2)
                        }
                        .frame(minHeight: 44)
                    }
                    #if os(tvOS)
                    .buttonStyle(.plain)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

// MARK: - Section header

struct GameDetailSection<Content: View>: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(Theme.Typography.overline)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            content
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                    }
                    .font(Theme.Typography.callout.weight(.semibold))
                    .foregroundStyle(Theme.accessibleAccent)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }
}

// MARK: - Scoring timeline

struct EventTimeline: View {
    let events: [TimelineEvent]
    let league: League
    var emptyText: String = "No scoring yet."

    var body: some View {
        if events.isEmpty {
            Text(emptyText)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    TimelineEventRow(event: event, isLast: index == events.count - 1)
                }
            }
        }
    }
}

struct TimelineEventRow: View {
    let event: TimelineEvent
    var isLast: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Theme.accessibleAccent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                if !isLast {
                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text([event.periodText, event.clockText].compactMap { $0 }.joined(separator: " · ").uppercased())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(event.badges) { badge in
                        Text(badge.rawValue)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let score = event.scoreAfter {
                        TeamLogo(url: event.teamLogo, size: 16).accessibilityHidden(true)
                        Text(score)
                            .font(Theme.Typography.headlineDigits)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    if let headshot = event.headshot {
                        CachedImage(url: headshot) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFill() }
                            else { Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary.opacity(0.6)) }
                        }
                        .frame(width: 40, height: 40)
                        .background(Theme.surfaceElevated)
                        .clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.headline)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if let detail = event.detail {
                            Text(detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let secondary = event.secondary {
                            Text(secondary)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        if let replay = event.replayURL {
                            Link(destination: replay) {
                                Label("Replay", systemImage: "play.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.accessibleAccent)
                            }
                            .frame(minHeight: 32)
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.periodText), \(event.clockText ?? ""). \(event.headline). \(event.detail ?? ""). \(event.scoreAfter.map { "Score \($0)" } ?? "")")
    }
}

// MARK: - Leaders

struct GameLeadersStrip: View {
    let leaders: [LeaderCard]
    var body: some View {
        if !leaders.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(leaders) { leader in
                        PlayerLeaderCard(leader: leader)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -Theme.Spacing.md)
        }
    }
}

struct PlayerLeaderCard: View {
    let leader: LeaderCard
    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            CachedImage(url: leader.headshot) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() }
                else { Image(systemName: "person.fill").font(.title2).foregroundStyle(Theme.textSecondary.opacity(0.6)) }
            }
            .frame(width: 56, height: 56)
            .background(Theme.surfaceElevated)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.hairline))

            Text(leader.name)
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(leader.statLine)
                .font(Theme.Typography.captionDigits)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Text(leader.role ?? leader.teamAbbreviation)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: 112)
        .padding(Theme.Spacing.sm)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Team stats comparison

struct TeamStatsComparison: View {
    let stats: [ComparisonStat]
    let awayAbbreviation: String
    let homeAbbreviation: String

    var body: some View {
        if stats.isEmpty {
            Text("Team statistics will appear when available.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.textSecondary)
        } else {
            VStack(spacing: Theme.Spacing.md) {
                HStack {
                    Text(awayAbbreviation).font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(homeAbbreviation).font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(stats) { stat in
                    ComparisonStatRow(stat: stat)
                }
            }
        }
    }
}

struct ComparisonStatRow: View {
    let stat: ComparisonStat

    private var awayShare: Double {
        switch stat.visualization {
        case .share(let a, let h): return (a + h) > 0 ? a / (a + h) : 0.5
        case .percentSplit(let a, _): return a / 100
        case .fraction(let am, let aa, _, _): return aa > 0 ? am / aa : 0
        case .none: return 0.5
        }
    }
    private var homeShare: Double {
        switch stat.visualization {
        case .percentSplit(_, let h): return h / 100
        case .fraction(_, _, let hm, let ha): return ha > 0 ? hm / ha : 0
        default: return 1 - awayShare
        }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            HStack {
                statValue(stat.awayDisplay, secondary: stat.awaySecondary, emphasized: stat.leader == .away)
                Spacer()
                Text(stat.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                statValue(stat.homeDisplay, secondary: stat.homeSecondary, emphasized: stat.leader == .home, alignment: .trailing)
            }
            if stat.visualization != .none {
                GeometryReader { proxy in
                    let midpoint = proxy.size.width / 2
                    let awayWidth = isSplit ? midpoint * awayShare : proxy.size.width * awayNormalizedShare
                    let homeWidth = isSplit ? midpoint * homeShare : proxy.size.width * (1 - awayNormalizedShare)
                    HStack(spacing: isSplit ? 2 : 0) {
                        Capsule()
                            .fill(stat.leader == .away ? Theme.accessibleAccent : Theme.textTertiary.opacity(0.5))
                            .frame(width: max(2, awayWidth))
                        Capsule()
                            .fill(stat.leader == .home ? Theme.accessibleAccent : Theme.textTertiary.opacity(0.5))
                            .frame(width: max(2, homeWidth))
                    }
                }
                .frame(height: 6)
                .animation(Theme.Motion.smooth, value: awayShare)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.accessibilityLabel)
    }

    /// Percent-split stats render as two independent bars meeting at a midpoint; count/fraction
    /// stats render as one proportional bar spanning the full width.
    private var isSplit: Bool {
        if case .percentSplit = stat.visualization { return true }
        return false
    }
    private var awayNormalizedShare: Double {
        switch stat.visualization {
        case .share(let a, let h): return (a + h) > 0 ? a / (a + h) : 0.5
        case .fraction(let am, let aa, let hm, let ha):
            let ap = aa > 0 ? am / aa : 0, hp = ha > 0 ? hm / ha : 0
            return (ap + hp) > 0 ? ap / (ap + hp) : 0.5
        default: return 0.5
        }
    }

    private func statValue(_ text: String, secondary: String?, emphasized: Bool, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(text)
                .font(Theme.Typography.headlineDigits.weight(emphasized ? .bold : .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let secondary {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(minWidth: 44, alignment: alignment == .leading ? .leading : .trailing)
    }
}

// MARK: - Primary stream card

struct PrimaryStreamCard: View {
    let title: String
    let isLive: Bool
    /// EPG programme title when the guide confirms this channel is airing the event, e.g. "Kings @ Sharks".
    var matchLabel: String? = nil
    let countryFlag: String?
    let quality: String?
    let isConfirmed: Bool
    let showsNewBadge: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(isLive ? Theme.live : Theme.accessibleAccent)
                    Text(isLive ? "WATCH LIVE" : "WATCH WHEN LIVE")
                        .font(Theme.Typography.overline)
                        .foregroundStyle(Theme.textSecondary)
                    if showsNewBadge { newBadge }
                    Spacer()
                    if isLive { LiveBadge() }
                }
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let matchLabel {
                    Text(matchLabel)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: Theme.Spacing.xxs) {
                    if let countryFlag { Text(countryFlag) }
                    Text([quality, isConfirmed ? "Confirmed" : "Possible match"].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(isConfirmed ? Theme.textSecondary : Theme.textTertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.Typography.caption)
                .lineLimit(1)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(isLive ? Theme.live.opacity(0.4) : Theme.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isLive ? "Watch live" : "Watch when live"), \(title). \(matchLabel.map { "\($0). " } ?? "")\(isConfirmed ? "Confirmed" : "Possible match").")
    }

    private var newBadge: some View {
        Text("NEW")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.live, in: Capsule())
            .foregroundStyle(.white)
    }
}

struct AlternateStreamsButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("••• \(count) more broadcast\(count == 1 ? "" : "s")")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.accessibleAccent)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Game info card

struct GameInfoCard: View {
    let items: [GameInfoItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Image(systemName: item.icon)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.primary)
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.textPrimary)
                            if let secondary = item.secondary {
                                Text(secondary)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if index < items.count - 1 {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}
