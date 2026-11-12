import Foundation
import LyricsFinder
import LyricsKit
import Observation
import PlaybackCore
import SyncEngine

public protocol LyricsLookup: Sendable {
    func find(_ query: TrackQuery) async throws -> LookupResult
    func findWordTimed(_ query: TrackQuery, base: FoundLyrics) async throws -> FoundLyrics?
    func candidates(title: String, artist: String, duration: TimeInterval) async -> [LyricsCandidate]
    func use(_ candidate: LyricsCandidate, for query: TrackQuery) async -> FoundLyrics
    func setOffset(_ offset: TimeInterval, for query: TrackQuery) async
    func clearCache() async
}

extension LyricsFinder: LyricsLookup {}

public enum LyricsStatus: Equatable, Sendable {
    case idle
    case searching
    case found(source: String)
    case notFound
    case unavailable
}

/// What the interface shows: the song, its lyrics and the active line.
@MainActor
@Observable
public final class NowPlayingModel {
    public private(set) var player: PlayerKind?
    public private(set) var track: PlayedTrack?
    public private(set) var playback = PlaybackState.stopped
    public private(set) var status = LyricsStatus.idle
    public private(set) var moment = LineClock.Moment()
    /// Running players that need the user's permission.
    public private(set) var blockedPlayers: [PlayerKind] = []
    /// Every line of the current song, for the open notch.
    public private(set) var lines: [LineTimeline.Line] = []
    /// True when the current lyrics highlight each word.
    public var hasWordTiming: Bool { lines.contains { !$0.marks.isEmpty } }
    /// This song's timing offset in seconds. Positive shows lines earlier.
    public private(set) var offset: TimeInterval = 0
    public let settings: AppSettings

    @ObservationIgnored private let monitor: PlaybackMonitor
    @ObservationIgnored private let lookup: LyricsLookup
    @ObservationIgnored private let clock: LineClock
    @ObservationIgnored private var timeline: LineTimeline?
    @ObservationIgnored private var lyrics: Lyrics?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var wordTask: Task<Void, Never>?

    public init(
        monitor: PlaybackMonitor,
        lookup: LyricsLookup,
        settings: AppSettings? = nil,
        clock: LineClock? = nil
    ) {
        let clock = clock ?? LineClock()
        self.monitor = monitor
        self.lookup = lookup
        self.settings = settings ?? AppSettings()
        self.clock = clock
        clock.onChange = { [weak self] in self?.moment = $0 }
        monitor.onChange = { [weak self] in self?.apply($0) }
    }

    public static func live() -> NowPlayingModel {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cache = LyricsDiskCache(directory: support.appendingPathComponent("NotchLyrics/Lyrics"))
        return NowPlayingModel(monitor: .live(), lookup: LyricsFinder(cache: cache))
    }

    public func start() {
        monitor.start()
        followGlobalOffset()
    }

    private func followGlobalOffset() {
        withObservationTracking {
            _ = settings.globalOffsetMs
            _ = settings.wordTimingEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.rebuildTimeline()
                self?.followGlobalOffset()
            }
        }
    }

    public func send(_ command: PlayerCommand) {
        monitor.send(command)
    }

    /// Shifts this song's lyrics and remembers the change.
    public func adjustOffset(by delta: TimeInterval) {
        guard lyrics != nil, let query = currentQuery else { return }
        offset = ((offset + delta) * 1000).rounded() / 1000
        rebuildTimeline()
        let lookup = self.lookup
        let saved = offset
        Task { await lookup.setOffset(saved, for: query) }
    }

    public func search(title: String, artist: String) async -> [LyricsCandidate] {
        await lookup.candidates(title: title, artist: artist, duration: track?.duration ?? 0)
    }

    /// Replaces the current song's lyrics with a manual choice.
    public func use(_ candidate: LyricsCandidate) async {
        guard let query = currentQuery else { return }
        searchTask?.cancel()
        wordTask?.cancel()
        let found = await lookup.use(candidate, for: query)
        guard query == currentQuery else { return }
        show(found)
    }

    public func clearCache() async {
        await lookup.clearCache()
    }

    private var currentQuery: TrackQuery? {
        track.map { TrackQuery(title: $0.title, artist: $0.artist, duration: $0.duration) }
    }

    private func show(_ found: FoundLyrics) {
        lyrics = found.lyrics
        offset = found.offset
        status = .found(source: found.source)
        rebuildTimeline()
    }

    /// The lyrics are already showing, so this quietly swaps them if it finds better.
    private func searchWordTiming(for query: TrackQuery, base: FoundLyrics) {
        guard settings.wordTimingEnabled, !base.hasWordTiming else { return }
        let lookup = self.lookup
        wordTask = Task { [weak self] in
            guard let better = try? await lookup.findWordTimed(query, base: base),
                  !Task.isCancelled,
                  let self,
                  query == self.currentQuery else { return }
            self.lyrics = better.lyrics
            self.status = .found(source: better.source)
            self.rebuildTimeline()
        }
    }

    private func rebuildTimeline() {
        timeline = lyrics.map {
            LineTimeline(
                lyrics: $0,
                offset: offset + Double(settings.globalOffsetMs) / 1000,
                usesWordTiming: settings.wordTimingEnabled
            )
        }
        lines = timeline?.lines ?? []
        clock.update(timeline: timeline, playback: playback)
    }

    private func apply(_ snapshot: PlaybackSnapshot) {
        let songChanged = snapshot.track?.id != track?.id || snapshot.player != player
        player = snapshot.player
        track = snapshot.track
        playback = snapshot.state
        blockedPlayers = snapshot.blockedPlayers

        if songChanged { startSearch(for: snapshot.track) }
        clock.update(timeline: timeline, playback: playback)
    }

    private func startSearch(for track: PlayedTrack?) {
        searchTask?.cancel()
        wordTask?.cancel()
        timeline = nil
        lyrics = nil
        lines = []
        offset = 0
        guard let track else {
            status = .idle
            return
        }
        // Spotify ads have no title, and there is nothing to search for.
        guard !track.title.isEmpty else {
            status = .notFound
            return
        }
        status = .searching
        let query = TrackQuery(title: track.title, artist: track.artist, duration: track.duration)
        let lookup = self.lookup
        searchTask = Task { [weak self] in
            let result = try? await lookup.find(query)
            guard !Task.isCancelled else { return }
            self?.finishSearch(result)
        }
    }

    private func finishSearch(_ result: LookupResult?) {
        switch result {
        case .found(let found):
            show(found)
            if let query = currentQuery { searchWordTiming(for: query, base: found) }
            return
        case .notFound:
            status = .notFound
        case .unavailable, nil:
            status = .unavailable
        }
        clock.update(timeline: timeline, playback: playback)
    }
}
