import AppState
import PlaybackCore
import SwiftUI
import SyncEngine

struct NotchRootView: View {
    let model: NowPlayingModel
    let presentation: NotchPresentation
    let artwork: ArtworkStore
    let geometry: NotchGeometry

    private var appearance: NotchAppearance { presentation.appearance }

    var body: some View {
        let size = geometry.size(for: appearance)
        let topFlare = geometry.topFlare(for: appearance)
        let shape = NotchShape(bottomRadius: geometry.bottomRadius(for: appearance), topFlare: topFlare)
        ZStack(alignment: .top) {
            shape.fill(.black)

            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(presentation.isDimmed && appearance != .open ? 0.5 : 1)
        }
        .frame(width: size.width + topFlare * 2, height: size.height)
        // The shape, not a rectangle, so the glow stops at the rounded corners.
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(duration: presentation.isGreetingRunning ? 0.8 : 0.5, bounce: 0), value: appearance)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch appearance {
        case .idle, .asleep:
            EmptyView()
        case .playing, .title:
            ClosedContent(model: model, artwork: artwork, notchHeight: geometry.idle.height, showsTitle: appearance == .title)
                .frame(width: geometry.size(for: appearance).width, height: geometry.size(for: appearance).height)
                .transition(.opacity)
        case .greeting:
            GreetingContent(model: model, notchHeight: geometry.idle.height)
                .frame(width: geometry.size(for: .greeting).width, height: geometry.size(for: .greeting).height)
                .transition(.opacity)
        case .open:
            // Laid out at its final size and uncovered by the growing shape,
            // because reflowing the text on every frame looks unsteady.
            OpenContent(model: model, artwork: artwork, notchHeight: geometry.idle.height)
                .frame(width: geometry.size(for: .open).width, height: geometry.size(for: .open).height)
                .transition(.opacity)
        }
    }
}

private struct ClosedContent: View {
    let model: NowPlayingModel
    let artwork: ArtworkStore
    let notchHeight: CGFloat
    let showsTitle: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Artwork(store: artwork, size: 26, radius: 6)
                Spacer()
                ActivityBars(isPlaying: model.playback.isPlaying)
            }
            .padding(.horizontal, 10)
            .frame(height: notchHeight)

            Text(styledText)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity, alignment: showsTitle ? .center : .top)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: text)
        }
    }

    private var styledText: AttributedString {
        let isLyric = !showsTitle && model.moment.current?.isEmpty == false
        return SungText.attributed(text, sung: isLyric ? model.moment.sung : nil, color: .white)
    }

    private var text: String {
        let name = [model.track?.title, model.track?.artist].compactMap { $0 }.joined(separator: " - ")
        if showsTitle { return "♪ \(name)" }
        guard model.moment.index != nil, let line = model.moment.current else {
            return model.lines.isEmpty ? name : "♪"
        }
        return line.isEmpty ? "♪" : line
    }
}

private struct OpenContent: View {
    let model: NowPlayingModel
    let artwork: ArtworkStore
    let notchHeight: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Artwork(store: artwork, size: 124, radius: 12)
                .background {
                    if model.settings.notchArtworkGlow {
                        ArtworkGlow(colors: artwork.colors)
                            .frame(width: 240, height: 240)
                            .allowsHitTesting(false)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.track?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(model.track?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                ProgressLine(model: model)
                Controls(model: model)
            }
            .frame(width: 150, alignment: .leading)

            LyricsColumn(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.top, notchHeight - 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProgressLine: View {
    let model: NowPlayingModel

    var body: some View {
        // One update a second is enough for a bar this size.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = model.track?.duration ?? 0
            let position = model.playback.position(at: context.date)
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white).frame(width: proxy.size.width * progress)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard duration > 0 else { return }
                    let fraction = min(max(value.location.x / proxy.size.width, 0), 1)
                    model.send(.seek(fraction * duration))
                })
            }
            .frame(height: 4)
        }
    }
}

private struct Controls: View {
    let model: NowPlayingModel

    var body: some View {
        HStack(spacing: 22) {
            control("backward.fill", .previous)
            control(model.playback.isPlaying ? "pause.fill" : "play.fill", .playPause)
            control("forward.fill", .next)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func control(_ symbol: String, _ command: PlayerCommand) -> some View {
        Button {
            model.send(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LyricsColumn: View {
    let model: NowPlayingModel

    /// Four lines still fit when every one of them wraps.
    private static let visibleLines = 4

    /// The active line and its neighbours, kept in view near the middle.
    private var visible: [(index: Int, text: String)] {
        let lines = model.lines
        guard !lines.isEmpty else { return [] }
        let active = model.moment.index ?? 0
        let first = max(0, min(active - 1, lines.count - Self.visibleLines))
        return (first..<min(first + Self.visibleLines, lines.count)).map { ($0, lines[$0].text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if visible.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ForEach(visible, id: \.index) { line in
                let isActive = line.index == model.moment.index
                Text(SungText.attributed(
                    line.text.isEmpty ? "♪" : line.text,
                    sung: isActive && !line.text.isEmpty ? model.moment.sung : nil,
                    color: .white.opacity(isActive ? 1 : 0.5)
                ))
                    .font(.system(size: 13, weight: isActive ? .bold : .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: model.moment.index)
    }

    private var message: String {
        switch model.status {
        case .searching: return "Mencari lirik…"
        case .notFound: return "Lirik tidak ditemukan"
        case .unavailable: return "Layanan lirik tidak terjangkau"
        default: return ""
        }
    }
}

private struct Artwork: View {
    let store: ArtworkStore
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image = store.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Moving bars while playing, four still dots while paused.
///
/// Core Animation runs this outside the app. The same motion in SwiftUI redraws
/// every frame and used about 15% of a CPU core.
private struct ActivityBars: NSViewRepresentable {
    let isPlaying: Bool

    func makeNSView(context: Context) -> ActivityBarsView {
        ActivityBarsView()
    }

    func updateNSView(_ view: ActivityBarsView, context: Context) {
        view.isPlaying = isPlaying
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ActivityBarsView, context: Context) -> CGSize? {
        ActivityBarsView.size
    }
}

final class ActivityBarsView: NSView {
    static let size = CGSize(width: 19.5, height: 14)

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2.5
    private static let peaks: [CGFloat] = [0.55, 1, 0.7, 0.85]
    private static let animationKey = "bars"

    private var bars: [CALayer] = []

    var isPlaying = false {
        didSet {
            if isPlaying != oldValue { applyMotion() }
        }
    }

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        bars = Self.peaks.indices.map { index in
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.frame = CGRect(
                x: CGFloat(index) * (Self.barWidth + Self.gap),
                y: 0,
                width: Self.barWidth,
                height: Self.size.height
            )
            layer?.addSublayer(bar)
            return bar
        }
        applyMotion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used from a storyboard")
    }

    /// Animations are dropped while a view is off screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMotion()
    }

    private func applyMotion() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: Self.animationKey)
            if isPlaying {
                bar.transform = CATransform3DIdentity
                let motion = CABasicAnimation(keyPath: "transform.scale.y")
                motion.fromValue = 0.3
                motion.toValue = Self.peaks[index]
                motion.duration = 0.45 + Double(index) * 0.07
                motion.autoreverses = true
                motion.repeatCount = .infinity
                motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                motion.isRemovedOnCompletion = false
                bar.add(motion, forKey: Self.animationKey)
            } else {
                bar.transform = CATransform3DMakeScale(1, Self.barWidth / Self.size.height, 1)
            }
        }
        CATransaction.commit()
    }
}
