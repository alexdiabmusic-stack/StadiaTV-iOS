import Foundation

// MARK: - Player Bar Action

/// Identifies a named action slot in the Live player's control bar.
/// The user can configure which of these appear in the bar vs. being hidden.
enum PlayerBarAction: String, Codable, CaseIterable, Identifiable {
    case guide      = "guide"
    case channels   = "channels"
    case recent     = "recent"
    case pip        = "pip"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guide:    return "Guide"
        case .channels: return "Channels"
        case .recent:   return "Recent"
        case .pip:      return "PiP"
        }
    }

    var systemImage: String {
        switch self {
        case .guide:    return "rectangle.grid.1x2.fill"
        case .channels: return "list.bullet"
        case .recent:   return "clock.arrow.circlepath"
        case .pip:      return "pip.fill"
        }
    }

    /// Default visible order in the control bar.
    static let defaultOrder: [PlayerBarAction] = [.guide, .channels, .recent]
}

// MARK: - Player Action Configuration

/// Serialisable configuration of which actions appear in the player control bar
/// and in what order. Stored in UserPreferences.playerBarActions.
///
/// The bar always shows the zap chevrons (when available) and the More button.
/// Up to 3 slots between them are user-configurable.
struct PlayerActionConfiguration {
    /// Ordered list of actions to show in the bar (max 3).
    var barActions: [PlayerBarAction]

    init(rawIDs: [String]) {
        let known = rawIDs.compactMap(PlayerBarAction.init(rawValue:))
        barActions = Array(known.prefix(3))
        // Back-fill defaults for any missing slots so the bar is never empty.
        if barActions.isEmpty { barActions = PlayerBarAction.defaultOrder }
    }

    static var `default`: PlayerActionConfiguration {
        PlayerActionConfiguration(rawIDs: PlayerBarAction.defaultOrder.map(\.rawValue))
    }

    var rawIDs: [String] { barActions.map(\.rawValue) }
}
