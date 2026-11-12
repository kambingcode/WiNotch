import Foundation
import LyricsKit

/// Removes lines that name the song or its makers instead of being sung.
enum CreditFilter {
    private static let labelPattern = try! NSRegularExpression(
        pattern: #"^\s*(written|composed?|composer|lyrics?|lyricist|music|arrange[dr]|arrangement|produced?|producer|vocals?|background vocals|recorded|recording|mixed|mixing|mastered|mastering|engineer|publisher|guitars?|bass|drums|keyboards?|piano|strings|pencipta|penulis|lirik|musik|aransemen|penyanyi|作词|作词人|作曲|作曲人|编曲|制作|制作人|词|曲|演唱|歌手)(\s+by)?\s*[:：∶]"#,
        options: [.caseInsensitive]
    )

    static func isCredit(_ line: String) -> Bool {
        labelPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Matches a heading such as "Blinding Lights - The Weeknd", in either order.
    static func isHeading(_ line: String, for query: TrackQuery) -> Bool {
        let parts = line.components(separatedBy: " - ")
        guard parts.count == 2 else { return false }
        return (TextMatch.sameTitle(parts[0], query.title) && TextMatch.sameArtist(parts[1], query.artist))
            || (TextMatch.sameArtist(parts[0], query.artist) && TextMatch.sameTitle(parts[1], query.title))
    }

    /// Some services keep the plain title in their metadata and name the
    /// release only in the first lines, as in "Song (Live) - Artist".
    static func announcesVariant(_ lyrics: Lyrics, for query: TrackQuery) -> Bool {
        guard !TextMatch.isVariant(query.title) else { return false }
        return lyrics.lines.prefix(3).contains { line in
            TextMatch.isVariant(line.content) && TextMatch.sameTitle(line.content, query.title)
        }
    }

    static func clean(_ lyrics: Lyrics, for query: TrackQuery) {
        let headingLimit = lyrics.lines.prefix(3).last?.position ?? 0
        lyrics.lines.removeAll { line in
            isCredit(line.content) || (line.position <= headingLimit && isHeading(line.content, for: query))
        }
    }
}
