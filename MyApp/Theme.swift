import SwiftUI

/// StadiaTV visual language — dark backdrop with a bright blue accent.
enum Theme {
    static let background = Color(hex: 0x06070A)
    static let surface = Color(hex: 0x12141A)
    static let surfaceElevated = Color(hex: 0x1B1E27)
    static let accent = Color(hex: 0x2F81F7)
    static let live = Color(hex: 0xFF4D4F)
    static let textPrimary = Color(hex: 0xF2F5F8)
    static let textSecondary = Color(hex: 0x8B929C)
    static let hairline = Color.white.opacity(0.08)
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

/// The "STADIA TV" wordmark used in navigation bars.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("STADIA")
                .foregroundStyle(Theme.textPrimary)
            Text("TV")
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: 20, weight: .heavy))
        .tracking(1)
    }
}
