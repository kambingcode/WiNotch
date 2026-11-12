import AppKit

/// How the notch looks at a given moment.
public enum NotchAppearance: Equatable, Sendable {
    /// Exactly the hardware notch, so nothing shows. The greeting starts and ends here.
    case asleep
    /// No song, or paused long enough to collapse.
    case idle
    /// A song is playing and the active lyric is shown.
    case playing
    /// Briefly shows the song name after a change or resume.
    case title
    /// Says hello when the app starts.
    case greeting
    case open
}

/// Sizes in points, stored as additions to the hardware notch so they adapt to
/// other screens. They leave enough room for a full lyric line.
public struct NotchGeometry: Equatable, Sendable {
    /// Used when a screen does not report its menu bar areas.
    static let fallbackWidth: CGFloat = 195
    static let fallbackHeight: CGFloat = 30
    /// How far the idle notch reaches past the hardware one.
    static let idleMargin: CGFloat = 10

    /// The physical notch, or an equivalent on screens without one.
    public var idle: CGSize
    public var hasNotch: Bool
    /// The user's adjustment to the closed width.
    public var extraWidth: CGFloat = 0

    public init(idle: CGSize, hasNotch: Bool, extraWidth: CGFloat = 0) {
        self.idle = idle
        self.hasNotch = hasNotch
        self.extraWidth = extraWidth
    }

    public init(screen: NSScreen?) {
        guard let screen else {
            self.init(idle: CGSize(width: Self.fallbackWidth, height: Self.fallbackHeight), hasNotch: false)
            return
        }
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRight: screen.auxiliaryTopRightArea?.width
        )
    }

    init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeft: CGFloat?,
        auxiliaryRight: CGFloat?
    ) {
        var width = Self.fallbackWidth
        if let auxiliaryLeft, let auxiliaryRight {
            width = frame.width - auxiliaryLeft - auxiliaryRight + Self.idleMargin
        }
        let height = safeAreaTop > 0 ? safeAreaTop : frame.maxY - visibleFrame.maxY
        self.init(
            idle: CGSize(width: width, height: height > 0 ? height : Self.fallbackHeight),
            hasNotch: safeAreaTop > 0
        )
    }

    /// Without a notch to hide in, the shape starts flat against the top of the screen.
    private var hardware: CGSize {
        hasNotch ? CGSize(width: idle.width - Self.idleMargin, height: idle.height) : CGSize(width: idle.width, height: 0)
    }

    public func size(for appearance: NotchAppearance) -> CGSize {
        switch appearance {
        case .asleep: return hardware
        case .idle: return idle
        case .playing: return CGSize(width: idle.width + 190 + extraWidth, height: idle.height + 28)
        case .title: return CGSize(width: idle.width + 214 + extraWidth, height: idle.height + 41)
        case .greeting: return CGSize(width: hardware.width, height: idle.height + 44)
        case .open: return CGSize(width: idle.width + 490, height: idle.height + 160)
        }
    }

    public func bottomRadius(for appearance: NotchAppearance) -> CGFloat {
        appearance == .open ? 22 : 14
    }

    /// Width of the curve joining the top edge of the screen.
    static let topFlare: CGFloat = 6

    /// The greeting has none, so its sides continue straight down from the hardware notch.
    public func topFlare(for appearance: NotchAppearance) -> CGFloat {
        appearance == .asleep || appearance == .greeting ? 0 : Self.topFlare
    }

    /// Fits every appearance. A wide extra width can pass the open notch.
    public var canvasSize: CGSize {
        let sizes = [NotchAppearance.title, .open].map { panelFrame(for: $0, on: .zero).size }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }

    /// The panel only ever covers the shape, so everything around it stays clickable.
    public func panelFrame(for appearance: NotchAppearance, on screen: CGRect) -> CGRect {
        let size = size(for: appearance)
        // An even width keeps the centre on the same point at every size, so
        // the shape does not shift when the panel changes.
        let width = ((size.width + Self.topFlare * 2) / 2).rounded(.up) * 2
        let height = size.height.rounded(.up)
        return CGRect(
            x: screen.midX - width / 2,
            y: screen.maxY - height,
            width: width,
            height: height
        )
    }
}
