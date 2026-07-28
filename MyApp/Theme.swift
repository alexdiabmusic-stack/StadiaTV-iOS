import SwiftUI
import UIKit

/// StadiaTV visual language — a bright blue accent over a backdrop that
/// adapts to the user's chosen appearance (dark by default, light optional).
enum Theme {
    static let background = dynamic(dark: 0x06070A, light: 0xF4F5F7)
    static let surface = dynamic(dark: 0x12141A, light: 0xFFFFFF)
    static let surfaceElevated = dynamic(dark: 0x1B1E27, light: 0xE8EAEF)
    static let accent = Color(hex: 0x2F81F7)
    static let live = Color(hex: 0xFF4D4F)
    static let textPrimary = dynamic(dark: 0xF2F5F8, light: 0x15181D)
    static let textSecondary = dynamic(dark: 0x8B929C, light: 0x5C6470)
    static let hairline = dynamic(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.08, lightAlpha: 0.08)

    /// Resolves to a different color per interface style so the whole app
    /// follows the appearance picked in Settings.
    private static func dynamic(dark: UInt, light: UInt, darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(Color(hex: light, alpha: lightAlpha))
                : UIColor(Color(hex: dark, alpha: darkAlpha))
        })
    }

    /// True on iPad, where text and icons render larger to suit the bigger screen.
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad

    /// Scales a fixed icon or logo dimension up on iPad.
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
    /// `scrollContentBackground(.hidden)` where available; tvOS lacks the modifier.
    func hidesScrollContentBackground() -> some View {
        #if os(tvOS)
        self
        #else
        scrollContentBackground(.hidden)
        #endif
    }

    /// `navigationBarTitleDisplayMode(.inline)` where available; tvOS lacks the modifier.
    func inlineNavigationTitle() -> some View {
        #if os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The "STADIA TV" wordmark used in navigation bars.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("STADIA")
                .foregroundStyle(Theme.textPrimary)
            Text("TV")
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: Theme.scaled(20), weight: .heavy))
        .tracking(1)
    }
}
