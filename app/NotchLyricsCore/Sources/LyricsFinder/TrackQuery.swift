import Foundation

/// The song being looked up, as reported by the player.
public struct TrackQuery: Sendable, Hashable {
    public var title: String
    public var artist: String
    /// Length in seconds, or 0 when the player does not know it.
    public var duration: TimeInterval

    public init(title: String, artist: String, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.duration = duration
    }

    /// Title without suffixes such as " - Remastered 2011" or "(feat. X)",
    /// which lyric services rarely include.
    var searchTitle: String { TextMatch.coreTitle(title) }

    /// Spotify can list several artists; services match best on the first.
    var searchArtist: String { TextMatch.artistParts(artist).first ?? artist }
}
