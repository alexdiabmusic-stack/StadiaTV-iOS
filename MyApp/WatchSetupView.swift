import SwiftUI

/// Screen 3 of 3 — Connect a playlist source.
struct WatchSetupView: View {
    let onSkip: () -> Void

    @EnvironmentObject private var playlistStore: PlaylistStore
    @State private var showingAdd = false
    @State private var editingPlaylist: Playlist?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepHeader(
                step: .watch,
                title: "Add your streams",
                subtitle: "Connect an M3U playlist or Xtream account to start watching."
            )

            ScrollView {
                VStack(spacing: 16) {
                    if !playlistStore.playlists.isEmpty {
                        connectedSection
                    }

                    sourceCards

                    Button {
                        onSkip()
                    } label: {
                        Text("Set up later")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: sizeClass == .regular ? 600 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddPlaylistView { playlistStore.add($0) }
        }
        .sheet(item: $editingPlaylist) { playlist in
            AddPlaylistView(initialPlaylist: playlist) { playlistStore.add($0) }
        }
    }

    // MARK: - Connected playlists

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)

            ForEach(playlistStore.playlists) { playlist in
                ConnectedPlaylistRow(playlist: playlist) {
                    editingPlaylist = playlist
                }
            }
        }
    }

    // MARK: - Source cards

    private var sourceCards: some View {
        VStack(spacing: 12) {
            SourceTypeCard(
                icon: "link",
                title: "M3U Playlist",
                description: "Connect using a URL from your subscription service.",
                action: { showingAdd = true }
            )

            SourceTypeCard(
                icon: "person.badge.key.fill",
                title: "Xtream Account",
                description: "Login with your Xtream Codes portal credentials.",
                action: { showingAdd = true }
            )
        }
    }
}

// MARK: - Source type card

private struct SourceTypeCard: View {
    let icon: String
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title)")
    }
}

// MARK: - Connected playlist row

private struct ConnectedPlaylistRow: View {
    let playlist: Playlist
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(playlist.kind == .m3u ? "M3U Playlist" : "Xtream Account")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(playlist.name)")
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.green.opacity(0.3))
        )
    }
}
