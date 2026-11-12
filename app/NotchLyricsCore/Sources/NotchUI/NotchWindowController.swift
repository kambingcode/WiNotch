import AppKit
import AppState
import Observation
import SwiftUI

/// A panel that sits over the notch without ever taking focus.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.utilityWindow, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }
}

/// Takes clicks even though the app is never active.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps its content at one size, centred at the top, however the panel resizes.
///
/// SwiftUI would otherwise see the panel change in the middle of an animation
/// and animate the notch's position too, so it would grow off centre.
final class NotchCanvas: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for content in subviews {
            content.setFrameOrigin(NSPoint(
                x: (bounds.width - content.frame.width) / 2,
                y: bounds.height - content.frame.height
            ))
        }
    }
}

/// Places the notch and keeps it matched to the playback and the screen.
@MainActor
public final class NotchWindowController {
    /// Long enough for the closing animation before the panel shrinks.
    private static let shrinkDelay: TimeInterval = 0.65

    private let model: NowPlayingModel
    private let presentation = NotchPresentation()
    private let artwork = ArtworkStore()
    private let panel = NotchPanel()
    private var screen: NSScreen?
    private var pointerInside = false
    private var shrinkTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var pointer: PointerWatcher?

    public init(model: NowPlayingModel) {
        self.model = model
    }

    public func show() {
        presentation.onChange = { [weak self] appearance in
            if appearance == .open {
                // Fires as the shape starts to grow. Only felt with a finger on a trackpad.
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            self?.fitPanel()
        }
        // Before the panel appears, so its first frame is already the hardware notch.
        if model.settings.notchEnabled, model.settings.notchGreetingEnabled {
            presentation.greet()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen() }
        }
        placeOnScreen()
        pointer = PointerWatcher(frame: { [panel] in panel.frame }) { [weak self] inside in
            self?.pointerMoved(inside: inside)
        }
        pointer?.start()
        followPlayback()
        followSettings()
    }

    private func pointerMoved(inside: Bool) {
        pointerInside = inside
        if inside {
            presentation.pointerEntered()
        } else {
            presentation.pointerExited()
        }
        fitPanel()
    }

    private func followSettings() {
        let settings = model.settings
        withObservationTracking {
            presentation.opensOnHover = settings.notchOpensOnHover
            presentation.collapsesOnPause = settings.notchCollapsesOnPause
            if settings.notchEnabled {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
            _ = settings.notchExtraWidth
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.placeOnScreen()
                self?.followSettings()
            }
        }
    }

    private func placeOnScreen() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        let geometry = currentGeometry
        let content = NotchHostingView(rootView: NotchRootView(
            model: model,
            presentation: presentation,
            artwork: artwork,
            geometry: geometry
        ))
        // The size is set here, not by what SwiftUI would like.
        content.sizingOptions = []
        content.setFrameSize(geometry.canvasSize)
        let canvas = NotchCanvas()
        canvas.addSubview(content)
        panel.contentView = canvas
        setFrame(for: presentation.appearance)
    }

    private var currentGeometry: NotchGeometry {
        var geometry = NotchGeometry(screen: screen)
        geometry.extraWidth = model.settings.notchExtraWidth
        return geometry
    }

    private func setFrame(for appearance: NotchAppearance) {
        guard let screen else { return }
        let frame = currentGeometry.panelFrame(for: appearance, on: screen.frame)
        panel.setFrame(frame, display: true)
    }

    /// Growing happens before the animation and shrinking after it, because
    /// the panel clips whatever falls outside it. While the pointer is inside,
    /// the panel takes its open size at once, so it never resizes mid-motion.
    private func fitPanel() {
        guard let screen else { return }
        shrinkTask?.cancel()
        let opening = pointerInside && presentation.canOpen
        let appearance = opening ? NotchAppearance.open : presentation.appearance
        let target = currentGeometry.panelFrame(for: appearance, on: screen.frame)
        if target.width >= panel.frame.width, target.height >= panel.frame.height {
            panel.setFrame(target, display: true)
            return
        }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.shrinkDelay))
            guard !Task.isCancelled else { return }
            self?.setFrame(for: appearance)
        }
    }

    private func followPlayback() {
        withObservationTracking {
            presentation.update(trackID: model.track?.id, isPlaying: model.playback.isPlaying)
            artwork.load(model.track?.artworkURL)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPlayback() }
        }
    }
}
