import Foundation

nonisolated extension Match {
    /// Whether fans of this sport read the home side first ("Arsenal v Chelsea") rather than the
    /// away side first ("Lakers @ Celtics").
    var listsHomeSideFirst: Bool { league.group == .soccer }

    /// The two sides in the order they should be shown, left to right.
    var leadingSide: TeamSide { listsHomeSideFirst ? home : away }
    var trailingSide: TeamSide { listsHomeSideFirst ? away : home }
}
