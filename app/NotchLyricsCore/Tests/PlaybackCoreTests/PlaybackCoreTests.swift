import Foundation
import Testing
@testable import PlaybackCore

private let songA = PlayedTrack(id: "a", title: "A", artist: "X", duration: 200)
private let songB = PlayedTrack(id: "b", title: "B", artist: "Y", duration: 180)
private let start = Date(timeIntervalSince1970: 1000)

@MainActor
private final class FakeSource: PlayerSource {
    let kind: PlayerKind
    var isRunning = true
    var permission = AutomationStatus.granted
    var reading = PlayerReading.stopped
    var reads = 0
    var prompts = 0
    var answer = AutomationStatus.granted

    init(_ kind: PlayerKind) {
        self.kind = kind
    }

    func requestPermission() async {
        prompts += 1
        permission = answer
    }

    var onRead: (() -> Void)?

    func read() -> PlayerReading {
        reads += 1
        onRead?()
        return reading
    }

    var positionReads = 0
    var positionAnswer = true

    func readPosition() -> TimeInterval? {
        positionReads += 1
        onRead?()
        return positionAnswer ? reading.position : nil
    }

    var commands: [PlayerCommand] = []
    func send(_ command: PlayerCommand) { commands.append(command) }
}

private func playing(_ track: PlayedTrack, at position: TimeInterval) -> PlayerReading {
    PlayerReading(track: track, activity: .playing, position: position)
}

private func paused(_ track: PlayedTrack, at position: TimeInterval) -> PlayerReading {
    PlayerReading(track: track, activity: .paused, position: position)
}

@Suite struct PlayerKindTests {
    @Test func durationsBecomeSeconds() {
        #expect(PlayerKind.spotify.seconds(fromReportedDuration: 271_387) == 271.387)
        #expect(PlayerKind.appleMusic.seconds(fromReportedDuration: 271.387) == 271.387)
    }
}

@Suite struct PositionTrackerTests {
    @Test func positionAdvancesFromStartTime() {
        var tracker = PositionTracker()
        tracker.apply(playing(songA, at: 10), at: start)
        #expect(tracker.state.position(at: start.addingTimeInterval(5)) == 15)
    }

    @Test func smallDifferencesKeepTheStartTime() {
        var tracker = PositionTracker()
        tracker.apply(playing(songA, at: 10), at: start)
        let changed = tracker.apply(playing(songA, at: 11.05), at: start.addingTimeInterval(1))
        #expect(!changed)
    }

    @Test func driftBeyondToleranceIsCorrected() {
        var tracker = PositionTracker()
        tracker.apply(playing(songA, at: 10), at: start)
        let changed = tracker.apply(playing(songA, at: 11.2), at: start.addingTimeInterval(1))
        #expect(changed)
        #expect(abs(tracker.state.position(at: start.addingTimeInterval(1)) - 11.2) < 0.001)
    }

    @Test func seekIsPickedUp() {
        var tracker = PositionTracker()
        tracker.apply(playing(songA, at: 10), at: start)
        tracker.apply(playing(songA, at: 90), at: start.addingTimeInterval(1))
        #expect(abs(tracker.state.position(at: start.addingTimeInterval(1)) - 90) < 0.001)
    }

    @Test func pauseHoldsPosition() {
        var tracker = PositionTracker()
        tracker.apply(playing(songA, at: 10), at: start)
        tracker.apply(paused(songA, at: 12), at: start.addingTimeInterval(2))
        #expect(tracker.state.position(at: start.addingTimeInterval(60)) == 12)
        #expect(!tracker.state.isPlaying)
    }
}

@MainActor
@Suite struct PlaybackMonitorTests {
    private func monitor(_ sources: [PlayerSource]) -> PlaybackMonitor {
        PlaybackMonitor(sources: sources, now: { start })
    }

    @Test func picksThePlayingPlayer() {
        let music = FakeSource(.appleMusic)
        let spotify = FakeSource(.spotify)
        music.reading = paused(songA, at: 5)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([music, spotify])

        monitor.refresh()
        #expect(monitor.snapshot.player == .spotify)
        #expect(monitor.snapshot.track == songB)
    }

    @Test func keepsTheActivePlayerWhenBothPlay() {
        let music = FakeSource(.appleMusic)
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([music, spotify])
        monitor.refresh()

        music.reading = playing(songA, at: 1)
        monitor.refresh()
        #expect(monitor.snapshot.player == .spotify)
    }

    @Test func pausedPlayerStaysActive() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([FakeSource(.appleMusic), spotify])
        monitor.refresh()

        spotify.reading = paused(songB, at: 12)
        monitor.refresh()
        #expect(monitor.snapshot.player == .spotify)
        #expect(monitor.snapshot.state == .paused(position: 12))
    }

    @Test func timerOnlyRunsWhilePlaying() {
        let spotify = FakeSource(.spotify)
        let monitor = monitor([spotify])
        monitor.refresh()
        #expect(!monitor.isPolling)

        spotify.reading = playing(songB, at: 10)
        monitor.refresh()
        #expect(monitor.isPolling)

        spotify.reading = paused(songB, at: 11)
        monitor.refresh()
        #expect(!monitor.isPolling)
    }

    @Test func quittingPlayerClearsTheSong() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([spotify])
        monitor.refresh()

        spotify.isRunning = false
        spotify.reading = .stopped
        monitor.refresh()
        #expect(monitor.snapshot == PlaybackSnapshot())
    }

    @Test func newSongResetsTheStartTime() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songA, at: 100)
        let monitor = monitor([spotify])
        monitor.refresh()

        spotify.reading = playing(songB, at: 100.05)
        monitor.refresh()
        #expect(monitor.snapshot.track == songB)
    }

    @Test func notifiesOnlyOnChange() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([spotify])
        var changes = 0
        monitor.onChange = { _ in changes += 1 }

        monitor.refresh()
        monitor.refresh()
        #expect(changes == 1)
    }

    @Test func refusedPlayerIsReportedNotTreatedAsPositionZero() async {
        let spotify = FakeSource(.spotify)
        spotify.permission = .undetermined
        spotify.answer = .denied
        let monitor = monitor([spotify])

        await monitor.askPermissionThenRefresh()
        #expect(spotify.prompts == 1)
        #expect(monitor.snapshot.blockedPlayers == [.spotify])
        #expect(monitor.snapshot.track == nil)
    }

    @Test func commandsGoToTheActivePlayerOnly() {
        let music = FakeSource(.appleMusic)
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([music, spotify])
        monitor.refresh()

        monitor.send(.next)
        #expect(spotify.commands == [.next])
        #expect(music.commands.isEmpty)
    }

    @Test func playerStillLaunchingIsAskedAgainOnItsNextNotification() async {
        let spotify = FakeSource(.spotify)
        spotify.permission = .playerNotRunning
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([spotify])

        monitor.refresh()
        for _ in 0..<100 where monitor.snapshot.track == nil {
            await Task.yield()
        }
        #expect(spotify.prompts == 1)
        #expect(monitor.snapshot.track == songB)
    }

    @Test func refusedPlayerIsNotAskedAgainOnEveryRefresh() async {
        let spotify = FakeSource(.spotify)
        spotify.permission = .denied
        let monitor = monitor([spotify])

        monitor.refresh()
        await Task.yield()
        #expect(spotify.prompts == 0)
    }

    @Test func playerThatNeverAnswersDoesNotLoop() async {
        let spotify = FakeSource(.spotify)
        spotify.permission = .playerNotRunning
        spotify.answer = .playerNotRunning
        let monitor = monitor([spotify])

        monitor.refresh()
        for _ in 0..<100 { await Task.yield() }
        #expect(spotify.prompts == 1)
    }

    @Test func slowPlayerIsLeftAloneForAWhile() {
        var time = start
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = PlaybackMonitor(sources: [spotify], now: { time })
        monitor.refresh()

        spotify.onRead = { time += 1 }
        monitor.correctPosition()
        spotify.onRead = nil
        let readsAfterSlowOne = spotify.positionReads

        for _ in 0..<PlaybackMonitor.ticksToSkipAfterSlowRead {
            monitor.correctPosition()
        }
        #expect(spotify.positionReads == readsAfterSlowOne)

        monitor.correctPosition()
        #expect(spotify.positionReads == readsAfterSlowOne + 1)
    }

    @Test func mostTicksOnlyReadThePosition() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([spotify])
        monitor.refresh()
        let fullReads = spotify.reads

        for _ in 0..<(PlaybackMonitor.ticksBetweenFullReads - 1) {
            monitor.correctPosition()
        }
        #expect(spotify.reads == fullReads)
        #expect(spotify.positionReads == PlaybackMonitor.ticksBetweenFullReads - 1)

        monitor.correctPosition()
        #expect(spotify.reads == fullReads + 1)
    }

    @Test func positionTicksStillCorrectDrift() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([spotify])
        monitor.refresh()

        spotify.reading = playing(songB, at: 90)
        monitor.correctPosition()
        #expect(monitor.snapshot.state.position(at: start) == 90)
        #expect(monitor.snapshot.track == songB)
    }

    @Test func missedPauseIsCaughtByTheFullRead() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([spotify])
        monitor.refresh()

        spotify.reading = paused(songB, at: 12)
        for _ in 0..<PlaybackMonitor.ticksBetweenFullReads {
            monitor.correctPosition()
        }
        #expect(monitor.snapshot.state == .paused(position: 12))
    }

    @Test func playerThatCannotAnswerGetsAFullRead() {
        let spotify = FakeSource(.spotify)
        spotify.reading = playing(songB, at: 10)
        let monitor = monitor([spotify])
        monitor.refresh()
        let fullReads = spotify.reads

        spotify.positionAnswer = false
        monitor.correctPosition()
        #expect(spotify.reads == fullReads + 1)
    }

    @Test func playerThatIsNotRunningIsNotPrompted() async {
        let spotify = FakeSource(.spotify)
        spotify.isRunning = false
        spotify.permission = .undetermined

        await monitor([spotify]).askPermissionThenRefresh()
        #expect(spotify.prompts == 0)
    }
}
