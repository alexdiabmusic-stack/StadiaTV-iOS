import SwiftUI

/// A half-court shot chart driven by `BasketballCourtCoordinateTransformer`'s
/// output — the transformer and `BasketballGameSnapshot.shots` exist only for this view.
struct BasketballShotChartView: View {
    let shots: [NBAShotCoordinate]

    private func courtV(_ y: Double) -> Double { (y + 5.25) / 47 }
    private func courtU(_ x: Double) -> Double { (x + 25) / 50 }
    /// Backcourt heaves fall outside the drawn half-court; they're excluded from
    /// the canvas but never silently dropped — they're counted and labeled below.
    private var onCourt: [NBAShotCoordinate] { shots.filter { courtV($0.y) <= 1 } }
    private var offCourtCount: Int { shots.count - onCourt.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                drawCourt(context: context, size: size)
                for shot in onCourt {
                    let point = canvasPoint(shot.x, shot.y, in: size)
                    let radius: CGFloat = shot.value == 3 ? 5 : 4
                    let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(shot.made ? Theme.accessibleAccent : Theme.textSecondary.opacity(0.6)))
                }
            }
            .aspectRatio(50.0 / 47.0, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
            if offCourtCount > 0 {
                Text("\(offCourtCount) shot\(offCourtCount == 1 ? "" : "s") beyond half court").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("Made", systemImage: "circle.fill").foregroundStyle(Theme.accessibleAccent)
                Label("Missed", systemImage: "circle.fill").foregroundStyle(Theme.textSecondary.opacity(0.6))
            }.font(.caption)
        }
    }

    private var summary: String {
        let made = shots.filter(\.made).count
        return "Shot chart. \(made) made of \(shots.count) attempts."
    }

    private func canvasPoint(_ x: Double, _ y: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: courtU(x) * size.width, y: (1 - courtV(y)) * size.height)
    }

    private func drawCourt(context: GraphicsContext, size: CGSize) {
        let basket = canvasPoint(0, 0, in: size)
        context.stroke(Path(ellipseIn: CGRect(x: basket.x - 3, y: basket.y - 3, width: 6, height: 6)), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
        context.stroke(restrictedAreaPath(in: size), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
        let freeThrowCenter = canvasPoint(0, 15, in: size)
        context.stroke(Path(ellipseIn: CGRect(x: freeThrowCenter.x - 6, y: freeThrowCenter.y - 6, width: 12, height: 12)), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
        context.stroke(threePointPath(in: size), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
    }

    /// A simplified semicircle at the restricted-area radius (4 ft from the basket).
    private func restrictedAreaPath(in size: CGSize) -> Path {
        var path = Path()
        let points = stride(from: 0.0, through: 180.0, by: 5.0).map { angle -> CGPoint in
            let radians = angle * .pi / 180
            return canvasPoint(4 * cos(radians), 4 * sin(radians), in: size)
        }
        path.addLines(points)
        return path
    }

    /// 23.75 ft arc, straightening to a 22 ft corner line where the arc would
    /// otherwise cross the sideline.
    private func threePointPath(in size: CGSize) -> Path {
        var path = Path()
        let corner = 22.0, arc = 23.75
        let cornerY = sqrt(max(0, arc * arc - corner * corner))
        let theta1 = acos(corner / arc) * 180 / .pi
        path.move(to: canvasPoint(-corner, 0, in: size))
        path.addLine(to: canvasPoint(-corner, cornerY, in: size))
        for angle in stride(from: 180 - theta1, through: theta1, by: -5.0) {
            let radians = angle * .pi / 180
            path.addLine(to: canvasPoint(arc * cos(radians), arc * sin(radians), in: size))
        }
        path.addLine(to: canvasPoint(corner, 0, in: size))
        return path
    }
}
