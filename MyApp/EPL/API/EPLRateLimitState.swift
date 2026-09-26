import Foundation
#if DEBUG
import OSLog
#endif

/// Tracks the PulseLive/SDP gateway's own quota headers (observed ~300 requests per
/// 60 seconds per IP). This does not grant permission to poll anywhere near that —
/// call sites should stay far below it (see EPL polling cadence policy) — it exists
/// purely so DEBUG builds can see the remaining quota and so a 429 can be diagnosed.
actor EPLRateLimitState {
    static let shared = EPLRateLimitState()

    private(set) var limit: Int?
    private(set) var remaining: Int?
    private(set) var resetSeconds: Int?
    private(set) var updatedAt: Date?

    func update(from response: HTTPURLResponse) {
        if let raw = response.value(forHTTPHeaderField: "x-ratelimit-limit"),
           let first = raw.split(separator: ",").first, let value = Int(first.trimmingCharacters(in: .whitespaces)) {
            limit = value
        }
        if let raw = response.value(forHTTPHeaderField: "x-ratelimit-remaining"), let value = Int(raw) { remaining = value }
        if let raw = response.value(forHTTPHeaderField: "x-ratelimit-reset"), let value = Int(raw) { resetSeconds = value }
        updatedAt = Date()
        #if DEBUG
        if let remaining, let limit {
            Logger(subsystem: "BannerTV", category: "EPL").debug("PulseLive quota: \(remaining, privacy: .public)/\(limit, privacy: .public) remaining")
        }
        #endif
    }
}
