import ActivityKit
import BannerSharedKit
import WidgetKit
import SwiftUI

/// Renders Banner's single game Live Activity. `LiveActivityManager` (main app target)
/// decides which game gets tracked; this view only renders whatever `ContentState` it's
/// given — no sports/priority logic lives here.
struct BannerGameLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GameLiveActivityAttributes.self) { context in
            BannerLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.homeAbbreviation).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.awayAbbreviation).font(.headline)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.state.homeScore) — \(context.state.awayScore)").font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.state.statusDetail) · \(context.state.stateLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Text(context.attributes.homeAbbreviation).font(.caption2.bold())
            } compactTrailing: {
                Text("\(context.state.homeScore)-\(context.state.awayScore)").font(.caption2.bold())
            } minimal: {
                Text(context.state.stateLabel == "LIVE" ? "🔴" : "")
            }
            .widgetURL(URL(string: "banner://game/\(context.attributes.matchID)"))
        }
    }
}

private struct BannerLiveActivityLockScreenView: View {
    let context: ActivityViewContext<GameLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(context.attributes.homeName) vs \(context.attributes.awayName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text("\(context.attributes.homeAbbreviation) \(context.state.homeScore) — \(context.attributes.awayAbbreviation) \(context.state.awayScore)")
                    .font(.title2.bold())
                Spacer()
                Text(context.state.stateLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(context.state.stateLabel == "LIVE" ? Color.red : Color.gray, in: Capsule())
                    .foregroundStyle(.white)
            }
            Text(context.state.statusDetail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .widgetURL(URL(string: "banner://game/\(context.attributes.matchID)"))
    }
}
