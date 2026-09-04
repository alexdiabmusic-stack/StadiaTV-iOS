import SwiftUI
import UIKit

// MARK: - LaunchAnimationView

/// Full-screen brand overlay that plays on cold launch and transitions
/// the STADIA TV wordmark into the Home navigation-bar header position.
///
/// Layout strategy
/// ───────────────
/// • The view covers the entire screen (ignores safe area) so it aligns
///   with the native iOS launch screen without any gap or flash.
/// • `BrandMark` uses the *exact same* font as the toolbar BrandMark,
///   scaled 2× for the splash presentation.  When the animation ends, the
///   overlay logo is at scale 1× over the nav-bar centre — pixel-aligned
///   with the toolbar logo that becomes visible at `phase == .home`.
///
/// Animation choreography
/// ──────────────────────
///  0.00 s  White logo centred (matches native launch screen background).
///  0.20 s  TV starts animating white → Stadia blue (easeInOut 0.45 s).
///  0.65 s  Fully branded wordmark at rest. Startup pipeline is running.
///  1.10 s  Minimum brand duration met.
///  ~1.25 s Logo flies from centre → nav-bar header (0.65 s, custom ease).
///           Background fades to transparent (0.5 s easeInOut, 0.1 s delay).
///           Home sections begin rising upward while logo is still moving.
///           Tab-bar cover fades last (0.35 s, 0.4 s delay) so the bar
///           never appears against a blank content area.
///  ~1.9 s  Overlay removed; toolbar BrandMark takes over in same frame.
struct LaunchAnimationView: View {
    @EnvironmentObject private var coordinator: StartupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Splash scale relative to the standard toolbar BrandMark (which is scale 1.0).
    private static let splashScale: CGFloat = 2.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                splashBackground
                    .ignoresSafeArea()

                // Separate cover for the tab-bar area so it lingers longer than
                // the main background, preventing the tab bar from appearing against
                // a still-blank content area. Skipped when Reduce Motion is on.
                if !reduceMotion {
                    tabBarCover
                }

                animatedBrandMark(in: geo)
            }
        }
        .ignoresSafeArea()
        // Never intercept touches — Home is usable even while the overlay is present.
        .allowsHitTesting(false)
    }

    // MARK: - Background

    private var splashBackground: some View {
        // Use the exact same colour as Theme.background (dark: #080A0F) so
        // the transition from the native launch screen is a single seamless frame.
        // Delayed 0.1 s so content sections have already begun rising before the
        // background lifts, creating the "emerging from dark" feel.
        Color(hex: 0x080A0F)
            .opacity(backgroundOpacity)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.25)
                    : .easeInOut(duration: 0.5).delay(0.1),
                value: coordinator.isTransitioningToHome
            )
    }

    private var backgroundOpacity: Double {
        coordinator.isTransitioningToHome ? 0.0 : 1.0
    }

    // MARK: - Tab-bar cover

    /// Pinned strip that covers the tab-bar + home-indicator region. Fades later
    /// than the main background so the tab bar only appears once content is visible.
    private var tabBarCover: some View {
        VStack(spacing: 0) {
            Spacer()
            Color(hex: 0x080A0F)
                .frame(height: tabBarCoverHeight())
                .opacity(coordinator.isTransitioningToHome ? 0 : 1)
                .animation(.easeOut(duration: 0.35).delay(0.4), value: coordinator.isTransitioningToHome)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func tabBarCoverHeight() -> CGFloat {
        let bottomInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.bottom ?? 34
        return 49 + bottomInset
    }

    // MARK: - Brand Mark

    @ViewBuilder
    private func animatedBrandMark(in geo: GeometryProxy) -> some View {
        BrandMark(tvColor: tvColor)
            .scaleEffect(logoScale)
            .offset(y: logoOffset(in: geo))
            .animation(
                // No position/scale animation when Reduce Motion is enabled —
                // the colour change still plays; the overlay simply fades out.
                reduceMotion ? nil : .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.65),
                value: coordinator.isTransitioningToHome
            )
    }

    // MARK: - Animated properties

    /// The "TV" colour.  Changes from white → Stadia blue when
    /// `coordinator.phase` becomes `.colorizingTV`.  Because the coordinator
    /// wraps the phase mutation in `withAnimation(.easeInOut(duration: 0.45))`,
    /// SwiftUI interpolates the Color in that same transaction — no extra
    /// state needed here.
    private var tvColor: Color {
        coordinator.phase == .brandWhite ? .white : Theme.accent
    }

    private var logoScale: CGFloat {
        coordinator.isTransitioningToHome ? 1.0 : Self.splashScale
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
