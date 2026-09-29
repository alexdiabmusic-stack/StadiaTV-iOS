import SwiftUI
import UIKit

/// BannerTV visual language — neutral foundation with colour reserved for meaning.
enum Theme {
    static let background       = dynamic(dark: 0x080A0F, light: 0xF4F5F7)
    static let surface          = dynamic(dark: 0x12151C, light: 0xFFFFFF)
    static let surfaceElevated  = dynamic(dark: 0x181C24, light: 0xE8EAEF)
    static let accent           = Color(hex: 0x3B82F6)
    static let accessibleAccent = dynamic(dark: 0x60A5FA, light: 0x1D4ED8)
    static let actionFill       = Color(hex: 0x1D4ED8)
    static let live             = Color(hex: 0xFF4D5E)
    static let starting         = Color(hex: 0xF5B942)
    static let upcoming         = Color(hex: 0x31C978)
    static let textPrimary      = dynamic(dark: 0xF7F8FA, light: 0x15181D)
    static let textSecondary    = dynamic(dark: 0x9BA3B2, light: 0x5C6470)
    static let textTertiary     = dynamic(dark: 0x636B7A, light: 0x8F979F)
    static let hairline         = dynamic(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.09, lightAlpha: 0.09)

    private static func dynamic(dark: UInt, light: UInt, darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(Color(hex: light, alpha: lightAlpha))
                : UIColor(Color(hex: dark, alpha: darkAlpha))
        })
    }

    static let isPad = UIDevice.current.userInterfaceIdiom == .pad

    // MARK: Spacing (4-pt grid)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: Corner radius

    enum Radius {
        /// Chips, small buttons.
        static let sm: CGFloat = 8
        /// Rows, inputs.
        static let md: CGFloat = 12
        /// Cards, sheets.
        static let lg: CGFloat = 16
        /// Hero surfaces.
        static let xl: CGFloat = 24
    }

    // MARK: Typography
    // Built on Dynamic Type text styles so everything scales with the user's text size.
    // Weights are semibold/bold only.

    enum Typography {
        static let display = Font.system(.largeTitle, weight: .bold)
        static let title = Font.system(.title2, weight: .bold)
        static let headline = Font.system(.headline, weight: .semibold)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let caption = Font.system(.caption, weight: .semibold)
        /// Use with `.overlineStyle()` for the uppercase tracking.
        static let overline = Font.system(.caption2, weight: .semibold)

        /// Monospaced-digit variants for scores, clocks and times.
        static let titleDigits = Font.system(.title2, weight: .bold).monospacedDigit()
        static let headlineDigits = Font.system(.headline, weight: .semibold).monospacedDigit()
        static let captionDigits = Font.system(.caption, weight: .semibold).monospacedDigit()
    }

    // MARK: Materials

    enum Materials {
        /// Player chrome: ultra-thin material over a 35 % black tint.
        static let playerChromeTint = Color.black.opacity(0.35)
    }

    // MARK: Motion

    enum Motion {
        /// State changes (toggles, selection, small layout shifts).
        /// With Reduce Motion on, becomes a short fade-like ease with no spring travel.
        static var snappy: Animation {
            UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.15) : .snappy(duration: 0.25)
        }
        /// Presentations (sheets, overlays, panels).
        static var smooth: Animation {
            UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.2) : .smooth(duration: 0.35)
        }

        /// `animation` unless Reduce Motion is on.
        static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
            reduceMotion ? nil : animation
        }
    }

    // MARK: Palette
    // Named colours that used to be inline hex literals. Brand/team/sport colours live here.

    enum Palette {
        static let highlightYellow = Color(hex: 0xFFCC00)
        static let positive = Color(hex: 0x3DBE6B)
        static let systemGreen = Color(hex: 0x34C759)
        static let gold = Color(hex: 0xFFD700)
        static let orange = Color(hex: 0xFF6B35)
        static let raspberry = Color(hex: 0xE24A6B)
        static let amber = Color(hex: 0xE0A83D)
        static let green = Color(hex: 0x37C871)
        static let graphite = Color(hex: 0x2A2C31)
        static let nearBlack = Color(hex: 0x080A0F)
        static let midnight = Color(hex: 0x060D1B)
        static let systemRed = Color(hex: 0xFF453A)
        static let sunflower = Color(hex: 0xF5C842)
        static let cloud = Color(hex: 0xF4F5F7)
        static let marigold = Color(hex: 0xE8A020)
        static let carrot = Color(hex: 0xE67E22)
        static let mist = Color(hex: 0xE0E2E8)
        static let frost = Color(hex: 0xD7E4EF)
        static let skyBlue = Color(hex: 0x5B9CF5)
        static let clay = Color(hex: 0x5A3520)
        static let mint = Color(hex: 0x52C28E)
        static let cornflower = Color(hex: 0x4A90E2)
        static let turf = Color(hex: 0x3B6E2A)
        static let teal = Color(hex: 0x30B0C7)
        static let cobalt = Color(hex: 0x2458A6)
        static let pitch = Color(hex: 0x234329)
        static let forest = Color(hex: 0x1B3B2A)
        static let fieldGreen = Color(hex: 0x1A9E40)
        static let royal = Color(hex: 0x1A6FE8)
        static let slate = Color(hex: 0x181C24)
        static let deepGreen = Color(hex: 0x153B2C)
        static let navy = Color(hex: 0x0D1F3C)
        static let abyss = Color(hex: 0x0A1628)
    }

    static func scaled(_ base: CGFloat) -> CGFloat {
        isPad ? base * 1.4 : base
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension View {
    /// Overline text: small, semibold, uppercase with 0.6 pt tracking.
    func overlineStyle() -> some View {
        font(Theme.Typography.overline)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    @ViewBuilder
    func platformRowActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        #if os(tvOS)
        contextMenu(menuItems: actions)
        #else
        swipeActions(edge: .trailing, allowsFullSwipe: true, content: actions)
        #endif
    }

    @ViewBuilder
    func platformGroupedList() -> some View {
        #if os(tvOS)
        listStyle(.plain)
        #else
        listStyle(.insetGrouped)
        #endif
    }

    func hidesScrollContentBackground() -> some View {
        #if os(tvOS)
        self
        #else
        scrollContentBackground(.hidden)
        #endif
    }

    func inlineNavigationTitle() -> some View {
        #if os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct BrandMark: View {
    /// Pass `.white` during the launch animation's initial white-logo state;
    /// any other value (including the default `Theme.accent`) shows the full-colour logo.
    var tvColor: Color = Theme.accent

    private var isAllWhite: Bool { tvColor == .white }

    var body: some View {
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
        .frame(height: Theme.scaled(36))
    }
}
