import AppKit

/// Reports when the pointer enters or leaves a window.
///
/// A tracking area would be simpler, but AppKit then rebuilds the window's
/// regions on every redraw, which was a third of the app's work while lyrics
/// played. Mouse monitors cost nothing until the mouse moves.
@MainActor
public final class PointerWatcher {
    private let frame: () -> CGRect
    private let onChange: (Bool) -> Void
    private var isInside = false
    private var monitors: [Any] = []

    public init(frame: @escaping () -> CGRect, onChange: @escaping (Bool) -> Void) {
        self.frame = frame
        self.onChange = onChange
    }

    public func start() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Global sees the pointer over other apps, local sees it over this one.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.update(NSEvent.mouseLocation) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.update(NSEvent.mouseLocation) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func update(_ location: CGPoint) {
        let inside = frame().contains(location)
        guard inside != isInside else { return }
        isInside = inside
        onChange(inside)
    }
}
