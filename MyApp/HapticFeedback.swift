#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform haptic/trackpad feedback. On iOS this drives the standard
/// UIFeedbackGenerator family; on macOS it drives NSHapticFeedbackManager
/// (felt on Force Touch trackpads, silently a no-op otherwise). No-op on tvOS.
enum Haptic {
    enum ImpactStyle {
        case light, medium, heavy

        #if os(iOS)
        var uiKit: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light: return .light
            case .medium: return .medium
            case .heavy: return .heavy
            }
        }
        #endif
    }

    static func impact(_ style: ImpactStyle = .light) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: style.uiKit).impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        #endif
    }

    static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        #endif
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        #endif
    }

    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        #endif
    }
}
