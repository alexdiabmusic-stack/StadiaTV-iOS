import SwiftUI
import AVKit

/// Presents a channel's stream in the native AVPlayer UI.
struct PlayerView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            StreamTile(channel: channel, isPrimary: true, showsChrome: false)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            PlayerCloseButton { dismiss() }
                .padding()
        }
        .overlay(alignment: .bottom) {
            PlayerSourceBar(channel: channel)
                .padding(16)
        }
    }
}

/// Plays up to four channels at once with one primary audio source.
struct MultiScreenPlayerView: View {
    let channels: [Channel]
    @Environment(\.dismiss) private var dismiss
    @State private var layout: MultiScreenLayout = .two
    @State private var primaryChannelID: String?

    private var visibleChannels: [Channel] {
        Array(channels.prefix(layout.capacity))
    }

    private var activePrimaryID: String? {
        if let primaryChannelID, visibleChannels.contains(where: { $0.id == primaryChannelID }) {
            return primaryChannelID
        }
        return visibleChannels.first?.id
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                header
                screenGrid
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .onAppear {
            layout = channels.count >= 4 ? .four : .two
            primaryChannelID = channels.first?.id
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PlayerCloseButton { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                BrandMark()
                    .scaleEffect(0.82, anchor: .leading)
                    .frame(height: 18, alignment: .leading)
                Text("Multiscreen")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
            }

            Spacer()

            Picker("Layout", selection: $layout) {
                ForEach(MultiScreenLayout.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            .disabled(channels.count < 4)
        }
    }

    @ViewBuilder private var screenGrid: some View {
        switch layout {
        case .two:
            VStack(spacing: 10) {
                ForEach(visibleChannels) { channel in
                    tile(for: channel)
                }
                if visibleChannels.count == 1 {
                    emptyTile(title: "Add another source")
                }
            }
        case .four:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(visibleChannels) { channel in
                    tile(for: channel)
                }
                ForEach(visibleChannels.count..<4, id: \.self) { _ in
                    emptyTile(title: "Source slot")
                }
            }
        }
    }

    private func tile(for channel: Channel) -> some View {
        let isPrimary = channel.id == activePrimaryID
        return Button {
            primaryChannelID = channel.id
        } label: {
            StreamTile(channel: channel, isPrimary: isPrimary, showsChrome: true)
                .frame(maxWidth: .infinity)
                .aspectRatio(layout.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isPrimary ? Theme.accent : Theme.hairline, lineWidth: isPrimary ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func emptyTile(title: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.surface)
            .aspectRatio(layout.aspectRatio, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.title2)
                    Text(title)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private enum MultiScreenLayout: String, CaseIterable, Identifiable {
    case two
    case four

    var id: String { rawValue }
    var capacity: Int { self == .two ? 2 : 4 }
    var title: String { self == .two ? "2" : "4" }
    var systemImage: String { self == .two ? "rectangle.split.2x1" : "rectangle.grid.2x2" }
    var aspectRatio: CGFloat { self == .two ? 16 / 9 : 1 }
}

private struct StreamTile: View {
    let channel: Channel
    let isPrimary: Bool
    let showsChrome: Bool

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayer(player: player)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("Source unavailable")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsChrome {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isPrimary ? Theme.accent : Theme.textSecondary)
                        .frame(width: 7, height: 7)
                    Text(isPrimary ? "PRIMARY" : "MUTED")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.62), in: Capsule())
                .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showsChrome {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(channel.group ?? channel.playlistName)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.74)], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: isPrimary) { _, newValue in
            player?.isMuted = !newValue
        }
    }

    private func start() {
        guard player == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let asset = AVURLAsset(url: channel.streamURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.isMuted = !isPrimary
        self.player = player

        Task {
            do {
                let playable = try await asset.load(.isPlayable)
                if playable {
                    player.play()
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }

    private func stop() {
        player?.pause()
        player = nil
    }
}

private struct PlayerSourceBar: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.tv.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(channel.group ?? channel.playlistName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("LIVE")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.live, in: Capsule())
        }
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct PlayerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.66), in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}
