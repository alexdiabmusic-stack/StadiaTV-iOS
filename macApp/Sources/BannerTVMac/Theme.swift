import AppKit
import CoreText
import SwiftUI

/// BannerTV's look, taken from the iPhone app (its design tokens): near-black surfaces, JetBrains Sans, white primary
/// buttons, and the cool blue accent used sparingly.
enum Theme {
    static let background = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0D / 255)
    static let surface = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)
    static let surfaceRaised = Color(red: 0x24 / 255, green: 0x24 / 255, blue: 0x24 / 255)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.70)
    static let textMuted = Color.white.opacity(0.52)
    static let hairline = Color.white.opacity(0.10)
    static let accentStart = Color(red: 0x4D / 255, green: 0xE3 / 255, blue: 0xFF / 255)
    static let accentEnd = Color(red: 0x31 / 255, green: 0x85 / 255, blue: 0xF5 / 255)
    static let imdb = Color(red: 0xF5 / 255, green: 0xC5 / 255, blue: 0x18 / 255)
    static var accent: LinearGradient {
        LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Radii from the phone's tokens.
    static let radiusPoster: CGFloat = 12
    static let radiusCard: CGFloat = 20
    static let radiusButton: CGFloat = 16
    /// Side margin of every page.
    static let gutter: CGFloat = 40

    /// The app's fonts are bundled; they are registered once at launch.
    static func registerFonts() {
        let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        for name in ["jetbrains_sans_regular", "jetbrains_sans_semibold", "jetbrains_sans_bold"] {
            if let url = dir?.appendingPathComponent("\(name).ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
}

enum JB { case regular, semibold, bold }

extension Font {
    /// JetBrains Sans, the phone app's typeface (falls back to the system font if the files are missing).
    static func jb(_ size: CGFloat, _ weight: JB = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = "JetBrainsSans-Regular"
        case .semibold: name = "JetBrainsSans-SemiBold"
        case .bold: name = "JetBrainsSans-Bold"
        }
        if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: weight == .bold ? .bold : weight == .semibold ? .semibold : .regular)
    }
}

// MARK: - Surfaces

extension View {
    /// A text field in the phone's rounded style (use with `.textFieldStyle(.plain)`).
    func fieldStyle() -> some View {
        font(.jb(14)).padding(.horizontal, 16).frame(height: 40)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    /// The frosted pill used by the navigation bar and floating controls.
    func glassCapsule() -> some View {
        background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    /// Posters and cards lift slightly under the pointer.
    func hoverLift(_ scale: CGFloat = 1.035) -> some View { modifier(HoverLift(scale: scale)) }
}

private struct HoverLift: ViewModifier {
    let scale: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 16, y: 10)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Buttons

enum PillKind { case primary, secondary }

/// The white Play pill and the translucent My List pill from the phone's hero.
struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .primary
    var height: CGFloat = 52

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.jb(17, .semibold))
            .foregroundStyle(kind == .primary ? Color.black : Color.white)
            .padding(.horizontal, 28)
            .frame(height: height)
            .background(kind == .primary ? Color.white : Color.white.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(kind == .primary ? 0 : 0.12), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A round icon button (back, save, more).
struct CircleButtonStyle: ButtonStyle {
    var filled = false
    var size: CGFloat = 52

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(filled ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(filled ? Color.white.opacity(0.95) : Color.white.opacity(0.14), in: Circle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct GlassCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .background(Color.black.opacity(0.3), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Small rounded chip (filters, days, seasons).
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.jb(14, .semibold)).padding(.horizontal, 16).padding(.vertical, 8)
                .background(selected ? Color.white : Color.white.opacity(0.10), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section header and images

/// "Continue Watching" and friends: a big title and, optionally, the round chevron that opens the full list.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.jb(24, .semibold)).foregroundStyle(.white)
                if let subtitle { Text(subtitle).font(.jb(13)).foregroundStyle(Theme.textMuted) }
            }
            Spacer()
            if let onMore {
                Button(action: onMore) { Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

/// An image that fades in once loaded, on the card's own placeholder colour.
struct RemoteImage: View {
    let url: URL?
    var fill = true

    var body: some View {
        ZStack {
            Theme.surface
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
                }
            }
        }
    }
}

/// A horizontal row of cards with the page gutter on both sides.
struct HShelf<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) { content }
                .padding(.horizontal, Theme.gutter).padding(.vertical, 6)
        }
    }
}

/// Text outlined in a thin line, with the page colour inside (the Top 10 numerals).
struct OutlinedNumeral: View {
    let text: String
    var size: CGFloat = 150

    var body: some View {
        let offsets: [CGSize] = [(-2, 0), (2, 0), (0, -2), (0, 2), (-1.5, -1.5), (1.5, 1.5), (-1.5, 1.5), (1.5, -1.5)].map { CGSize(width: $0.0, height: $0.1) }
        ZStack {
            ForEach(0..<offsets.count, id: \.self) { i in
                Text(text).font(.jb(size, .bold)).foregroundStyle(Color.white.opacity(0.55)).offset(offsets[i])
            }
            Text(text).font(.jb(size, .bold)).foregroundStyle(Theme.background)
        }
    }
}

/// An integration's app icon (Serializd, Letterboxd) from the bundle's Integrations folder, in a rounded tile.
struct IntegrationIcon: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Integrations/\(name).png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
