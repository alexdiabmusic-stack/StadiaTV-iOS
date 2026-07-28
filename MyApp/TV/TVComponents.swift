#if os(tvOS)
import SwiftUI

// MARK: - TV Match Card

/// Focusable match card sized for horizontal shelves.
struct TVMatchCard: View {
    let match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(match.league.shortName.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                Spacer()
                stateLabel
            }

            HStack(spacing: 0) {
                teamColumn(side: match.away, isWinnerOpponent: match.state == .final && match.home.isWinner)
                centerColumn
                teamColumn(side: match.home, isWinnerOpponent: match.state == .final && match.away.isWinner)
            }
        }
        .padding(18)
        .frame(width: 340, height: 180)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(match.state == .live ? Theme.live.opacity(0.5) : Theme.hairline)
        )
    }

    private func teamColumn(side: TeamSide, isWinnerOpponent: Bool) -> some View {
        VStack(spacing: 6) {
            TVTeamLogo(url: side.logoURL, size: 48)
            Text(side.abbreviation)
                .font(.caption.weight(.bold))
                .foregroundStyle(isWinnerOpponent ? Theme.textSecondary : Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private var centerColumn: some View {
        VStack(spacing: 6) {
            if match.state != .pre {
                Text("\(match.away.score ?? "-")–\(match.home.score ?? "-")")
                    .font(.title2.weight(.black).monospacedDigit())
                    .foregroundStyle(.white)
            } else {
                Text(match.statusDetail)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if match.state == .live {
                Text(match.statusDetail)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.live)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var stateLabel: some View {
        switch match.state {
        case .live:
            TVLiveBadge()
        case .final:
            Text("Final")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surfaceElevated, in: Capsule())
        case .pre:
            EmptyView()
        }
    }
}

// MARK: - TV Hero Card

/// Full-width featured match hero used in the Home tab.
struct TVHeroCard: View {
    let match: Match
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(hex: 0x0A1628), Color(hex: 0x0D1F3C)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            HStack(spacing: 0) {
                heroTeam(side: match.away, dimmed: match.state == .final && match.home.isWinner)
                    .frame(maxWidth: .infinity)

                VStack(spacing: 16) {
                    Text(match.league.name.uppercased())
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)

                    if match.state != .pre {
                        Text("\(match.away.score ?? "0")–\(match.home.score ?? "0")")
                            .font(.system(size: 56, weight: .black, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                    } else {
                        Text("VS")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    if match.state == .live {
                        TVLiveBadge()
                    } else {
                        Text(match.statusDetail)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                    }

                    Label("View Streams", systemImage: match.state == .live ? "play.fill" : "arrow.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                }
                .frame(maxWidth: .infinity)

                heroTeam(side: match.home, dimmed: match.state == .final && match.away.isWinner)
                    .frame(maxWidth: .infinity)
            }
            .padding(52)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(match.state == .live ? Theme.live.opacity(0.5) : Theme.accent.opacity(0.25))
        )
    }

    private func heroTeam(side: TeamSide, dimmed: Bool) -> some View {
        VStack(spacing: 14) {
            TVTeamLogo(url: side.logoURL, size: 108)
            Text(side.displayName)
                .font(.title3.weight(.heavy))
                .foregroundStyle(dimmed ? .white.opacity(0.5) : .white)
                .multilineTextAlignment(.center)
            if let record = side.record {
                Text(record)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - TV Channel Card

struct TVChannelCard: View {
    let channel: Channel
    let isFavorite: Bool

    var body: some View {
        VStack(spacing: 12) {
            TVChannelLogo(url: channel.logoURL, size: 80)
            VStack(spacing: 4) {
                Text(channel.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let group = channel.group, !group.isEmpty {
                    Text(group)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(18)
        .frame(width: 220, height: 200)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isFavorite ? Theme.accent.opacity(0.55) : Theme.hairline)
        )
    }
}

// MARK: - TV Article Card

struct TVArticleCard: View {
    let article: ESPNArticle
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: article.imageURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Theme.surfaceElevated.overlay {
                        Image(systemName: "newspaper")
                            .font(.title)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(width: width, height: width * 0.5625)
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(article.league.shortName.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.accent)
                Text(article.headline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .clipped()
    }
}

// MARK: - TV Team Logo

struct TVTeamLogo: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Image(systemName: "shield.fill")
                    .font(.system(size: size * 0.48))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - TV Channel Logo

struct TVChannelLogo: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Image(systemName: "play.tv.fill")
                    .font(.system(size: size * 0.48))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - TV Shelf Row

/// Titled horizontal shelf of focusable content tiles.
struct TVShelfRow<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.accent
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(title, systemImage: systemImage)
                .font(.title2.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    content()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - TV Live Badge

struct TVLiveBadge: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.live)
                .frame(width: 7, height: 7)
                .opacity(pulsing ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            Text("LIVE")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.live, in: Capsule())
        .onAppear { pulsing = true }
    }
}

// MARK: - TV Empty State

struct TVEmptyState: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }
}

// MARK: - TV Source Tile

/// A focusable channel/stream tile for the match detail streaming section.
struct TVSourceTile: View {
    let channel: Channel
    let score: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                TVChannelLogo(url: channel.logoURL, size: 60)
                VStack(spacing: 3) {
                    Text(channel.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let group = channel.group, !group.isEmpty {
                        Text(group)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Label("Watch", systemImage: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(18)
            .frame(width: 200, height: 200)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(score > 60 ? Theme.accent.opacity(0.4) : Theme.hairline)
            )
        }
        .buttonStyle(.card)
    }
}

#endif
