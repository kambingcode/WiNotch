import Foundation
import LyricsFinder
import LyricsKit
import PlaybackCore
import SyncEngine
import Testing
@testable import AppState
@testable import LyricsFinder

private let songA = PlayedTrack(id: "a", title: "Lagu A", artist: "X", duration: 200)
private let songB = PlayedTrack(id: "b", title: "Lagu B", artist: "Y", duration: 180)

@MainActor
private final class FakeSource: PlayerSource {
    let kind = PlayerKind.spotify
    var isRunning = true
    var permission = AutomationStatus.granted
    var reading = PlayerReading.stopped
    func requestPermission() async {}
    func read() -> PlayerReading { reading }
    func readPosition() -> TimeInterval? { reading.position }
    func send(_ command: PlayerCommand) {}
}

private func lyrics(_ text: String) -> Lyrics {
    Lyrics(lines: [
        LyricsLine(content: text, position: 1),
        LyricsLine(content: "\(text) berikutnya", position: 1000),
    ], idTags: [:])
}

/// Answers per title; a title in `held` waits until released.
private actor FakeLookup: LyricsLookup {
    var answers: [String: LookupResult] = [:]
    var held: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var titles: [String] = []

    func set(_ title: String, _ result: LookupResult, held isHeld: Bool = false) {
        answers[title] = result
        if isHeld { held.insert(title) }
    }

    func release(_ title: String) {
        held.remove(title)
        waiting.removeValue(forKey: title)?.resume()
    }

    func find(_ query: TrackQuery) async throws -> LookupResult {
        titles.append(query.title)
        if held.contains(query.title) {
            await withCheckedContinuation { waiting[query.title] = $0 }
        }
        return answers[query.title] ?? .notFound
    }

    var wordAnswers: [String: FoundLyrics] = [:]
    private(set) var wordSearches: [String] = []

    func setWord(_ title: String, _ result: FoundLyrics) {
        wordAnswers[title] = result
    }

    func findWordTimed(_ query: TrackQuery, base: FoundLyrics) async throws -> FoundLyrics? {
        wordSearches.append(query.title)
        if held.contains("kata \(query.title)") {
            await withCheckedContinuation { waiting["kata \(query.title)"] = $0 }
        }
        return wordAnswers[query.title]
    }

    func hold(_ key: String) {
        held.insert(key)
    }

    var candidatesToReturn: [LyricsCandidate] = []
    private(set) var offsets: [TimeInterval] = []
    private(set) var cleared = false

    func candidates(title: String, artist: String, duration: TimeInterval) async -> [LyricsCandidate] {
        candidatesToReturn
    }

    func use(_ candidate: LyricsCandidate, for query: TrackQuery) async -> FoundLyrics {
        FoundLyrics(lyrics: candidate.lyrics, source: candidate.source, fromCache: false, offset: 0)
    }

    func setOffset(_ offset: TimeInterval, for query: TrackQuery) async {
        offsets.append(offset)
    }

    func clearCache() async {
        cleared = true
    }
}

private func found(_ text: String) -> LookupResult {
    .found(FoundLyrics(lyrics: lyrics(text), source: "Uji", fromCache: false, offset: 0))
}

@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
@Suite struct NowPlayingModelTests {
    private let source = FakeSource()
    private let monitor: PlaybackMonitor
    private let lookup = FakeLookup()
    private let model: NowPlayingModel
    private let defaults: UserDefaults

    init() {
        monitor = PlaybackMonitor(sources: [source])
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        model = NowPlayingModel(monitor: monitor, lookup: lookup, settings: AppSettings(defaults: defaults))
    }

    private func play(_ track: PlayedTrack, at position: TimeInterval = 10) {
        source.reading = PlayerReading(track: track, activity: .playing, position: position)
        monitor.refresh()
    }

    @Test func showsLinesOnceLyricsArrive() async {
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        #expect(model.status == .searching)

        await settle { model.moment.current != nil }
        #expect(model.status == .found(source: "Uji"))
        #expect(model.moment.current == "Satu")
        #expect(model.moment.next == "Satu berikutnya")
    }

    @Test func missingLyricsAreReported() async {
        play(songA)
        await settle { model.status == .notFound }
        #expect(model.moment.current == nil)
    }

    @Test func unreachableServicesAreReported() async {
        await lookup.set("Lagu A", .unavailable)
        play(songA)
        await settle { model.status == .unavailable }
        #expect(model.status == .unavailable)
    }

    @Test func oldSongLinesDisappearOnSongChange() async {
        await lookup.set("Lagu A", found("Satu"))
        await lookup.set("Lagu B", found("Dua"), held: true)
        play(songA)
        await settle { model.moment.current != nil }

        play(songB)
        #expect(model.status == .searching)
        #expect(model.moment.current == nil)
    }

    @Test func lateAnswerForPreviousSongIsIgnored() async {
        await lookup.set("Lagu A", found("Lama"), held: true)
        await lookup.set("Lagu B", found("Baru"))
        play(songA)
        await settle { model.status == .searching }

        play(songB)
        await settle { model.moment.current == "Baru" }
        await lookup.release("Lagu A")
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.moment.current == "Baru")
    }

    @Test func positionUpdatesDoNotSearchAgain() async {
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        await settle { model.moment.current != nil }

        play(songA, at: 50)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(await lookup.titles == ["Lagu A"])
    }

    private func wordLyrics() -> FoundLyrics {
        let tag = LyricsLine.Attachments.InlineTimeTag(tags: [.init(index: 0, time: 0), .init(index: 4, time: 1)])
        let line = LyricsLine(
            content: "Kata",
            position: 1,
            attachments: LyricsLine.Attachments(attachments: [.timetag: tag])
        )
        return FoundLyrics(lyrics: Lyrics(lines: [line], idTags: [:]), source: "Kata", fromCache: false, offset: 0)
    }

    @Test func wordTimingReplacesTheLyricsOnceFound() async {
        await lookup.set("Lagu A", found("Satu"))
        await lookup.setWord("Lagu A", wordLyrics())
        play(songA)

        await settle { model.status == .found(source: "Kata") }
        await settle { model.moment.current == "Kata" }
        #expect(model.moment.current == "Kata")
        #expect(model.moment.sung != nil)
        #expect(model.hasWordTiming)
    }

    @Test func noWordTimingKeepsWhatIsShowing() async {
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        await settle { model.moment.current != nil }
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(await lookup.wordSearches == ["Lagu A"])
        #expect(model.status == .found(source: "Uji"))
        #expect(!model.hasWordTiming)
    }

    @Test func wordTimingCanBeTurnedOff() async {
        model.settings.wordTimingEnabled = false
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        await settle { model.moment.current != nil }
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(await lookup.wordSearches.isEmpty)
    }

    @Test func turningWordTimingOffRemovesTheHighlight() async {
        await lookup.set("Lagu A", found("Satu"))
        await lookup.setWord("Lagu A", wordLyrics())
        model.start()
        play(songA)
        await settle { model.moment.sung != nil }

        model.settings.wordTimingEnabled = false
        await settle { model.moment.sung == nil }
        #expect(model.moment.sung == nil)
        #expect(model.moment.current == "Kata")
    }

    @Test func lateWordTimingForPreviousSongIsIgnored() async {
        await lookup.set("Lagu A", found("Satu"))
        await lookup.set("Lagu B", found("Dua"))
        await lookup.setWord("Lagu A", wordLyrics())
        await lookup.hold("kata Lagu A")
        play(songA)
        await settle { model.moment.current == "Satu" }

        play(songB)
        await settle { model.moment.current == "Dua" }
        await lookup.release("kata Lagu A")
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.moment.current == "Dua")
    }

    @Test func offsetMovesLinesAndIsSaved() async {
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        await settle { model.moment.current != nil }

        model.adjustOffset(by: 0.3)
        #expect(model.offset == 0.3)
        #expect(model.lines[0].time == 0.7)
        await settle { model.offset == 0.3 }
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(await lookup.offsets == [0.3])
    }

    @Test func offsetDoesNothingWithoutLyrics() async {
        play(songA)
        await settle { model.status == .notFound }
        model.adjustOffset(by: 0.3)
        #expect(model.offset == 0)
    }

    @Test func offsetResetsForTheNextSong() async {
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        await settle { model.moment.current != nil }
        model.adjustOffset(by: 0.3)

        play(songB)
        #expect(model.offset == 0)
    }

    @Test func globalOffsetAddsToEverySong() async {
        model.settings.globalOffsetMs = 500
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        await settle { model.moment.current != nil }
        #expect(model.lines[0].time == 0.5)
    }

    @Test func changingGlobalOffsetAppliesToTheCurrentSong() async {
        await lookup.set("Lagu A", found("Satu"))
        model.start()
        play(songA)
        await settle { model.moment.current != nil }

        model.settings.globalOffsetMs = 250
        await settle { model.lines.first?.time == 0.75 }
        #expect(model.lines[0].time == 0.75)
    }

    @Test func manualChoiceReplacesTheLyrics() async {
        play(songA)
        await settle { model.status == .notFound }

        let candidate = LyricsCandidate(
            lyrics: lyrics("Pilihan"), source: "Manual", title: "Lagu A", artist: "X",
            length: nil, lineCount: 2, score: nil
        )
        await model.use(candidate)
        #expect(model.status == .found(source: "Manual"))
        await settle { model.moment.current == "Pilihan" }
        #expect(model.moment.current == "Pilihan")
    }

    @Test func clearingCachePassesThrough() async {
        await model.clearCache()
        #expect(await lookup.cleared)
    }

    @Test func trackWithoutTitleIsNotSearched() async {
        play(PlayedTrack(id: "iklan", title: "", artist: "", duration: 30))
        #expect(model.status == .notFound)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(await lookup.titles.isEmpty)
    }

    @Test func stoppingClearsEverything() async {
        await lookup.set("Lagu A", found("Satu"))
        play(songA)
        await settle { model.moment.current != nil }

        source.reading = .stopped
        monitor.refresh()
        #expect(model.track == nil)
        #expect(model.status == .idle)
        #expect(model.moment == .init())
    }
}

@MainActor
@Suite struct AppSettingsTests {
    private let defaults = UserDefaults(suiteName: UUID().uuidString)!

    @Test func defaultsAreSensible() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.notchEnabled)
        #expect(settings.notchOpensOnHover)
        #expect(settings.notchArtworkGlow)
        #expect(settings.notchGreetingEnabled)
        #expect(settings.notchGreetingSoundEnabled)
        #expect(settings.greetingName.isEmpty)
        #expect(!settings.floatingEnabled)
        #expect(settings.floatingPosition == nil)
        #expect(settings.globalOffsetMs == 0)
    }

    @Test func greetingUsesTheChosenName() {
        let settings = AppSettings(defaults: defaults)
        settings.greetingName = "  Budi "
        #expect(settings.greeting(accountName: "Ani Wijaya") == "Hello, Welcome Budi!")
    }

    @Test func greetingFallsBackToTheAccountsFirstName() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.greeting(accountName: "Ani Wijaya") == "Hello, Welcome Ani!")
        #expect(settings.greeting(accountName: "") == "Hello, Welcome!")
    }

    @Test func changesSurviveARestart() {
        let settings = AppSettings(defaults: defaults)
        settings.globalOffsetMs = -300
        settings.notchOpensOnHover = false
        settings.notchExtraWidth = 40
        settings.floatingAlignment = .right
        settings.floatingPosition = CGPoint(x: 12, y: 34)

        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.globalOffsetMs == -300)
        #expect(!reopened.notchOpensOnHover)
        #expect(reopened.notchExtraWidth == 40)
        #expect(reopened.floatingAlignment == .right)
        #expect(reopened.floatingPosition == CGPoint(x: 12, y: 34))
    }

    @Test func coloursRoundTrip() {
        let hex = "#12345678"
        #expect(ColorCoding.hex(from: ColorCoding.color(from: hex)) == hex)
    }

    @Test func brokenColourFallsBackToWhite() {
        #expect(ColorCoding.hex(from: ColorCoding.color(from: "rusak")) == "#FFFFFFFF")
    }
}

@Suite struct SungTextTests {
    private func fragments(_ text: AttributedString) -> [String] {
        text.runs.map { String(text[$0.range].characters) }
    }

    @Test func withoutWordTimingTheLineIsOnePiece() {
        #expect(fragments(SungText.attributed("Halo dunia", sung: nil, color: .white)) == ["Halo dunia"])
    }

    @Test func sungPartIsSeparated() {
        #expect(fragments(SungText.attributed("Halo dunia", sung: 5, color: .white)) == ["Halo ", "dunia"])
    }

    @Test func nothingSungDimsEverything() {
        #expect(fragments(SungText.attributed("Halo", sung: 0, color: .white)) == ["Halo"])
    }

    @Test func indexBeyondTheLineIsSafe() {
        #expect(fragments(SungText.attributed("Halo", sung: 99, color: .white)) == ["Halo"])
    }

    @Test func emojiCountsAsOneCharacter() {
        #expect(fragments(SungText.attributed("😀a", sung: 1, color: .white)) == ["😀", "a"])
    }
}

@MainActor
@Suite struct PointerWatcherTests {
    private let area = CGRect(x: 100, y: 100, width: 50, height: 50)

    @Test func reportsEnteringAndLeavingOnce() {
        var changes: [Bool] = []
        let frame = area
        let watcher = PointerWatcher(frame: { frame }, onChange: { changes.append($0) })

        watcher.update(CGPoint(x: 10, y: 10))
        watcher.update(CGPoint(x: 120, y: 120))
        watcher.update(CGPoint(x: 121, y: 121))
        watcher.update(CGPoint(x: 10, y: 10))
        #expect(changes == [true, false])
    }

    @Test func followsAWindowThatGrows() {
        var changes: [Bool] = []
        var current = area
        let watcher = PointerWatcher(frame: { current }, onChange: { changes.append($0) })

        watcher.update(CGPoint(x: 120, y: 120))
        current = CGRect(x: 0, y: 0, width: 500, height: 500)
        watcher.update(CGPoint(x: 300, y: 300))
        #expect(changes == [true])
    }
}
