import Foundation
import LyricsKit
import Testing
@testable import LyricsFinder

private let song = TrackQuery(title: "Lagu Uji", artist: "Penyanyi", duration: 200)

private func sampleLyrics(title: String = "Lagu Uji", artist: String = "Penyanyi", length: Double? = 200) -> Lyrics {
    let lines = (0..<20).map { LyricsLine(content: "Baris \($0)", position: Double($0) * 9 + 5) }
    let lyrics = Lyrics(lines: lines, idTags: [.title: title, .artist: artist])
    lyrics.length = length
    return lyrics
}

/// The same song as `sampleLyrics`, with every word timed.
private func wordLyrics(shift: Double = 0.2, timed: Bool = true) -> Lyrics {
    let lines = (0..<20).map { index -> LyricsLine in
        let text = "Baris \(index)"
        guard timed else { return LyricsLine(content: text, position: Double(index) * 9 + 5 + shift) }
        let tag = LyricsLine.Attachments.InlineTimeTag(tags: [
            .init(index: 0, time: 0), .init(index: 6, time: 0.5), .init(index: text.count, time: 1),
        ], duration: 1)
        return LyricsLine(
            content: text,
            position: Double(index) * 9 + 5 + shift,
            attachments: LyricsLine.Attachments(attachments: [.timetag: tag])
        )
    }
    let lyrics = Lyrics(lines: lines, idTags: [.title: "Lagu Uji", .artist: "Penyanyi"])
    lyrics.length = 200
    return lyrics
}

private final class FakeProvider: LyricsProvider, @unchecked Sendable {
    enum Behaviour {
        case results(@Sendable () -> [Lyrics])
        case failure(Error)
        case hang
    }

    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    let behaviour: Behaviour

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func lyrics(for request: LyricsSearchRequest) -> AsyncThrowingStream<Lyrics, Error> {
        lock.withLock { count += 1 }
        let behaviour = self.behaviour
        return AsyncThrowingStream { continuation in
            switch behaviour {
            case .results(let make):
                make().forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .hang:
                let task = Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private func temporaryCache() -> LyricsDiskCache {
    LyricsDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

private func source(_ name: String, _ provider: FakeProvider) -> LyricsSource {
    LyricsSource(name: name, provider: provider)
}

private func foundSource(_ result: LookupResult) -> String? {
    if case .found(let found) = result { return found.source }
    return nil
}

@Suite struct LyricsFinderTests {
    @Test func primaryHitNeverCallsBackup() async throws {
        let primary = FakeProvider(.results { [sampleLyrics()] })
        let backup = FakeProvider(.results { [sampleLyrics()] })
        let finder = LyricsFinder(tiers: [[source("A", primary)], [source("B", backup)]], cache: temporaryCache())

        #expect(foundSource(try await finder.find(song)) == "A")
        #expect(backup.calls == 0)
    }

    @Test func wrongSongFromPrimaryFallsBackToBackup() async throws {
        let primary = FakeProvider(.results { [sampleLyrics(title: "Lagu Lain")] })
        let backup = FakeProvider(.results { [sampleLyrics()] })
        let finder = LyricsFinder(tiers: [[source("A", primary)], [source("B", backup)]], cache: temporaryCache())

        #expect(foundSource(try await finder.find(song)) == "B")
    }

    @Test func picksBestCandidateNotTheFirst() async throws {
        let provider = FakeProvider(.results {
            [sampleLyrics(artist: "Orang Lain", length: 200), sampleLyrics(length: 201), sampleLyrics(length: 200)]
        })
        let finder = LyricsFinder(tiers: [[source("A", provider)]], cache: temporaryCache())

        guard case .found(let found) = try await finder.find(song) else {
            Issue.record("Expected lyrics")
            return
        }
        #expect(found.lyrics.idTags[.artist] == "Penyanyi")
        #expect(found.lyrics.length == 200)
    }

    @Test func skipsVariantHiddenBehindPlainTitle() async throws {
        let provider = FakeProvider(.results {
            let hidden = sampleLyrics()
            hidden.lines.insert(LyricsLine(content: "Lagu Uji (Live) - Penyanyi", position: 0), at: 0)
            return [hidden]
        })
        let finder = LyricsFinder(tiers: [[source("A", provider)]], cache: temporaryCache())

        guard case .notFound = try await finder.find(song) else {
            Issue.record("A hidden live version should be rejected")
            return
        }
    }

    @Test func secondLookupUsesCacheWithoutCallingServices() async throws {
        let provider = FakeProvider(.results { [sampleLyrics()] })
        let finder = LyricsFinder(tiers: [[source("A", provider)]], cache: temporaryCache())

        _ = try await finder.find(song)
        guard case .found(let cached) = try await finder.find(song) else {
            Issue.record("Expected cached lyrics")
            return
        }
        #expect(provider.calls == 1)
        #expect(cached.fromCache)
        #expect(cached.source == "A")
        #expect(cached.lyrics.lines.count == 20)
        #expect(cached.lyrics.lines[3].position == 32)
    }

    @Test func offsetSurvivesInCache() async throws {
        let cache = temporaryCache()
        let finder = LyricsFinder(tiers: [[source("A", FakeProvider(.results { [sampleLyrics()] }))]], cache: cache)

        _ = try await finder.find(song)
        try await cache.setOffset(0.4, for: song)
        guard case .found(let cached) = try await finder.find(song) else {
            Issue.record("Expected cached lyrics")
            return
        }
        #expect(cached.offset == 0.4)
    }

    @Test func manualSearchShowsRejectedResultsAfterGoodOnes() async {
        let provider = FakeProvider(.results { [sampleLyrics(title: "Lagu Lain"), sampleLyrics()] })
        let backup = FakeProvider(.results { [sampleLyrics(length: 300)] })
        let finder = LyricsFinder(tiers: [[source("A", provider)], [source("B", backup)]], cache: temporaryCache())

        let results = await finder.candidates(title: "Lagu Uji", artist: "Penyanyi", duration: 200)
        #expect(results.count == 3)
        #expect(results[0].isLikelyMatch)
        #expect(results[0].title == "Lagu Uji")
        #expect(!results[2].isLikelyMatch)
        #expect(backup.calls == 1)
    }

    @Test func chosenLyricsAreUsedFromThenOn() async throws {
        let provider = FakeProvider(.results { [sampleLyrics(title: "Lagu Lain")] })
        let finder = LyricsFinder(tiers: [[source("A", provider)]], cache: temporaryCache())

        let results = await finder.candidates(title: "Lagu Lain", artist: "Penyanyi", duration: 200)
        _ = await finder.use(results[0], for: song)

        guard case .found(let found) = try await finder.find(song) else {
            Issue.record("Expected the chosen lyrics")
            return
        }
        #expect(found.fromCache)
        #expect(provider.calls == 1)
    }

    @Test func clearingTheCacheForgetsSongs() async throws {
        let provider = FakeProvider(.results { [sampleLyrics()] })
        let finder = LyricsFinder(tiers: [[source("A", provider)]], cache: temporaryCache())

        _ = try await finder.find(song)
        await finder.clearCache()
        _ = try await finder.find(song)
        #expect(provider.calls == 2)
    }

    private func foundBase(_ finder: LyricsFinder) async throws -> FoundLyrics {
        guard case .found(let found) = try await finder.find(song) else {
            throw CancellationError()
        }
        return found
    }

    private func finder(word: FakeProvider, cache: LyricsDiskCache? = nil) -> LyricsFinder {
        LyricsFinder(
            tiers: [[source("A", FakeProvider(.results { [sampleLyrics()] }))]],
            wordSources: [source("W", word)],
            cache: cache ?? temporaryCache()
        )
    }

    @Test func wordTimedLyricsReplaceAndAreRemembered() async throws {
        let word = FakeProvider(.results { [wordLyrics()] })
        let finder = finder(word: word)
        let base = try await foundBase(finder)

        let better = try await finder.findWordTimed(song, base: base)
        #expect(better?.source == "W")
        #expect(better?.hasWordTiming == true)

        let cached = try await foundBase(finder)
        #expect(cached.fromCache)
        #expect(cached.hasWordTiming)
        #expect(cached.lyrics.lines[0].attachments.timetag?.tags.count == 3)
        #expect(try await finder.findWordTimed(song, base: cached) == nil)
        #expect(word.calls == 1)
    }

    @Test func differentRecordingIsRejected() async throws {
        let finder = finder(word: FakeProvider(.results { [wordLyrics(shift: 24)] }))
        let base = try await foundBase(finder)
        #expect(try await finder.findWordTimed(song, base: base) == nil)
    }

    @Test func lyricsWithoutWordTimingAreRejected() async throws {
        let finder = finder(word: FakeProvider(.results { [wordLyrics(timed: false)] }))
        let base = try await foundBase(finder)
        #expect(try await finder.findWordTimed(song, base: base) == nil)
    }

    @Test func nothingFoundIsNotSearchedAgain() async throws {
        let word = FakeProvider(.results { [] })
        let finder = finder(word: word)
        let base = try await foundBase(finder)

        _ = try await finder.findWordTimed(song, base: base)
        _ = try await finder.findWordTimed(song, base: base)
        #expect(word.calls == 1)
    }

    @Test func failedWordSearchIsRetried() async throws {
        let word = FakeProvider(.failure(URLError(.notConnectedToInternet)))
        let finder = finder(word: word)
        let base = try await foundBase(finder)

        _ = try await finder.findWordTimed(song, base: base)
        _ = try await finder.findWordTimed(song, base: base)
        #expect(word.calls == 2)
    }

    @Test func chosenLyricsAreNeverReplaced() async throws {
        let word = FakeProvider(.results { [wordLyrics()] })
        let finder = finder(word: word)
        let results = await finder.candidates(title: "Lagu Uji", artist: "Penyanyi", duration: 200)
        let chosen = await finder.use(results[0], for: song)

        #expect(try await finder.findWordTimed(song, base: chosen) == nil)
        #expect(word.calls == 0)
    }

    @Test func offsetSurvivesTheReplacement() async throws {
        let cache = temporaryCache()
        let finder = finder(word: FakeProvider(.results { [wordLyrics()] }), cache: cache)
        let base = try await foundBase(finder)
        try await cache.setOffset(0.4, for: song)

        let better = try await finder.findWordTimed(song, base: base)
        #expect(better?.offset == 0.4)
    }

    @Test func entriesFromBeforeWordTimingStillLoad() throws {
        let old = #"{"lyrics":"[00:01.00]Satu","source":"LRCLIB","offset":0.5}"#
        let entry = try JSONDecoder().decode(LyricsDiskCache.Entry.self, from: Data(old.utf8))
        #expect(entry.offset == 0.5)
        #expect(entry.wordChecked == nil)
    }

    @Test func emptyAnswersMeanNotFound() async throws {
        let finder = LyricsFinder(tiers: [[source("A", FakeProvider(.results { [] }))]], cache: temporaryCache())
        guard case .notFound = try await finder.find(song) else {
            Issue.record("Expected notFound")
            return
        }
    }

    @Test func networkFailureMeansUnavailableAndIsNotCached() async throws {
        let provider = FakeProvider(.failure(URLError(.notConnectedToInternet)))
        let finder = LyricsFinder(tiers: [[source("A", provider)]], cache: temporaryCache())

        guard case .unavailable = try await finder.find(song) else {
            Issue.record("Expected unavailable")
            return
        }
        _ = try await finder.find(song)
        #expect(provider.calls == 2)
    }

    @Test func emptyResultErrorDoesNotCountAsFailure() async throws {
        let provider = FakeProvider(.failure(LyricsProviderError.processingFailed(reason: "no candidates")))
        let finder = LyricsFinder(tiers: [[source("A", provider)]], cache: temporaryCache(), failureLimit: 1)

        guard case .notFound = try await finder.find(song) else {
            Issue.record("Expected notFound")
            return
        }
        _ = try await finder.find(song)
        #expect(provider.calls == 2)
    }

    @Test func failingServiceIsPausedThenRetried() async throws {
        let clock = Clock()
        let provider = FakeProvider(.failure(URLError(.timedOut)))
        let finder = LyricsFinder(
            tiers: [[source("A", provider)]], cache: temporaryCache(),
            failureLimit: 2, pause: 300, now: { clock.date }
        )

        _ = try await finder.find(song)
        _ = try await finder.find(song)
        #expect(provider.calls == 2)

        guard case .unavailable = try await finder.find(song) else {
            Issue.record("A paused service should report unavailable")
            return
        }
        #expect(provider.calls == 2)

        clock.advance(301)
        _ = try await finder.find(song)
        #expect(provider.calls == 3)
    }

    @Test func slowServiceTimesOutAndBackupStillAnswers() async throws {
        let backup = FakeProvider(.results { [sampleLyrics()] })
        let finder = LyricsFinder(
            tiers: [[source("A", FakeProvider(.hang))], [source("B", backup)]],
            cache: temporaryCache(), timeout: 0.1
        )
        #expect(foundSource(try await finder.find(song)) == "B")
    }

    @Test func firstAcceptableAnswerStopsTheRestOfTheTier() async throws {
        let finder = LyricsFinder(
            tiers: [[source("Slow", FakeProvider(.hang)), source("Fast", FakeProvider(.results { [sampleLyrics()] }))]],
            cache: temporaryCache(), timeout: 20
        )
        let start = Date()
        #expect(foundSource(try await finder.find(song)) == "Fast")
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func cancellingStopsWithoutCaching() async throws {
        let cache = temporaryCache()
        let hanging = FakeProvider(.hang)
        let finder = LyricsFinder(tiers: [[source("A", hanging)]], cache: cache, timeout: 20)

        let task = Task { try await finder.find(song) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cache.entry(for: song) == nil)
    }
}
