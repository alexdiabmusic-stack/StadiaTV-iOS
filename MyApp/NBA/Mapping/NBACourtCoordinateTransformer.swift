import Foundation

/// NBA's legacy `xLegacy`/`yLegacy` fields are already basket-origin, just in
/// tenths of a foot rather than feet. This is the only place that unit
/// conversion happens; `NBAShotCoordinate` downstream is documented as
/// court-relative feet and nothing else should touch the raw legacy values.
nonisolated enum NBACourtCoordinateTransformer {
    static func normalize(xLegacy: Double?, yLegacy: Double?, distanceFeet: Double?, made: Bool, value: Int) -> NBAShotCoordinate? {
        // A distance-only shot has no real (x, y) — inventing one (e.g. straight up
        // the middle) would fabricate geometry that was never reported.
        guard let xLegacy, let yLegacy, xLegacy.isFinite, yLegacy.isFinite else { return nil }
        guard value == 2 || value == 3 else { return nil }
        let x = xLegacy / 10
        let y = yLegacy / 10
        // Half-court is 50x94 ft; a generous envelope absorbs out-of-bounds noise
        // without silently relocating a shot that's actually broken data.
        guard abs(x) <= 30, y >= -6, y <= 95 else { return nil }
        // NBA emits exact (0, 0) as a "no location" sentinel for events that were
        // never spatially tracked. A genuine shot at the rim is also (0, 0), but it
        // reports a near-zero distance — that's the only way to tell them apart.
        if x == 0, y == 0, !(distanceFeet != nil && distanceFeet! <= 1) { return nil }
        let computed = hypot(x, y)
        let resolvedDistance: Double
        if let distanceFeet {
            // Both figures are measured from the hoop; real values agree closely.
            // A larger gap means we've misread which field is which, and plotting
            // a point that contradicts its own labeled distance would silently
            // corrupt the whole chart — better to drop the point than mislabel it.
            guard abs(distanceFeet - computed) <= max(3.0, 0.15 * computed) else { return nil }
            resolvedDistance = distanceFeet
        } else {
            // Arithmetic on the supplied coordinates, not a guess.
            resolvedDistance = (computed * 10).rounded() / 10
        }
        return NBAShotCoordinate(x: x, y: y, distanceFeet: resolvedDistance, made: made, value: value)
    }
}
