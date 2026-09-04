import SwiftUI
import UIKit

/// StadiaTV visual language — neutral foundation with colour reserved for meaning.
enum Theme {
    static let background       = dynamic(dark: 0x080A0F, light: 0xF4F5F7)
    static let surface          = dynamic(dark: 0x12151C, light: 0xFFFFFF)
    static let surfaceElevated  = dynamic(dark: 0x181C24, light: 0xE8EAEF)
    static let accent           = Color(hex: 0x3B82F6)
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
    /// Color for the "TV" portion. Defaults to Stadia blue.
    /// Pass `.white` during the launch animation's initial white-logo state.
    var tvColor: Color = Theme.accent

    var body: some View {
        HStack(spacing: 0) {
            Text("STADIA")
                .foregroundStyle(Theme.textPrimary)
            Text("TV")
                .foregroundStyle(tvColor)
        }
        .font(.system(size: Theme.scaled(20), weight: .heavy))
        .tracking(1)
    }
}
