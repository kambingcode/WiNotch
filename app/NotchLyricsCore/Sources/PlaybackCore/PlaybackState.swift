import Foundation

public enum PlayerKind: String, CaseIterable, Sendable {
    case appleMusic = "Apple Music"
    case spotify = "Spotify"

    /// Spotify reports track length in milliseconds, Apple Music in seconds.
    func seconds(fromReportedDuration duration: Double) -> TimeInterval {
        self == .spotify ? duration / 1000 : duration
    }
}

public struct PlayedTrack: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var duration: TimeInterval
    public var artworkURL: URL?

    public init(id: String, title: String, artist: String, duration: TimeInterval, artworkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.artworkURL = artworkURL
    }
}

public enum PlayerCommand: Equatable, Sendable {
    case playPause
    case next
    case previous
    case seek(TimeInterval)
}

/// While playing only the start time is kept, so the position can be worked
/// out at any moment without asking the player.
public enum PlaybackState: Equatable, Sendable {
    case stopped
    case paused(position: TimeInterval)
    case playing(startTime: Date)

    public func position(at now: Date) -> TimeInterval {
        switch self {
        case .stopped: return 0
        case .paused(let position): return position
        case .playing(let startTime): return now.timeIntervalSince(startTime)
        }
    }

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }
}

/// One read of a player.
public struct PlayerReading: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        case stopped, paused, playing
    }

    public var track: PlayedTrack?
    public var activity: Activity
    public var position: TimeInterval

    public init(track: PlayedTrack?, activity: Activity, position: TimeInterval) {
        self.track = track
        self.activity = activity
        self.position = position
    }

    public static let stopped = PlayerReading(track: nil, activity: .stopped, position: 0)
}

/// Turns repeated player reads into a steady start time.
public struct PositionTracker {
    /// LXMusicPlayer tolerates 1.5 seconds of error, far above the 150 ms
    /// target. Reads measured within a few milliseconds of the clock in
    /// docs/architecture.md, so a tight limit does not cause jitter.
    public static let tolerance: TimeInterval = 0.1

    public private(set) var state: PlaybackState = .stopped

    public init() {}

    /// Returns true when the state changed.
    @discardableResult
    public mutating func apply(_ reading: PlayerReading, at now: Date) -> Bool {
        let next: PlaybackState
        switch reading.activity {
        case .stopped:
            next = .stopped
        case .paused:
            next = .paused(position: reading.position)
        case .playing:
            let startTime = now.addingTimeInterval(-reading.position)
            if case .playing(let current) = state,
               abs(current.timeIntervalSince(startTime)) <= Self.tolerance {
                return false
            }
            next = .playing(startTime: startTime)
        }
        guard next != state else { return false }
        state = next
        return true
    }

    public mutating func reset() {
        state = .stopped
    }
}
