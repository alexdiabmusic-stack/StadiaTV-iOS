import Foundation
import Network

nonisolated enum SportsConnectivity {
    static func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "BannerTV.sports.connectivity"))
        }
    }
}
