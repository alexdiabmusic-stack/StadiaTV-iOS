import SwiftUI

/// What the scene's content area looks like right now: its size and any active system-reserved
/// regions (the iPhone Duo's fold division and inner-camera occlusion). Driven by real geometry,
/// never by device identity, so it updates live as the device folds, unfolds or is resized.
nonisolated struct AdaptiveLayoutContext: Equatable, Sendable {
    enum FoldAxis: Equatable, Sendable {
        /// The fold line runs left-to-right (tabletop): content stacks above and below it.
        case horizontal
        /// The fold line runs top-to-bottom (book): content sits beside it.
        case vertical
    }

    var size: CGSize = .zero
    /// Active fold/hinge division frames, in the root view's local space.
    var divisions: [CGRect] = []
    /// Active camera-occlusion frames, in the root view's local space.
    var occlusions: [CGRect] = []

    /// Width at which a second column is genuinely usable. A starting point to tune in the
    /// simulator; layouts should still collapse by available width, not by this alone.
    static let expandedWidth: CGFloat = 700

    var isExpanded: Bool { size.width >= Self.expandedWidth }

    var foldAxis: FoldAxis? {
        guard let division = divisions.first else { return nil }
        return division.width > division.height ? .horizontal : .vertical
    }
}

extension AdaptiveLayoutContext {
    init(proxy: GeometryProxy) {
        size = proxy.size
        // Reserved regions arrived in iOS 27.1; earlier systems simply report none.
        #if os(iOS)
        if #available(iOS 27.1, *) {
            divisions = proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
            occlusions = proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        }
        #endif
    }
}

extension EnvironmentValues {
    @Entry var adaptiveLayout = AdaptiveLayoutContext()
}

extension View {
    /// Publishes `\.adaptiveLayout` for this view's subtree. Apply once, near the scene root.
    func providesAdaptiveLayoutContext() -> some View {
        modifier(AdaptiveLayoutProvider())
    }
}

private struct AdaptiveLayoutProvider: ViewModifier {
    @State private var context = AdaptiveLayoutContext()

    func body(content: Content) -> some View {
        content
            .environment(\.adaptiveLayout, context)
            .onGeometryChange(for: AdaptiveLayoutContext.self) { proxy in
                AdaptiveLayoutContext(proxy: proxy)
            } action: { newValue in
                context = newValue
            }
    }
}
