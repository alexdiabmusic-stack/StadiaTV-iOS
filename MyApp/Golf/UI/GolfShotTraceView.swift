import SwiftUI

/// Schematic shot-path visualization (STEP 32-33). This deliberately does
/// NOT render fairways/greens/bunkers/water — no course-geometry asset
/// backs this view, so only the shots themselves (as a connected path) are
/// drawn. Prefers the provider's already-normalized `x`/`y` (seen roughly in
/// 0...1 range in captured fixtures); falls back to min/max-normalizing the
/// `tourcastX`/`tourcastY` pair when `x`/`y` is absent. Neither is asserted
/// to be a true geographic projection.
struct GolfShotTraceView: View {
    let shots: [GolfShot]
    let selectedShotID: String?

    private var points: [(shot: GolfShot, from: CGPoint?, to: CGPoint?)] {
        let allRaw = shots.compactMap { $0.coordinates?.leftToRight ?? $0.coordinates?.bottomToTop }
        let usesNormalized = allRaw.contains { ($0.from?.x != nil || $0.to?.x != nil) }
        guard usesNormalized || !allRaw.isEmpty else { return [] }

        // Collect the coordinate space needed for min/max normalization when
        // falling back to tourcast units.
        var allTourcastX: [Double] = [], allTourcastY: [Double] = []
        for pair in allRaw {
            for point in [pair.from, pair.to].compactMap({ $0 }) {
                if let x = point.tourcastX { allTourcastX.append(x) }
                if let y = point.tourcastY { allTourcastY.append(y) }
            }
        }
        let minX = allTourcastX.min() ?? 0, maxX = allTourcastX.max() ?? 1
        let minY = allTourcastY.min() ?? 0, maxY = allTourcastY.max() ?? 1

        func normalize(_ point: GolfShotPoint?) -> CGPoint? {
            guard let point else { return nil }
            if let x = point.x, let y = point.y { return CGPoint(x: x, y: y) }
            if let x = point.tourcastX, let y = point.tourcastY, maxX > minX, maxY > minY {
                return CGPoint(x: (x - minX) / (maxX - minX), y: (y - minY) / (maxY - minY))
            }
            return nil
        }

        return shots.map { shot in
            let pair = shot.coordinates?.leftToRight ?? shot.coordinates?.bottomToTop
            return (shot, normalize(pair?.from), normalize(pair?.to))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let usable = points.filter { $0.from != nil || $0.to != nil }
            if usable.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.circle").font(.title2)
                    Text("Shot trace unavailable for this hole").font(.caption)
                }
                .foregroundStyle(Theme.textTertiary)
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                let size = geometry.size
                let inset: CGFloat = 20
                let map: (CGPoint) -> CGPoint = { point in
                    CGPoint(
                        x: inset + point.x * (size.width - 2 * inset),
                        y: (size.height - inset) - point.y * (size.height - 2 * inset)
                    )
                }
                ZStack {
                    Canvas { context, _ in
                        for entry in usable {
                            guard let from = entry.from, let to = entry.to else { continue }
                            var path = Path()
                            path.move(to: map(from))
                            path.addLine(to: map(to))
                            let isSelected = entry.shot.id == selectedShotID
                            context.stroke(path, with: .color(isSelected ? Theme.accessibleAccent : Theme.textSecondary.opacity(0.6)), lineWidth: isSelected ? 3 : 1.5)
                        }
                    }
                    ForEach(usable, id: \.shot.id) { entry in
                        if let from = entry.from {
                            Circle().fill(Theme.textTertiary).frame(width: 6, height: 6).position(map(from))
                        }
                        if entry.shot.isFinalStroke, let to = entry.to {
                            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Theme.upcoming).position(map(to))
                        }
                    }
                }
            }
        }
        .frame(height: 180)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true) // shot list below is the accessible representation
    }
}
