import Foundation
import LyricsKit

/// LRCLIB search that skips malformed entries.
///
/// LyricsKit's own client decodes the whole response at once, so one entry
/// with a null field fails the search even when other entries are usable.
public struct LRCLIBClient: LyricsProvider {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lyrics(for request: LyricsSearchRequest) -> AsyncThrowingStream<Lyrics, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: Self.searchURL(for: request.searchTerm))
                    urlRequest.setValue("NotchLyrics/0.1", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await session.data(for: urlRequest)
                    if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                        throw URLError(.badServerResponse)
                    }
                    // Every entry arrives in one response, so nothing is gained by
                    // limiting them: the right version is often not the first.
                    for lyrics in try Self.parse(data) {
                        continuation.yield(lyrics)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func searchURL(for term: LyricsSearchRequest.SearchTerm) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        switch term {
        case .keyword(let keyword):
            components.queryItems = [URLQueryItem(name: "q", value: keyword)]
        case .info(let title, let artist):
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
        }
        return components.url!
    }

    private struct Entry: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var syncedLyrics: String?
    }

    /// Keeps an entry undecodable as a whole from taking the others with it.
    private struct LenientEntry: Decodable {
        var entry: Entry?

        init(from decoder: Decoder) {
            entry = try? Entry(from: decoder)
        }
    }

    static func parse(_ data: Data) throws -> [Lyrics] {
        try JSONDecoder().decode([LenientEntry].self, from: data).compactMap { item in
            guard let entry = item.entry,
                  let synced = entry.syncedLyrics,
                  let lyrics = Lyrics(synced) else { return nil }
            lyrics.idTags[.title] = entry.trackName
            lyrics.idTags[.artist] = entry.artistName
            lyrics.idTags[.album] = entry.albumName
            lyrics.length = entry.duration
            return lyrics
        }
    }
}
