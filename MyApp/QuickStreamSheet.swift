#if os(iOS)
import SwiftUI

/// Half-sheet that lists the top ranked streams for a match so the user can
/// jump straight into playback without opening the full Match Detail page.
struct QuickStreamSheet: View {
    let match: Match
    let sources: [RankedSource]
    @Environment(\.dismiss) private var dismiss
    @State private var playingChannel: Channel?

    var body: some View {
        NavigationStack {
            Group {
                if sources.isEmpty {
                    ContentUnavailableView(
                        "No Streams Found",
                        systemImage: "play.slash",
                        description: Text("No matching channels were found for this match.")
                    )
                } else {
                    List(Array(sources.prefix(8))) { source in
                        sourceRow(source)
                            .listRowBackground(Theme.surface)
                            .listRowSeparatorTint(Theme.hairline)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                }
            }
            .navigationTitle(match.shortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(match.league.shortName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $playingChannel) { ch in
                PlayerView(channel: ch, zapChannels: [ch], currentIndex: 0)
            }
        }
    }

    private func sourceRow(_ source: RankedSource) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.channel.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Group {
                    if let prog = source.epgProgramme {
                        Text(prog.title)
                    } else if let strongest = source.strongestEvidence {
                        Text(strongest.displayLabel)
                            .foregroundStyle(evidenceLabelColor(strongest))
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
            Spacer()
            Button {
                playingChannel = source.channel
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func evidenceLabelColor(_ evidence: StreamEvidenceCategory) -> Color {
        switch evidence {
        case .guideListsMatch:      return Theme.accent
        case .broadcastRightsMatch: return Theme.accent.opacity(0.8)
        default:                    return Theme.textSecondary
        }
    }
}
#endif
