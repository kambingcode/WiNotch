import Foundation
import LyricsKit
import PlaybackCore
import Testing
@testable import SyncEngine

private let timeline = LineTimeline(lines: [
    .init(time: 10, text: "Satu"),
    .init(time: 20, text: "Dua"),
    .init(time: 30, text: "Tiga"),
])

@Suite struct LineTimelineTests {
    @Test func beforeFirstLine() {
        #expect(timeline.step(at: 4) == .init(index: nil, secondsToNext: 6))
    }

    @Test func exactlyOnALineCountsAsThatLine() {
        #expect(timeline.step(at: 20) == .init(index: 1, secondsToNext: 10))
    }

    @Test func betweenLines() {
        #expect(timeline.step(at: 25) == .init(index: 1, secondsToNext: 5))
    }

    @Test func afterLastLine() {
        #expect(timeline.step(at: 99) == .init(index: 2, secondsToNext: nil))
    }

    @Test func emptyTimeline() {
        #expect(LineTimeline(lines: []).step(at: 5) == .init(index: nil, secondsToNext: nil))
    }

    @Test func positiveOffsetShowsLinesEarlier() {
        let lyrics = Lyrics(lines: [LyricsLine(content: "Satu", position: 10)], idTags: [:])
        #expect(LineTimeline(lyrics: lyrics, offset: 0.5).lines[0].time == 9.5)
    }

    @Test func lyricOwnOffsetTagIsApplied() {
        let lyrics = Lyrics(lines: [LyricsLine(content: "Satu", position: 10)], idTags: [:])
        lyrics.offset = 1000
        #expect(LineTimeline(lyrics: lyrics).lines[0].time == 9)
    }

    @Test func disabledLinesAreSkipped() {
        var hidden = LyricsLine(content: "Kredit", position: 1)
        hidden.enabled = false
        let lyrics = Lyrics(lines: [hidden, LyricsLine(content: "Satu", position: 10)], idTags: [:])
        #expect(LineTimeline(lyrics: lyrics).lines.map(\.text) == ["Satu"])
    }
}

private let wordTimeline = LineTimeline(lines: [
    .init(time: 10, text: "Halo dunia", marks: [.init(time: 10, sung: 5), .init(time: 11, sung: 10)]),
    .init(time: 20, text: "Lanjut"),
])

@Suite struct WordTimingTests {
    @Test func wordBeginsAtTheEndOfThePreviousOne() {
        let tag = LyricsLine.Attachments.InlineTimeTag(tags: [
            .init(index: 0, time: 0), .init(index: 5, time: 0.4), .init(index: 10, time: 1),
        ])
        let line = LyricsLine(
            content: "Halo dunia",
            position: 10,
            attachments: LyricsLine.Attachments(attachments: [.timetag: tag])
        )
        let timeline = LineTimeline(lyrics: Lyrics(lines: [line], idTags: [:]))
        #expect(timeline.lines[0].marks == [.init(time: 10, sung: 5), .init(time: 10.4, sung: 10)])
    }

    @Test func offsetMovesWordsWithTheirLine() {
        let tag = LyricsLine.Attachments.InlineTimeTag(tags: [.init(index: 0, time: 0), .init(index: 4, time: 1)])
        let line = LyricsLine(
            content: "Halo",
            position: 10,
            attachments: LyricsLine.Attachments(attachments: [.timetag: tag])
        )
        let timeline = LineTimeline(lyrics: Lyrics(lines: [line], idTags: [:]), offset: 0.5)
        #expect(timeline.lines[0].marks == [.init(time: 9.5, sung: 4)])
    }

    @Test func wordTimingCanBeIgnored() {
        let tag = LyricsLine.Attachments.InlineTimeTag(tags: [.init(index: 0, time: 0), .init(index: 4, time: 1)])
        let line = LyricsLine(
            content: "Halo",
            position: 10,
            attachments: LyricsLine.Attachments(attachments: [.timetag: tag])
        )
        let timeline = LineTimeline(lyrics: Lyrics(lines: [line], idTags: [:]), usesWordTiming: false)
        #expect(timeline.lines[0].marks.isEmpty)
    }

    @Test func stepsThroughWordsThenToTheNextLine() {
        #expect(wordTimeline.step(at: 10.5) == .init(index: 0, secondsToNext: 0.5, sung: 5))
        #expect(wordTimeline.step(at: 11.5) == .init(index: 0, secondsToNext: 8.5, sung: 10))
    }

    @Test func lineWithoutWordTimingHasNoHighlight() {
        #expect(wordTimeline.step(at: 25).sung == nil)
    }

    @Test func wordRunningPastTheNextLineDoesNotDelayIt() {
        let overlapping = LineTimeline(lines: [
            .init(time: 10, text: "Satu", marks: [.init(time: 10, sung: 2), .init(time: 25, sung: 4)]),
            .init(time: 20, text: "Dua"),
        ])
        #expect(overlapping.step(at: 15).secondsToNext == 5)
    }
}

/// Sleeps until the test says so, recording what was requested.
private actor FakeSleeper {
    private(set) var requests: [TimeInterval] = []
    private var waiting: [CheckedContinuation<Void, Error>] = []

    func sleep(_ seconds: TimeInterval) async throws {
        requests.append(seconds)
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func wakeAll() {
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func waitForRequests(_ count: Int) async {
        while requests.count < count {
            await Task.yield()
        }
    }
}

private final class TestTime: @unchecked Sendable {
    var value = Date(timeIntervalSince1970: 1000)
}

@MainActor
@Suite struct LineClockTests {
    private func makeClock(_ time: TestTime, _ sleeper: FakeSleeper) -> LineClock {
        LineClock(now: { time.value }, sleep: { try await sleeper.sleep($0) })
    }

    @Test func showsCurrentAndNextLine() {
        let time = TestTime()
        let clock = makeClock(time, FakeSleeper())
        clock.update(timeline: timeline, playback: .paused(position: 25))

        #expect(clock.moment == .init(index: 1, current: "Dua", next: "Tiga"))
    }

    @Test func pausedHasNothingScheduled() {
        let clock = makeClock(TestTime(), FakeSleeper())
        clock.update(timeline: timeline, playback: .paused(position: 25))
        #expect(!clock.isScheduled)
    }

    @Test func sleepsExactlyUntilTheNextLineThenAdvances() async {
        let time = TestTime()
        let sleeper = FakeSleeper()
        let clock = makeClock(time, sleeper)
        clock.update(timeline: timeline, playback: .playing(startTime: time.value.addingTimeInterval(-15)))

        await sleeper.waitForRequests(1)
        #expect(await sleeper.requests == [5])

        time.value += 5
        await sleeper.wakeAll()
        await sleeper.waitForRequests(2)
        #expect(clock.moment.current == "Dua")
        #expect(await sleeper.requests == [5, 10])
    }

    @Test func wakingEarlyKeepsTheLineAndWaitsAgain() async {
        let time = TestTime()
        let sleeper = FakeSleeper()
        let clock = makeClock(time, sleeper)
        clock.update(timeline: timeline, playback: .playing(startTime: time.value.addingTimeInterval(-15)))
        await sleeper.waitForRequests(1)

        time.value += 4.999
        await sleeper.wakeAll()
        await sleeper.waitForRequests(2)
        #expect(clock.moment.current == "Satu")
        #expect(await sleeper.requests[1] == 0.005)
    }

    @Test func wakesForEveryWord() async {
        let time = TestTime()
        let sleeper = FakeSleeper()
        let clock = makeClock(time, sleeper)
        clock.update(timeline: wordTimeline, playback: .playing(startTime: time.value.addingTimeInterval(-10)))
        #expect(clock.moment.sung == 5)

        await sleeper.waitForRequests(1)
        #expect(await sleeper.requests == [1])

        time.value += 1
        await sleeper.wakeAll()
        await sleeper.waitForRequests(2)
        #expect(clock.moment.sung == 10)
        #expect(clock.moment.current == "Halo dunia")
    }

    @Test func seekReschedulesImmediately() async {
        let time = TestTime()
        let sleeper = FakeSleeper()
        let clock = makeClock(time, sleeper)
        clock.update(timeline: timeline, playback: .playing(startTime: time.value.addingTimeInterval(-15)))
        await sleeper.waitForRequests(1)

        clock.update(timeline: timeline, playback: .playing(startTime: time.value.addingTimeInterval(-28)))
        #expect(clock.moment.current == "Dua")
        await sleeper.waitForRequests(2)
        #expect(await sleeper.requests.last == 2)
    }

    @Test func noLyricsClearsTheLines() {
        let clock = makeClock(TestTime(), FakeSleeper())
        clock.update(timeline: timeline, playback: .paused(position: 25))
        clock.update(timeline: nil, playback: .paused(position: 25))
        #expect(clock.moment == .init())
    }

    @Test func afterTheLastLineNothingIsScheduled() {
        let time = TestTime()
        let clock = makeClock(time, FakeSleeper())
        clock.update(timeline: timeline, playback: .playing(startTime: time.value.addingTimeInterval(-99)))
        #expect(!clock.isScheduled)
        #expect(clock.moment.current == "Tiga")
    }
}
