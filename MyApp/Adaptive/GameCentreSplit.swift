import SwiftUI

/// The shared chrome of a sport's Game Centre: hero, watch card, then the tabbed content.
///
/// Compact windows stack all three, pinned above the tab content. When the window is expanded
/// (an unfolded iPhone Duo, iPad) the hero and watch card move into a scrolling column beside
/// the tabs, so the tab content keeps the full height instead of sharing it with the pinned chrome.
/// The columns straddle a vertical fold rather than drawing under it.
struct GameCentreSplit<Hero: View, Watch: View, Rest: View>: View {
    @Environment(\.adaptiveLayout) private var layout
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let watch: () -> Watch
    @ViewBuilder let rest: () -> Rest

    var body: some View {
        if layout.prefersTwoPane {
            HStack(alignment: .top, spacing: layout.verticalFoldGap) {
                ScrollView {
                    VStack(spacing: 0) {
                        hero()
                        watch()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                VStack(spacing: 0) { rest() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 0) {
                hero()
                watch()
                rest()
            }
        }
    }
}
