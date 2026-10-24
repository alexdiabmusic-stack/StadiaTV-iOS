import SwiftUI

/// Width-driven layout helpers. Layout decisions must follow the space the scene actually has
/// (size classes), never the device idiom: an iPhone Duo is an iPhone in both of its shapes, and
/// any iPhone window can be resized at runtime (fold/unfold, Split View, Stage Manager).
extension View {
    /// Centres content and caps it at `maxWidth` while the window is regular-width, and lets it
    /// fill the window otherwise. Replaces `Theme.isPad ? maxWidth : .infinity`.
    func bannerReadableWidth(_ maxWidth: CGFloat) -> some View {
        modifier(BannerReadableWidth(maxWidth: maxWidth))
    }
}

private struct BannerReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.frame(maxWidth: sizeClass == .regular ? maxWidth : .infinity)
    }
}
