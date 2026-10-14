import Foundation

/// Transfers system media controls synchronously so a delayed notification cannot reclaim
/// commands or artwork after another source has started.
@MainActor
final class NowPlayingOwnership {
    static let shared = NowPlayingOwnership()
    private var owner: UUID?
    private var relinquish: (() -> Void)?

    func claim(_ id: UUID, relinquish: @escaping () -> Void) {
        guard owner != id else { return }
        let previous = self.relinquish
        owner = id
        self.relinquish = relinquish
        previous?()
    }

    func owns(_ id: UUID) -> Bool { owner == id }

    @discardableResult
    func release(_ id: UUID) -> Bool {
        guard owner == id else { return false }
        owner = nil
        relinquish = nil
        return true
    }
}
