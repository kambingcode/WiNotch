import CryptoKit
import Foundation

/// Lyrics already found, one file per song, with the user's timing offset.
public actor LyricsDiskCache {
    struct Entry: Codable, Equatable {
        var lyrics: String
        var source: String
        var offset: TimeInterval
        /// True once a search for word timing has been answered.
        var wordChecked: Bool?
        /// True when the user picked these lyrics, so they are never replaced.
        var isManual: Bool?
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Apple Music and Spotify can report a song a second or two apart, so
    /// lengths are grouped. A miss here only costs one more search.
    private func fileURL(for query: TrackQuery) -> URL {
        let bucket = Int((query.duration / 5).rounded())
        let key = [
            TextMatch.folded(TextMatch.coreTitle(query.title)),
            TextMatch.folded(query.searchArtist),
            String(bucket),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    func entry(for query: TrackQuery) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(for: query)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func store(_ entry: Entry, for query: TrackQuery) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: fileURL(for: query), options: .atomic)
    }

    /// Forgets every song, including its timing offset.
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Saves a timing offset, in seconds, for a song that has cached lyrics.
    public func setOffset(_ offset: TimeInterval, for query: TrackQuery) throws {
        guard var cached = entry(for: query) else { return }
        cached.offset = offset
        try store(cached, for: query)
    }
}
