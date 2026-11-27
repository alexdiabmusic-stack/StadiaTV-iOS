import SwiftUI

/// The destinations. The phone's tab bar has Home, Live TV, Search, Sports and Library; Explore and the Guide live inside
/// Home and Live TV, and Settings opens from the profile button.
enum AppSection: String, CaseIterable, Identifiable {
    case home, explore, search, library, liveTV, guide, sports, playbackTest, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .explore: "Explore"
        case .search: "Search"
        case .library: "Library"
        case .liveTV: "Live TV"
        case .guide: "Guide"
        case .sports: "Sports"
        case .playbackTest: "Player Test"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .explore: "sparkles.rectangle.stack"
        case .search: "magnifyingglass"
        case .library: "tray.full.fill"
        case .liveTV, .guide: "tv"
        case .sports: "soccerball"
        case .playbackTest: "play.rectangle"
        case .settings: "gearshape"
        }
    }

    /// Keyboard shortcut digit (⌘1 ... ⌘5) for the main destinations.
    var shortcutDigit: Character? {
        switch self {
        case .home: "1"
        case .liveTV: "2"
        case .search: "3"
        case .sports: "4"
        case .library: "5"
        default: nil
        }
    }

    /// Same order as the phone's tab bar.
    static var main: [AppSection] { [.home, .liveTV, .search, .sports, .library] }
    static var showsDeveloperTools: Bool { CommandLine.arguments.contains("--dev") }

    /// The tab a section belongs to (Explore is part of Home, the Guide part of Live TV).
    var tab: AppSection {
        switch self {
        case .explore: .home
        case .guide: .liveTV
        default: self
        }
    }
}
