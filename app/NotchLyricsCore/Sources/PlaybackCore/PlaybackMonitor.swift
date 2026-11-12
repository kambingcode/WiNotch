import AppKit

public struct PlaybackSnapshot: Equatable, Sendable {
    public var player: PlayerKind?
    public var track: PlayedTrack?
    public var state: PlaybackState
    /// Running players the user has refused or not yet allowed.
    public var blockedPlayers: [PlayerKind]

    public init(
        player: PlayerKind? = nil,
        track: PlayedTrack? = nil,
        state: PlaybackState = .stopped,
        blockedPlayers: [PlayerKind] = []
    ) {
        self.player = player
        self.track = track
        self.state = state
        self.blockedPlayers = blockedPlayers
    }
}

/// Keeps track of which player is active and where it is in the song.
///
/// Player notifications drive it. A timer corrects the position once a second
/// but only exists while something is playing, so a stopped player costs nothing.
@MainActor
public final class PlaybackMonitor {
    public private(set) var snapshot = PlaybackSnapshot()
    public var onChange: ((PlaybackSnapshot) -> Void)?

    private let sources: [PlayerSource]
    private let interval: TimeInterval
    private let now: () -> Date
    private var tracker = PositionTracker()
    private var active: PlayerSource?
    private var timer: Timer?
    private var isAsking = false
    private var ticksToSkip = 0
    private var ticksSinceFullRead = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public var isPolling: Bool { timer != nil }

    /// A read normally takes a few milliseconds. Slower means the player is
    /// struggling, and reads run on the main thread, so leave it alone a while.
    static let slowRead: TimeInterval = 0.25
    static let ticksToSkipAfterSlowRead = 5
    /// Notifications report song changes and pauses, so most ticks only need the
    /// position. Reading everything now and then covers a missed notification.
    static let ticksBetweenFullReads = 5

    public init(sources: [PlayerSource], interval: TimeInterval = 1, now: @escaping () -> Date = { Date() }) {
        self.sources = sources
        self.interval = interval
        self.now = now
    }

    public static func live() -> PlaybackMonitor {
        PlaybackMonitor(sources: PlayerKind.allCases.map { ScriptingPlayerSource(kind: $0) })
    }

    public func start() {
        // Upstream listens for the old iTunes name, which Music does not rely on.
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observe(distributed, Notification.Name(name))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification, askPermission: true)
        observe(workspace, NSWorkspace.didTerminateApplicationNotification)
        observe(workspace, NSWorkspace.didWakeNotification)
        Task { await askPermissionThenRefresh() }
    }

    public func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        stopTimer()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, askPermission: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if askPermission {
                    Task { await self.askPermissionThenRefresh() }
                } else {
                    self.refresh()
                }
            }
        }
        observers.append((center, token))
    }

    public func askPermissionThenRefresh() async {
        guard !isAsking else { return }
        isAsking = true
        for source in sources where source.isRunning && source.permission != .granted {
            await source.requestPermission()
        }
        isAsking = false
        readPlayers()
    }

    /// Sends a command to the active player and shows the result straight away.
    public func send(_ command: PlayerCommand) {
        active?.send(command)
        refresh()
    }

    /// Reads the players, first asking any that could not answer before. A
    /// player that was still launching when first asked gets another chance here.
    public func refresh() {
        let unanswered = sources.contains {
            $0.isRunning && ($0.permission == .undetermined || $0.permission == .playerNotRunning)
        }
        if unanswered {
            Task { await askPermissionThenRefresh() }
        } else {
            readPlayers()
        }
    }

    private func readPlayers() {
        let readings = sources.map { (source: $0, reading: $0.read()) }
        let chosen = readings.first { $0.source === active && $0.reading.activity == .playing }
            ?? readings.first { $0.reading.activity == .playing }
            ?? readings.first { $0.source === active && $0.reading.activity == .paused }
            ?? readings.first { $0.reading.activity == .paused }
        apply(chosen?.source, chosen?.reading)
    }

    /// The timer only needs the active player, sparing idle ones the wake-up.
    func correctPosition() {
        guard ticksToSkip == 0 else {
            ticksToSkip -= 1
            return
        }
        guard let active else { return refresh() }
        let started = now()
        ticksSinceFullRead += 1
        let isFullRead = ticksSinceFullRead >= Self.ticksBetweenFullReads
        let position = isFullRead ? nil : active.readPosition()
        if let position {
            finishTick(started)
            apply(active, PlayerReading(track: snapshot.track, activity: .playing, position: position))
            return
        }
        ticksSinceFullRead = 0
        let reading = active.read()
        finishTick(started)
        if reading.activity == .playing {
            apply(active, reading)
        } else {
            refresh()
        }
    }

    private func finishTick(_ started: Date) {
        if now().timeIntervalSince(started) > Self.slowRead {
            ticksToSkip = Self.ticksToSkipAfterSlowRead
        }
    }

    private func apply(_ source: PlayerSource?, _ reading: PlayerReading?) {
        let reading = reading ?? .stopped
        if source !== active || reading.track?.id != snapshot.track?.id {
            tracker.reset()
        }
        active = source
        tracker.apply(reading, at: now())

        let next = PlaybackSnapshot(
            player: source?.kind,
            track: reading.track,
            state: tracker.state,
            blockedPlayers: sources.filter { $0.isRunning && $0.permission != .granted }.map(\.kind)
        )
        if tracker.state.isPlaying { startTimer() } else { stopTimer() }

        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.correctPosition() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
