import AppKit
import SwiftUI

/// Soft, shapeless light drifting behind the album cover.
///
/// Core Animation runs the motion outside the app, so it costs no CPU here.
struct ArtworkGlow: NSViewRepresentable {
    let colors: [ArtworkPalette.Color]

    func makeNSView(context: Context) -> ArtworkGlowView {
        ArtworkGlowView()
    }

    func updateNSView(_ view: ArtworkGlowView, context: Context) {
        view.colors = colors
    }
}

final class ArtworkGlowView: NSView {
    private struct Blob {
        /// How many bumps each wave puts on the outline. Different counts per
        /// blob keep the three shapes from looking related.
        let waves: [Int]
        let orbitRadius: CGFloat
        /// Unrelated lengths, so the three blobs never settle into a visible pattern.
        let orbitDuration: CFTimeInterval
        let spinDuration: CFTimeInterval
        let morphDuration: CFTimeInterval
        let clockwise: Bool
    }

    private static let blobs = [
        Blob(waves: [2, 3], orbitRadius: 14, orbitDuration: 17, spinDuration: 41, morphDuration: 13, clockwise: true),
        Blob(waves: [3, 5], orbitRadius: 16, orbitDuration: 23, spinDuration: 53, morphDuration: 19, clockwise: false),
        Blob(waves: [2, 5], orbitRadius: 10, orbitDuration: 29, spinDuration: 47, morphDuration: 11, clockwise: true),
    ]
    /// Of the view's shorter side. Sized so only the bumps clear the cover.
    private static let blobRadius: CGFloat = 0.25
    private static let waveDepth: CGFloat = 0.24
    /// The blur hides the straight segments between these.
    private static let outlinePoints = 64
    private static let softness: CGFloat = 28
    private static let strength: CGFloat = 0.32
    /// White at full strength reads as a spotlight on black and white covers.
    private static let whiteStrength: CGFloat = 0.11
    private static let colorFade: CFTimeInterval = 0.3
    private static let driftKey = "drift"
    private static let spinKey = "spin"
    private static let morphKey = "morph"

    private var lights: [CALayer] = []

    var colors: [ArtworkPalette.Color] = [] {
        didSet {
            if colors != oldValue { applyColors() }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // A shadow with no layer content is the cheapest soft shape Core
        // Animation can both blur and reshape on its own.
        lights = Self.blobs.map { _ in
            let light = CALayer()
            light.shadowOffset = .zero
            light.shadowOpacity = 1
            light.shadowRadius = Self.softness
            layer?.addSublayer(light)
            return light
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used from a storyboard")
    }

    override func layout() {
        super.layout()
        applyMotion()
    }

    /// Animations are dropped while a view is off screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMotion()
    }

    private func applyColors() {
        guard !colors.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.colorFade)
        for (index, light) in lights.enumerated() {
            let color = colors[index % colors.count]
            let alpha = color == .white ? Self.whiteStrength : Self.strength
            light.shadowColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha)
        }
        CATransaction.commit()
    }

    private func applyMotion() {
        guard bounds.width > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = min(bounds.width, bounds.height)
        let radius = side * Self.blobRadius
        let staysStill = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, (light, blob)) in zip(lights, Self.blobs).enumerated() {
            // Spread around the circle, so the colours start on different sides.
            let startAngle = CGFloat(index) / CGFloat(lights.count) * .pi * 2
            let outline = Self.outline(of: blob, radius: radius, side: side, phase: startAngle)
            light.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            light.position = center
            light.shadowPath = outline
            // By name, so a colour fade in progress keeps running.
            [Self.driftKey, Self.spinKey, Self.morphKey].forEach(light.removeAnimation(forKey:))
            guard !staysStill else { continue }

            let path = CGMutablePath()
            path.addArc(
                center: center,
                radius: blob.orbitRadius,
                startAngle: startAngle,
                endAngle: startAngle + (blob.clockwise ? -.pi * 2 : .pi * 2),
                clockwise: blob.clockwise
            )
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.path = path
            drift.duration = blob.orbitDuration
            drift.calculationMode = .paced
            drift.repeatCount = .infinity
            drift.isRemovedOnCompletion = false
            light.add(drift, forKey: Self.driftKey)

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = blob.clockwise ? -CGFloat.pi * 2 : CGFloat.pi * 2
            spin.duration = blob.spinDuration
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            light.add(spin, forKey: Self.spinKey)

            let morph = CABasicAnimation(keyPath: "shadowPath")
            morph.fromValue = outline
            morph.toValue = Self.outline(of: blob, radius: radius, side: side, phase: startAngle + .pi)
            morph.duration = blob.morphDuration
            morph.autoreverses = true
            morph.repeatCount = .infinity
            morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            morph.isRemovedOnCompletion = false
            light.add(morph, forKey: Self.morphKey)
        }
        CATransaction.commit()
    }

    /// Every outline has the same number of points, which is what lets Core
    /// Animation blend one into another.
    private static func outline(of blob: Blob, radius: CGFloat, side: CGFloat, phase: CGFloat) -> CGPath {
        let points = (0..<outlinePoints).map { step -> CGPoint in
            let angle = CGFloat(step) / CGFloat(outlinePoints) * .pi * 2
            let swell = blob.waves.reduce(CGFloat(1)) { $0 + waveDepth * sin(CGFloat($1) * angle + phase) }
            return CGPoint(
                x: side / 2 + cos(angle) * radius * swell,
                y: side / 2 + sin(angle) * radius * swell
            )
        }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }
}
