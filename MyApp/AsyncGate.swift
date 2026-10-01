import Foundation

/// A simple async semaphore: caps how many callers can be inside an `acquire()`/`release()`
/// pair at once, queuing the rest in FIFO order. Swift has no built-in async semaphore type.
actor AsyncGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(0, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
