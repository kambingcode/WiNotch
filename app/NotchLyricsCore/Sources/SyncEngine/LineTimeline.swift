import Foundation
import LyricsKit
import PlaybackCore

/// Lyric lines with their display times after all offsets are applied.
public struct LineTimeline: Equatable, Sendable {
    /// The moment a word begins, and how many characters count as sung from then.
    public struct Mark: Equatable, Sendable {
        public var time: TimeInterval
        public var sung: Int

        public init(time: TimeInterval, sung: Int) {
            self.time = time
            self.sung = sung
        }
    }

    public struct Line: Equatable, Sendable {
        public var time: TimeInterval
        public var text: String
        /// Empty when the lyrics only have line timing.
        public var marks: [Mark]

        public init(time: TimeInterval, text: String, marks: [Mark] = []) {
            self.time = time
            self.text = text
            self.marks = marks
        }
    }

    public struct Step: Equatable, Sendable {
        /// Nil before the first line.
        public var index: Int?
        /// Time until the next word or line. Nil after the last one.
        public var secondsToNext: TimeInterval?
        /// Characters of the active line that have been reached. Nil without word timing.
        public var sung: Int?

        public init(index: Int?, secondsToNext: TimeInterval?, sung: Int? = nil) {
            self.index = index
            self.secondsToNext = secondsToNext
            self.sung = sung
        }
    }

    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines.sorted { $0.time < $1.time }
    }

    /// A positive offset shows lines earlier.
    public init(lyrics: Lyrics, offset: TimeInterval = 0, usesWordTiming: Bool = true) {
        let total = lyrics.timeDelay + offset
        self.init(lines: lyrics.lines.filter(\.enabled).map { line in
            let time = line.position - total
            let tags = usesWordTiming ? line.attachments.timetag?.tags ?? [] : []
            // A tag marks where a word ends, so a word begins at the tag before it.
            let marks = zip(tags, tags.dropFirst()).map { Mark(time: time + $0.time, sung: $1.index) }
            return Line(time: time, text: line.content, marks: marks)
        })
    }

    public func step(at position: TimeInterval) -> Step {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low == 0 ? nil : low - 1
        var nextChange = low < lines.count ? lines[low].time : nil
        var sung: Int?
        if let index, !lines[index].marks.isEmpty {
            let marks = lines[index].marks
            sung = marks.last { $0.time <= position }?.sung ?? 0
            if let upcoming = marks.first(where: { $0.time > position }) {
                nextChange = min(nextChange ?? upcoming.time, upcoming.time)
            }
        }
        return Step(index: index, secondsToNext: nextChange.map { $0 - position }, sung: sung)
    }
}
