import SwiftUI

extension AdaptiveLayoutContext {
    /// True when content should sit in two columns: the window is wide enough and the fold, if
    /// any, isn't a tabletop hinge (which splits the screen into a top and bottom half instead).
    var prefersTwoPane: Bool { isExpanded && foldAxis != .horizontal }

    /// Width of the vertical fold the columns must straddle, so no content is drawn under it.
    var verticalFoldGap: CGFloat {
        guard foldAxis == .vertical, let division = divisions.first else { return 0 }
        return division.width
    }
}

/// Lays `primary` and `secondary` out as two scrolling-friendly columns when the window is
/// expanded, and stacks them in order (primary first) otherwise. The columns split the width
/// evenly around the fold gap, so on a book-posture Duo each column fills one half of the display.
///
/// Pass `hasSecondary: false` when the secondary column would be empty, so the primary column
/// keeps the full width instead of leaving half the screen blank.
///
/// Place it inside the screen's `ScrollView`; both columns scroll together.
struct AdaptiveTwoPane<Primary: View, Secondary: View>: View {
    @Environment(\.adaptiveLayout) private var layout
    let spacing: CGFloat
    let columnSpacing: CGFloat
    let hasSecondary: Bool
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    init(
        spacing: CGFloat = 28,
        columnSpacing: CGFloat = 24,
        hasSecondary: Bool = true,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self.spacing = spacing
        self.columnSpacing = columnSpacing
        self.hasSecondary = hasSecondary
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        if layout.prefersTwoPane && hasSecondary {
            HStack(alignment: .top, spacing: max(columnSpacing, layout.verticalFoldGap)) {
                LazyVStack(alignment: .leading, spacing: spacing) { primary() }
                    .frame(maxWidth: .infinity, alignment: .top)
                LazyVStack(alignment: .leading, spacing: spacing) { secondary() }
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: spacing) {
                primary()
                secondary()
            }
        }
    }
}
