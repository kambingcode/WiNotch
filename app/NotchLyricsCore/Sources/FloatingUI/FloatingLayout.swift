import CoreGraphics

/// The floating window's decisions, kept free of AppKit so they can be tested.
enum FloatingLayout {
    static func isVisible(enabled: Bool, hasLyrics: Bool, isPlaying: Bool, hidesOnPause: Bool) -> Bool {
        enabled && hasLyrics && (isPlaying || !hidesOnPause)
    }

    static func height(fontSize: CGFloat, showsNextLine: Bool) -> CGFloat {
        let current = fontSize * 1.3
        let next = showsNextLine ? fontSize * 0.75 * 1.3 + 4 : 0
        return (current + next + 24).rounded(.up)
    }

    /// Restores the saved spot if it is still on a screen, which it may not be
    /// after a display is unplugged. Otherwise sits low and centred.
    static func origin(saved: CGPoint?, size: CGSize, screens: [CGRect]) -> CGPoint {
        if let saved {
            let frame = CGRect(origin: saved, size: size)
            if screens.contains(where: { $0.intersection(frame).width >= 40 && $0.intersection(frame).height >= 20 }) {
                return saved
            }
        }
        guard let screen = screens.first else { return .zero }
        return CGPoint(x: screen.midX - size.width / 2, y: screen.minY + 80)
    }
}
