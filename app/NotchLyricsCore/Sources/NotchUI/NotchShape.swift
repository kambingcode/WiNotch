import SwiftUI

/// The notch outline: flat against the top of the screen, curving out into it
/// at the top corners and rounded at the bottom.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topFlare: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topFlare) }
        set {
            bottomRadius = newValue.first
            topFlare = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + topFlare
        let right = rect.maxX - topFlare
        let radius = min(bottomRadius, rect.height / 2, (right - left) / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + topFlare),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: left + radius, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - radius),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + topFlare))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
