import Foundation
import LyricsKit

/// Decides whether word-timed lyrics can replace lyrics already shown.
///
/// Word timing comes from services that often carry a different recording of
/// the same song, up to 50 seconds out in testing. The limits come from the
/// measurements in docs/lyrics-sources.md.
enum WordTimingCheck {
    /// Share of sung lines that must have word timing.
    static let minimumCoverage = 0.8
    static let minimumMatchedLines = 5
    /// Typical lines started 0.2 seconds after LRCLIB's, up to about 0.6.
    static let largestShift: TimeInterval = 0.75
    /// How far lines may stray from that shift, which catches re-edited recordings.
    static let largestSpread: TimeInterval = 0.35

    static func hasWordTiming(_ lyrics: Lyrics) -> Bool {
        let sung = lyrics.lines.filter { !$0.content.isEmpty }
        guard !sung.isEmpty else { return false }
        let timed = sung.filter { ($0.attachments.timetag?.tags.count ?? 0) > 1 }
        return Double(timed.count) / Double(sung.count) >= minimumCoverage
    }

    static func fits(_ candidate: Lyrics, base: Lyrics) -> Bool {
        var baseTimes: [String: [TimeInterval]] = [:]
        for line in base.lines where !line.content.isEmpty {
            baseTimes[TextMatch.folded(line.content), default: []].append(line.position)
        }
        let shifts: [TimeInterval] = candidate.lines.compactMap { line in
            guard !line.content.isEmpty, let times = baseTimes[TextMatch.folded(line.content)] else { return nil }
            return times.map { line.position - $0 }.min { abs($0) < abs($1) }
        }
        guard shifts.count >= minimumMatchedLines else { return false }
        let shift = median(shifts)
        return abs(shift) <= largestShift
            && median(shifts.map { abs($0 - shift) }) <= largestSpread
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        values.sorted()[values.count / 2]
    }
}
