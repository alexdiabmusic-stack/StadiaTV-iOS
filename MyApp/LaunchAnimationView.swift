import SwiftUI
import UIKit

// MARK: - LaunchAnimationView

/// Full-screen brand overlay that plays on cold launch and transitions
/// the BANNER TV wordmark into the Home navigation-bar header position.
///
/// Layout strategy
/// ───────────────
/// • The view covers the entire screen (ignores safe area) so it aligns
///   with the native iOS launch screen without any gap or flash.
/// • `BrandMark` is scaled 4× for the splash presentation so the SVG logo
///   fills the screen at a natural weight.  When the animation ends, the
///   overlay logo is at scale 1× over the nav-bar centre — pixel-aligned
///   with the toolbar logo that becomes visible at `phase == .home`.
///
/// Animation choreography
/// ──────────────────────
///  0.00 s  White logo centred (matches native launch screen background).
///  0.05 s  TV starts animating white → Banner blue (easeInOut 0.3 s).
///  0.35 s  Minimum brand duration met; transitions at once if Home is ready,
///          otherwise waits for it (at most 1.0 s).
///  +0.35 s Logo flies from centre → nav-bar header while the background fades.
///  ~0.7 s  Overlay removed (with cached data); toolbar BrandMark takes over.
struct LaunchAnimationView: View {
    @EnvironmentObject private var coordinator: StartupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Splash scale relative to the standard toolbar BrandMark (which is scale 1.0).
    // 4× gives the SVG wordmark ~88 pt height / ~220 pt width on a standard iPhone —
    // comparable visual weight to the previous text-based logo at 2×.
    private static let splashScale: CGFloat = 4.0


    var body: some View {
        GeometryReader { geo in
            ZStack {
                splashBackground
                    .ignoresSafeArea()

                animatedBrandMark(in: geo)
            }
        }
        .ignoresSafeArea()
        // Never intercept touches — Home is usable even while the overlay is present.
        .allowsHitTesting(false)
    }

    // MARK: - Background

    private var splashBackground: some View {
        Theme.Palette.nearBlack
            .opacity(backgroundOpacity)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.25)
                    : .easeIn(duration: 0.3),
                value: coordinator.isTransitioningToHome
            )
    }

    private var backgroundOpacity: Double {
        coordinator.isTransitioningToHome ? 0.0 : 1.0
    }

    // MARK: - Brand Mark

    @ViewBuilder
    private func animatedBrandMark(in geo: GeometryProxy) -> some View {
        // Render at the full splash height so the SVG is never upscaled.
        // scaleEffect goes 1.0 → (1/splashScale) during the fly-to-navbar transition,
        // scaling down cleanly instead of blurrily scaling up a small rasterised bitmap.
        let splashHeight = Theme.scaled(36) * Self.splashScale
        let isAllWhite = coordinator.phase == .brandWhite

        ZStack {
            Image("BannerTVBlue")
                .resizable()
                .scaledToFit()
                .opacity(isAllWhite ? 0.0 : 1.0)
            Image("BannerTVWhite")
                .resizable()
                .scaledToFit()
                .opacity(isAllWhite ? 1.0 : 0.0)
        }
        .frame(height: splashHeight)
        .scaleEffect(logoScale)
        .offset(y: logoOffset(in: geo))
        .animation(
            // No position/scale animation when Reduce Motion is enabled —
            // the colour change still plays; the overlay simply fades out.
            reduceMotion ? nil : .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.35),
            value: coordinator.isTransitioningToHome
        )
    }

    // MARK: - Animated properties

    // logoScale is 1.0 while logo is on display at full splash size, then shrinks
    // to 1/splashScale to match the toolbar BrandMark at the end of the fly animation.
    private var logoScale: CGFloat {
        coordinator.isTransitioningToHome ? 1.0 / Self.splashScale : 1.0
    }

    /// Vertical offset that places the BrandMark at the nav-bar principal-item Y.
    ///
    /// The ZStack centres the BrandMark at `geo.size.height / 2` (full-screen
    /// centre). `geo.safeAreaInsets.top` reports 0 inside `.ignoresSafeArea()`,
    /// so we read the actual status-bar height from the UIKit window instead.
    private func logoOffset(in geo: GeometryProxy) -> CGFloat {
        guard coordinator.isTransitioningToHome && !reduceMotion else { return 0 }
        let statusBarHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.top ?? geo.safeAreaInsets.top
        let navBarCentreY = statusBarHeight + 22
        let currentCentreY = geo.size.height / 2
        return navBarCentreY - currentCentreY
    }
}
