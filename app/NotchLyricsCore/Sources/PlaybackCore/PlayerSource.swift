import AppKit
import LXMusicPlayer
import ScriptingBridge

/// A music player that can be read.
@MainActor
public protocol PlayerSource: AnyObject {
    var kind: PlayerKind { get }
    var isRunning: Bool { get }
    var permission: AutomationStatus { get }
    /// Shows the system prompt when the user has not answered yet.
    func requestPermission() async
    func read() -> PlayerReading
    /// A single cheap read, for correcting the position of the current song.
    func readPosition() -> TimeInterval?
    func send(_ command: PlayerCommand)
}

/// Reads a player through LXMusicPlayer.
///
/// The LXMusicPlayer object is only created once permission is granted,
/// because creating it reads the player, which would prompt on the main thread.
@MainActor
public final class ScriptingPlayerSource: PlayerSource {
    public let kind: PlayerKind
    public private(set) var permission: AutomationStatus = .undetermined

    private let bundleID: String
    private var player: LXScriptingMusicPlayer?
    private var artwork: (trackID: String, url: URL?)?

    public init(kind: PlayerKind) {
        self.kind = kind
        bundleID = kind == .spotify ? "com.spotify.client" : "com.apple.Music"
    }

    /// Reading a player that has quit would launch it again, so one that is
    /// still shutting down counts as gone.
    public var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    public func requestPermission() async {
        let bundleID = self.bundleID
        permission = await Task.detached {
            AutomationPermission.status(bundleID: bundleID, ask: true)
        }.value
    }

    public func read() -> PlayerReading {
        guard isRunning else { return .stopped }
        // Picks up access given in System Settings without a restart.
        if permission != .granted {
            permission = AutomationPermission.status(bundleID: bundleID, ask: false)
        }
        guard permission == .granted, let player = connectedPlayer() else { return .stopped }

        player.updatePlayerState()
        let activity: PlayerReading.Activity
        switch player.playerState.state() {
        case .playing: activity = .playing
        case .paused, .fastForwarding, .rewinding: activity = .paused
        default: activity = .stopped
        }
        // Permission can be withdrawn while running, and reads then look like
        // a stopped player, so confirm before trusting that.
        if activity == .stopped {
            permission = AutomationPermission.status(bundleID: bundleID, ask: false)
        }

        // LXMusicPlayer's own state lags by up to 1.5 seconds; this read is exact.
        let position = player.originalPlayer.value(forKey: "playerPosition") as? Double
        return PlayerReading(
            track: player.currentTrack.map(playedTrack),
            activity: activity,
            position: position ?? player.playerState.playbackTime()
        )
    }

    public func readPosition() -> TimeInterval? {
        guard isRunning, permission == .granted, let player else { return nil }
        return player.originalPlayer.value(forKey: "playerPosition") as? Double
    }

    public func send(_ command: PlayerCommand) {
        guard permission == .granted, let player = connectedPlayer() else { return }
        let control = player as LXMusicPlayerPlaybackControl
        switch command {
        case .playPause: control.playPause?()
        case .next: control.skipToNextItem?()
        case .previous: control.skipToPreviousItem?()
        case .seek(let position): player.playbackTime = position
        }
    }

    private func connectedPlayer() -> LXScriptingMusicPlayer? {
        if let player { return player }
        let name: LXScriptingMusicPlayer.Name = kind == .spotify ? .spotify : .appleMusic
        player = LXScriptingMusicPlayer(name: name)
        // A hung player must not freeze the app: the default wait is two minutes.
        player?.originalPlayer.timeout = 60 // ticks of 1/60 second
        return player
    }

    private func playedTrack(_ track: LXMusicTrack) -> PlayedTrack {
        PlayedTrack(
            id: track.persistentID,
            title: track.title ?? "",
            artist: track.artist ?? "",
            duration: kind.seconds(fromReportedDuration: track.duration?.doubleValue ?? 0),
            artworkURL: artworkURL(of: track)
        )
    }

    /// Read once per song: this runs on every position correction.
    private func artworkURL(of track: LXMusicTrack) -> URL? {
        if let artwork, artwork.trackID == track.persistentID { return artwork.url }
        let address = kind == .spotify ? track.originalTrack?.value(forKey: "artworkUrl") as? String : nil
        let url = address.flatMap(URL.init(string:))
        artwork = (track.persistentID, url)
        return url
    }
}
