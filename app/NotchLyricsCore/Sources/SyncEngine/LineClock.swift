import Foundation
import PlaybackCore

/// Announces the active line and word, sleeping until the next change instead
/// of polling. Words change a few times a second, which costs far less than
/// sweeping a highlight across every frame.
@MainActor
public final class LineClock {
    public struct Moment: Equatable, Sendable {
        public var index: Int?
        public var current: String?
        public var next: String?
        /// Characters of the current line reached so far. Nil without word timing.
        public var sung: Int?

        public init(index: Int? = nil, current: String? = nil, next: String? = nil, sung: Int? = nil) {
            self.index = index
            self.current = current
            self.next = next
            self.sung = sung
        }
    }

    public private(set) var moment = Moment()
    public var onChange: ((Moment) -> Void)?

    /// Waking a hair early would only reschedule, so waits never get shorter than this.
    private static let shortestWait: TimeInterval = 0.005

    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var timeline: LineTimeline?
    private var playback = PlaybackState.stopped
    private var task: Task<Void, Never>?

    public var isScheduled: Bool { task != nil }

    public init(
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(20))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Replaces the schedule. Call whenever the lyrics or playback change.
    public func update(timeline: LineTimeline?, playback: PlaybackState) {
        self.timeline = timeline
        self.playback = playback
        tick()
    }

    private func tick() {
        task?.cancel()
        task = nil
        guard let timeline else { return publish(Moment()) }

        let step = timeline.step(at: playback.position(at: now()))
        let nextIndex = step.index.map { $0 + 1 } ?? 0
        publish(Moment(
            index: step.index,
            current: step.index.map { timeline.lines[$0].text },
            next: nextIndex < timeline.lines.count ? timeline.lines[nextIndex].text : nil,
            sung: step.sung
        ))

        guard playback.isPlaying, let wait = step.secondsToNext else { return }
        let sleep = self.sleep
        let delay = max(wait, Self.shortestWait)
        task = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func publish(_ next: Moment) {
        guard next != moment else { return }
        moment = next
        onChange?(next)
    }
}
