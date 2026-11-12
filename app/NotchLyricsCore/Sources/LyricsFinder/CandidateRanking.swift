import Foundation
import LyricsKit

/// The parts of a search result that decide whether it is the right song.
struct CandidateFacts: Equatable {
    var title: String
    var artist: String
    /// Length reported by the service. Many services leave it empty.
    var length: TimeInterval?
    var lineCount: Int
    /// Seconds between the first and last lyric line.
    var span: TimeInterval

    init(title: String, artist: String, length: TimeInterval?, lineCount: Int, span: TimeInterval) {
        self.title = title
        self.artist = artist
        self.length = length
        self.lineCount = lineCount
        self.span = span
    }

    init(_ lyrics: Lyrics) {
        let lines = lyrics.lines.filter { !$0.content.isEmpty }
        self.init(
            title: lyrics.idTags[.title] ?? "",
            artist: lyrics.idTags[.artist] ?? "",
            length: lyrics.length.flatMap { $0 > 0 ? $0 : nil },
            lineCount: lines.count,
            span: (lines.last?.position ?? 0) - (lines.first?.position ?? 0)
        )
    }
}

enum CandidateRanking {
    static let minimumLines = 5
    static let lengthTolerance: TimeInterval = 5

    /// Returns a score where higher is better, or nil to reject the candidate.
    ///
    /// The rules come from the measurements in docs/lyrics-sources.md:
    /// a matching artist and length alone can still be a different song, so
    /// the title must always match. A wrong lyric is worse than no lyric.
    static func score(_ candidate: CandidateFacts, for query: TrackQuery) -> Double? {
        guard candidate.lineCount >= minimumLines,
              TextMatch.sameTitle(candidate.title, query.title) else { return nil }
        if TextMatch.isVariant(candidate.title), !TextMatch.isVariant(query.title) { return nil }

        let artistMatches = TextMatch.sameArtist(candidate.artist, query.artist)
        let artistScore: Double = artistMatches ? 100 : 0

        guard query.duration > 0 else { return artistMatches ? artistScore : nil }

        if let length = candidate.length {
            let difference = abs(length - query.duration)
            return difference <= lengthTolerance ? artistScore + 10 - difference : nil
        }
        // Without a reported length only the line span can confirm the version,
        // and that is too weak to accept a different artist.
        let spanFits = candidate.span >= query.duration * 0.6
            && candidate.span <= query.duration + lengthTolerance
        return artistMatches && spanFits ? artistScore : nil
    }
}
