import Foundation
import Observation

/// Decides which appearance the notch has, from playback and the pointer.
///
/// Holds timing only, so it can be tested without a window.
@MainActor
@Observable
public final class NotchPresentation {
    static let titleDuration: TimeInterval = 2.8
    static let collapseDelay: TimeInterval = 3
    /// Keeps a pointer passing over the notch from opening it. The original
    /// grows in two stages, but stopping between them looks like a jolt.
    static let openDelay: TimeInterval = 0.1
    /// Lets the panel reach the screen, so the drop is seen from its start.
    static let greetingDelay: TimeInterval = 0.4
    /// Long enough for the notch to rise before the song appears.
    static let greetingRise: TimeInterval = 0.8

    /// True while paused, when the content dims.
    public private(set) var isDimmed = false
    private var closed = NotchAppearance.idle
    private var isOpen = false
    private var isGreeting = false
    private var isAsleep = false

    public var appearance: NotchAppearance {
        if isGreeting { return .greeting }
        if isAsleep { return .asleep }
        return isOpen ? .open : closed
    }

    /// True until the notch has risen again after the greeting.
    public var isGreetingRunning: Bool { heldPlayback != nil }

    /// There is nothing to show without a song.
    public var canOpen: Bool { trackID != nil && opensOnHover }

    @ObservationIgnored public var opensOnHover = true
    @ObservationIgnored public var collapsesOnPause = true

    @ObservationIgnored public var onChange: ((NotchAppearance) -> Void)?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var closedTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var trackID: String?
    @ObservationIgnored private var wasPlaying = false
    /// Playback waits here during the greeting, and with no song the notch cannot open.
    @ObservationIgnored private var heldPlayback: (trackID: String?, isPlaying: Bool)?

    public init(
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.sleep = sleep
    }

    /// Plays the greeting, then shows whatever is playing by then.
    public func greet() {
        heldPlayback = (nil, false)
        isAsleep = true
        let sleep = self.sleep
        Task { [weak self] in
            try? await sleep(Self.greetingDelay)
            self?.setGreeting(true)
            try? await sleep(GreetingTimeline.duration)
            self?.setGreeting(false)
            try? await sleep(Self.greetingRise)
            self?.finishGreeting()
        }
    }

    public func update(trackID: String?, isPlaying: Bool) {
        guard heldPlayback == nil else {
            heldPlayback = (trackID, isPlaying)
            return
        }
        let songChanged = trackID != self.trackID
        let resumed = isPlaying && !wasPlaying
        let paused = !isPlaying && wasPlaying
        self.trackID = trackID
        wasPlaying = isPlaying

        guard trackID != nil else {
            closedTask?.cancel()
            isDimmed = false
            setClosed(.idle)
            pointerExited()
            return
        }
        isDimmed = !isPlaying
        if isPlaying, songChanged || resumed {
            setClosed(.title)
            after(Self.titleDuration) { $0.setClosed(.playing) }
        } else if paused, collapsesOnPause {
            after(Self.collapseDelay) { $0.setClosed(.idle) }
        }
    }

    public func pointerEntered() {
        guard canOpen, !isOpen else { return }
        hoverTask?.cancel()
        let sleep = self.sleep
        hoverTask = Task { [weak self] in
            guard (try? await sleep(Self.openDelay)) != nil, !Task.isCancelled else { return }
            self?.setOpen(true)
        }
    }

    public func pointerExited() {
        hoverTask?.cancel()
        setOpen(false)
    }

    private func after(_ delay: TimeInterval, _ action: @escaping (NotchPresentation) -> Void) {
        closedTask?.cancel()
        let sleep = self.sleep
        closedTask = Task { [weak self] in
            guard (try? await sleep(delay)) != nil, !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func setGreeting(_ next: Bool) {
        let before = appearance
        isGreeting = next
        announce(from: before)
    }

    private func finishGreeting() {
        guard let held = heldPlayback else { return }
        heldPlayback = nil
        let before = appearance
        isAsleep = false
        announce(from: before)
        update(trackID: held.trackID, isPlaying: held.isPlaying)
    }

    private func setClosed(_ next: NotchAppearance) {
        let before = appearance
        closed = next
        announce(from: before)
    }

    private func setOpen(_ next: Bool) {
        let before = appearance
        isOpen = next
        announce(from: before)
    }

    private func announce(from before: NotchAppearance) {
        if appearance != before { onChange?(appearance) }
    }
}
