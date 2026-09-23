import SwiftUI

struct NBAPlayRow: View {
    let play: NBAPlayEvent
    var body: some View {
        VStack(alignment: .leading, spacing: play.priority == .compact ? 2 : 6) {
            HStack(alignment: .top) {
                Text(play.title).font(titleFont)
                Spacer()
                if let clock = play.clockText { Text(clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let subtitle = play.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, play.priority == .compact ? 4 : play.priority == .medium ? 8 : 12)
        .padding(.horizontal, play.isPeriodBoundary ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(play.priority == .high ? Theme.surfaceElevated : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if play.isPeriodBoundary { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 1) }
        }
    }
    private var titleFont: Font {
        switch play.priority {
        case .high: return .headline
        case .medium: return .subheadline.bold()
        case .compact: return .subheadline
        }
    }
}
