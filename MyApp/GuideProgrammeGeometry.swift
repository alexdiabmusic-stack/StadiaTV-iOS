import Foundation

/// Absolute-time geometry avoids fixed 24-hour assumptions on DST transition days.
nonisolated enum GuideProgrammeGeometry {
    struct Frame: Equatable {
        let x: Double
        let width: Double
    }

    static func frame(start: Date, end: Date, windowStart: Date, windowEnd: Date,
                      pointsPerMinute: Double) -> Frame? {
        guard start < end, windowStart < windowEnd, pointsPerMinute > 0 else { return nil }
        let visibleStart = max(start, windowStart)
        let visibleEnd = min(end, windowEnd)
        guard visibleStart < visibleEnd else { return nil }
        return Frame(x: visibleStart.timeIntervalSince(windowStart) / 60 * pointsPerMinute,
                     width: visibleEnd.timeIntervalSince(visibleStart) / 60 * pointsPerMinute)
    }
}
