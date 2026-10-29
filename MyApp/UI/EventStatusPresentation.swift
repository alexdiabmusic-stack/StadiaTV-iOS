import Foundation

nonisolated extension BannerGameStatus {
    /// Legacy Match carries provider status text alongside its three-state summary.
    /// Resolve exceptional states in one place until callers carry native status directly.
    init(presentationOf match: Match) {
        let detail = match.statusDetail.lowercased()
        if detail.contains("postpon") { self = .postponed }
        else if detail.contains("cancel") { self = .cancelled }
        else if detail.contains("suspend") { self = .suspended }
        else if detail.contains("delay") { self = .delayed }
        else { self.init(gameState: match.state) }
    }

    var displayTitle: LocalizedStringResource {
        switch self {
        case .scheduled, .pregame: "Upcoming"
        case .live: "Live"
        case .delayed: "Delayed"
        case .postponed: "Postponed"
        case .suspended: "Suspended"
        case .final: "Final"
        case .cancelled: "Cancelled"
        case .unknown: "Status unavailable"
        }
    }
}
