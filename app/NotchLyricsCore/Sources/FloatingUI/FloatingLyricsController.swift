import AppKit
import AppState
import Observation
import SwiftUI

/// A borderless window that can be dragged anywhere and never takes focus.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .mainMenu
        isFloatingPanel = true
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }
}

private final class FloatingHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct FloatingLyricsView: View {
    let model: NowPlayingModel

    private var settings: AppSettings { model.settings }

    private var alignment: Alignment {
        switch settings.floatingAlignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private var horizontal: HorizontalAlignment {
        switch settings.floatingAlignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var body: some View {
        let text = Color(nsColor: ColorCoding.color(from: settings.floatingTextColor))
        VStack(alignment: horizontal, spacing: 4) {
            line(model.moment.current, sung: model.moment.sung, size: settings.floatingFontSize, weight: .semibold, color: text)
            if settings.floatingShowsNextLine {
                line(model.moment.next, sung: nil, size: settings.floatingFontSize * 0.75, weight: .regular, color: text.opacity(0.6))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .background(
            Color(nsColor: ColorCoding.color(from: settings.floatingBackgroundColor)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.2), value: model.moment.index)
    }

    private func line(_ text: String?, sung: Int?, size: Double, weight: Font.Weight, color: Color) -> some View {
        let sungLine = text.flatMap { $0.isEmpty ? nil : $0 }
        return Text(SungText.attributed(sungLine ?? "♪", sung: sungLine == nil ? nil : sung, color: color))
            .font(.system(size: size, weight: weight))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.opacity)
    }
}

/// Shows or hides the floating lyrics and remembers where the user left them.
@MainActor
public final class FloatingLyricsController {
    /// Faint enough to read what is underneath, but still draggable.
    private static let hoverOpacity: CGFloat = 0.08

    private let model: NowPlayingModel
    private let panel = FloatingPanel()
    private var saveTask: Task<Void, Never>?
    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var pointer: PointerWatcher?
    private var isPlacing = false

    public init(model: NowPlayingModel) {
        self.model = model
    }

    public func start() {
        let content = FloatingHostingView(rootView: FloatingLyricsView(model: model))
        content.sizingOptions = []
        pointer = PointerWatcher(frame: { [panel] in panel.isVisible ? panel.frame : .zero }) { [weak self] inside in
            guard let self else { return }
            let faded = inside && self.model.settings.floatingHidesOnHover
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.panel.animator().alphaValue = faded ? Self.hoverOpacity : 1
            }
        }
        pointer?.start()
        panel.contentView = content
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePositionSoon() }
        }
        // An unplugged display can leave the window with nowhere to be.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        follow()
    }

    private func follow() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func apply() {
        let settings = model.settings
        let size = CGSize(
            width: settings.floatingWidth,
            height: FloatingLayout.height(fontSize: settings.floatingFontSize, showsNextLine: settings.floatingShowsNextLine)
        )
        let origin = FloatingLayout.origin(
            saved: settings.floatingPosition,
            size: size,
            screens: NSScreen.screens.map(\.visibleFrame)
        )
        isPlacing = true
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        isPlacing = false

        let visible = FloatingLayout.isVisible(
            enabled: settings.floatingEnabled,
            hasLyrics: !model.lines.isEmpty,
            isPlaying: model.playback.isPlaying,
            hidesOnPause: settings.floatingHidesOnPause
        )
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Dragging sends many moves, so the position is saved once it settles.
    private func savePositionSoon() {
        guard !isPlacing else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, let self else { return }
            self.model.settings.floatingPosition = self.panel.frame.origin
        }
    }
}
