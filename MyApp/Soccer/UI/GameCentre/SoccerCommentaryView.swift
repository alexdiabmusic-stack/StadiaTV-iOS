import SwiftUI

/// Live text feed (Steps 35–38). Structured goals/cards/subs live in the Timeline —
/// this is supplemental narrative only. Newest entries are at the top (matching the
/// provider's own `timestamp:desc` ordering); "Jump to Live" always scrolls back to
/// the top rather than tracking a precise "N new" delta.
struct SoccerCommentaryView: View {
    let entries: [SoccerCommentaryEntry]
    let hasMore: Bool
    let onLoadMore: () async -> Void

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No commentary yet", systemImage: "text.bubble")
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .topTrailing) {
                    List {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                if let minute = entry.minuteDisplay { Text(minute).font(.caption.bold()).foregroundStyle(Theme.textSecondary) }
                                Text(entry.text).font(.subheadline)
                            }.id(entry.id)
                        }
                        if hasMore {
                            Button("Load older commentary") { Task { await onLoadMore() } }
                                .frame(maxWidth: .infinity).font(.subheadline.bold())
                        }
                    }.listStyle(.plain)
                    if let topID = entries.first?.id {
                        Button { withAnimation { proxy.scrollTo(topID, anchor: .top) } } label: {
                            Label("Jump to Live", systemImage: "arrow.up.circle.fill").font(.caption.bold())
                        }.buttonStyle(.borderedProminent).padding(8)
                    }
                }
            }
        }
    }
}
