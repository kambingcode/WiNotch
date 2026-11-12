import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NotchUI

/// Wakes sleeping tasks only when told to, so timing is exact.
private actor FakeSleeper {
    private var waiting: [(TimeInterval, CheckedContinuation<Void, Error>)] = []

    func sleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { waiting.append((seconds, $0)) }
    }

    var pending: [TimeInterval] { waiting.map(\.0) }

    /// Completes the waits of this length.
    func finish(_ seconds: TimeInterval) {
        let due = waiting.filter { $0.0 == seconds }
        waiting.removeAll { $0.0 == seconds }
        due.forEach { $0.1.resume() }
    }

    func waitUntilPending(_ seconds: TimeInterval) async {
        while !waiting.contains(where: { $0.0 == seconds }) {
            await Task.yield()
        }
    }
}

@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
        await Task.yield()
    }
}

@Suite struct NotchGeometryTests {
    private let frame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let visible = CGRect(x: 0, y: 0, width: 1800, height: 1131)

    private var measured: NotchGeometry {
        NotchGeometry(frame: frame, visibleFrame: visible, safeAreaTop: 38, auxiliaryLeft: 790, auxiliaryRight: 790)
    }

    @Test func matchesTheMeasuredScreen() {
        #expect(measured.idle == CGSize(width: 230, height: 38))
        #expect(measured.hasNotch)
    }

    @Test func appearancesGrowFromTheHardwareNotch() {
        #expect(measured.size(for: .playing) == CGSize(width: 420, height: 66))
        #expect(measured.size(for: .title) == CGSize(width: 444, height: 79))
        #expect(measured.size(for: .open) == CGSize(width: 720, height: 198))
    }

    @Test func extraWidthChangesClosedSizesOnly() {
        var wider = measured
        wider.extraWidth = 40
        #expect(wider.size(for: .playing).width == 460)
        #expect(wider.size(for: .title).width == 484)
        #expect(wider.size(for: .idle).width == 230)
        #expect(wider.size(for: .open).width == 720)
    }

    @Test func panelCentreIsTheSameAtEverySize() {
        let odd = NotchGeometry(idle: CGSize(width: 231.5, height: 38), hasNotch: true)
        for appearance in [NotchAppearance.idle, .playing, .title, .open] {
            #expect(odd.panelFrame(for: appearance, on: frame).midX == frame.midX)
        }
    }

    @Test func screenWithoutNotchUsesMenuBarHeight() {
        let geometry = NotchGeometry(frame: frame, visibleFrame: visible, safeAreaTop: 0, auxiliaryLeft: nil, auxiliaryRight: nil)
        #expect(geometry.idle == CGSize(width: 195, height: 38))
        #expect(!geometry.hasNotch)
    }

    @Test func noScreenFallsBack() {
        #expect(NotchGeometry(screen: nil).idle == CGSize(width: 195, height: 30))
    }

    @Test func greetingStartsFromTheHardwareNotchAndDropsStraightDown() {
        let geometry = NotchGeometry(idle: CGSize(width: 230, height: 38), hasNotch: true)
        #expect(geometry.size(for: .asleep) == CGSize(width: 220, height: 38))
        #expect(geometry.size(for: .greeting).width == 220)
        #expect(geometry.topFlare(for: .asleep) == 0)
        #expect(geometry.topFlare(for: .greeting) == 0)
        #expect(geometry.topFlare(for: .idle) == NotchGeometry.topFlare)
    }

    @Test func greetingStartsFlatWithoutANotch() {
        let geometry = NotchGeometry(idle: CGSize(width: 195, height: 30), hasNotch: false)
        #expect(geometry.size(for: .asleep) == CGSize(width: 195, height: 0))
    }

    @Test func canvasFitsEveryAppearance() {
        var geometry = NotchGeometry(idle: CGSize(width: 180, height: 32), hasNotch: true)
        for extraWidth: CGFloat in [-150, 0, 300] {
            geometry.extraWidth = extraWidth
            for appearance in [NotchAppearance.idle, .playing, .title, .greeting, .open] {
                let panel = geometry.panelFrame(for: appearance, on: .zero)
                #expect(panel.width <= geometry.canvasSize.width)
                #expect(panel.height <= geometry.canvasSize.height)
            }
        }
    }

    @MainActor
    @Test func canvasStaysCentredAtTheTopOfThePanel() {
        let canvas = NotchCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        canvas.addSubview(content)
        canvas.setFrameSize(CGSize(width: 100, height: 40))
        #expect(content.frame == CGRect(x: -100, y: -160, width: 300, height: 200))
    }

    @Test func panelTouchesTheTopAndStaysCentred() {
        for appearance in [NotchAppearance.idle, .playing, .title, .greeting, .open] {
            let panel = measured.panelFrame(for: appearance, on: frame)
            #expect(panel.maxY == frame.maxY)
            #expect(abs(panel.midX - frame.midX) <= 0.5)
            #expect(panel.width >= measured.size(for: appearance).width)
        }
    }

    @Test func panelFollowsAScreenPlacedElsewhere() {
        let external = CGRect(x: -2000, y: 300, width: 1800, height: 1169)
        let panel = measured.panelFrame(for: .idle, on: external)
        #expect(panel.maxY == external.maxY)
        #expect(abs(panel.midX - external.midX) <= 0.5)
    }
}

@Suite struct GreetingTimelineTests {
    private func pose(_ time: TimeInterval) -> GreetingTimeline.Pose { GreetingTimeline.pose(at: time) }

    @Test func startsEmpty() {
        #expect(pose(0).eyesOpacity == 0)
        #expect(pose(0).textOpacity == 0)
    }

    @Test func eyesAppearAsClosedLinesThenOpen() {
        #expect(pose(0.82).eyesOpacity == 1)
        #expect(pose(0.82).openness < 0.1)
        #expect(pose(1.2).openness == 1)
    }

    @Test func eyesGlanceLeftThenRightThenBack() {
        #expect(pose(1.2).glance == 0)
        #expect(pose(1.8).glance == -1)
        #expect(pose(2.6).glance == 1)
        #expect(pose(3.1).glance == 0)
    }

    @Test func blinkClosesAndReopens() {
        #expect(pose(3.1).openness == 1)
        #expect(pose(3.5).openness < 0.1)
        #expect(pose(3.8).openness == 1)
    }

    @Test func smileHoldsForASecondBeforeTheEyesFade() {
        #expect(pose(3.8).smile == 0)
        #expect(pose(4.6).smile == 1)
        #expect(pose(5.6).smile == 1)
        #expect(pose(5.6).eyesOpacity == 1)
    }

    @Test func textReplacesTheEyesAndStaysForThreeSeconds() {
        #expect(pose(5.6).textOpacity == 0)
        #expect(pose(6.15).eyesOpacity == 0)
        #expect(pose(6.15).textOpacity == 1)
        #expect(abs(GreetingTimeline.duration - 6.15 - 3) < 0.001)
    }

    @Test func soundsMarkTheEyesOpeningAndTheTextAppearing() {
        let times = GreetingTimeline.sounds.map(\.time)
        #expect(times.count == 2)
        #expect(pose(times[0]).openness < 0.1)
        #expect(pose(times[0] + 0.1).openness == 1)
        #expect(pose(times[1]).textOpacity == 0)
        #expect(pose(times[1] + 0.5).textOpacity == 1)
    }

    @Test func reducedMotionShowsOnlyTheText() {
        let pose = GreetingTimeline.pose(at: 2, reducesMotion: true)
        #expect(pose.eyesOpacity == 0)
        #expect(pose.textOpacity == 1)
    }
}

@MainActor
@Suite struct NotchPresentationTests {
    private let sleeper = FakeSleeper()
    private let presentation: NotchPresentation

    init() {
        let sleeper = self.sleeper
        presentation = NotchPresentation(sleep: { try await sleeper.sleep($0) })
    }

    private func finish(_ seconds: TimeInterval) async {
        await sleeper.waitUntilPending(seconds)
        await sleeper.finish(seconds)
    }

    @Test func startsIdle() {
        #expect(presentation.appearance == .idle)
    }

    @Test func newSongShowsTitleThenLyrics() async {
        presentation.update(trackID: "a", isPlaying: true)
        #expect(presentation.appearance == .title)

        await finish(NotchPresentation.titleDuration)
        await settle { presentation.appearance == .playing }
        #expect(presentation.appearance == .playing)
    }

    @Test func positionUpdatesDoNotReplayTheTitle() async {
        presentation.update(trackID: "a", isPlaying: true)
        await finish(NotchPresentation.titleDuration)
        await settle { presentation.appearance == .playing }

        presentation.update(trackID: "a", isPlaying: true)
        #expect(presentation.appearance == .playing)
    }

    @Test func pauseDimsThenCollapses() async {
        presentation.update(trackID: "a", isPlaying: true)
        await finish(NotchPresentation.titleDuration)
        await settle { presentation.appearance == .playing }

        presentation.update(trackID: "a", isPlaying: false)
        #expect(presentation.isDimmed)
        #expect(presentation.appearance == .playing)

        await finish(NotchPresentation.collapseDelay)
        await settle { presentation.appearance == .idle }
        #expect(presentation.appearance == .idle)
    }

    @Test func resumingBeforeCollapseCancelsItAndShowsTitle() async {
        presentation.update(trackID: "a", isPlaying: true)
        await finish(NotchPresentation.titleDuration)
        await settle { presentation.appearance == .playing }

        presentation.update(trackID: "a", isPlaying: false)
        await sleeper.waitUntilPending(NotchPresentation.collapseDelay)
        presentation.update(trackID: "a", isPlaying: true)
        #expect(presentation.appearance == .title)
        #expect(!presentation.isDimmed)

        await sleeper.finish(NotchPresentation.collapseDelay)
        await Task.yield()
        #expect(presentation.appearance == .title)
    }

    @Test func noSongReturnsToIdleImmediately() {
        presentation.update(trackID: "a", isPlaying: true)
        presentation.update(trackID: nil, isPlaying: false)
        #expect(presentation.appearance == .idle)
        #expect(!presentation.isDimmed)
    }

    @Test func hoverOpensInOneMoveAfterAShortWait() async {
        presentation.update(trackID: "a", isPlaying: true)
        presentation.pointerEntered()
        #expect(presentation.appearance == .title)

        await finish(NotchPresentation.openDelay)
        await settle { presentation.appearance == .open }
        #expect(presentation.appearance == .open)
    }

    @Test func leavingBeforeOpeningCancelsIt() async {
        presentation.update(trackID: "a", isPlaying: true)
        presentation.pointerEntered()
        await sleeper.waitUntilPending(NotchPresentation.openDelay)

        presentation.pointerExited()
        await sleeper.finish(NotchPresentation.openDelay)
        await Task.yield()
        #expect(presentation.appearance == .title)
    }

    @Test func hoverCanBeTurnedOff() {
        presentation.opensOnHover = false
        presentation.update(trackID: "a", isPlaying: true)
        #expect(!presentation.canOpen)
    }

    @Test func collapseOnPauseCanBeTurnedOff() async {
        presentation.collapsesOnPause = false
        presentation.update(trackID: "a", isPlaying: true)
        await finish(NotchPresentation.titleDuration)
        await settle { presentation.appearance == .playing }

        presentation.update(trackID: "a", isPlaying: false)
        await Task.yield()
        #expect(await sleeper.pending.isEmpty)
        #expect(presentation.isDimmed)
    }

    @Test func hoverWithNoSongDoesNothing() {
        presentation.pointerEntered()
        #expect(presentation.appearance == .idle)
    }

    @Test func openStaysOpenThroughTitleTimeout() async {
        presentation.update(trackID: "a", isPlaying: true)
        presentation.pointerEntered()
        await finish(NotchPresentation.openDelay)
        await settle { presentation.appearance == .open }

        await finish(NotchPresentation.titleDuration)
        await Task.yield()
        #expect(presentation.appearance == .open)

        presentation.pointerExited()
        await settle { presentation.appearance == .playing }
        #expect(presentation.appearance == .playing)
    }

    @Test func songEndingWhileOpenClosesIt() async {
        presentation.update(trackID: "a", isPlaying: true)
        presentation.pointerEntered()
        await finish(NotchPresentation.openDelay)
        await settle { presentation.appearance == .open }

        presentation.update(trackID: nil, isPlaying: false)
        #expect(presentation.appearance == .idle)
    }

    @Test func greetingHoldsTheSongUntilTheNotchHasRisen() async {
        presentation.greet()
        presentation.update(trackID: "a", isPlaying: true)
        #expect(presentation.appearance == .asleep)

        await finish(NotchPresentation.greetingDelay)
        await settle { presentation.appearance == .greeting }
        #expect(presentation.appearance == .greeting)
        presentation.pointerEntered()
        #expect(presentation.appearance == .greeting)

        await finish(GreetingTimeline.duration)
        await settle { presentation.appearance == .asleep }
        #expect(presentation.appearance == .asleep)

        await finish(NotchPresentation.greetingRise)
        await settle { presentation.appearance == .title }
        #expect(presentation.appearance == .title)
    }

    @Test func greetingWithNoSongEndsIdle() async {
        presentation.greet()
        await finish(NotchPresentation.greetingDelay)
        await finish(GreetingTimeline.duration)
        await finish(NotchPresentation.greetingRise)
        await settle { presentation.appearance == .idle }
        #expect(presentation.appearance == .idle)
    }

    @Test func changesAreReportedOnce() {
        var seen: [NotchAppearance] = []
        presentation.onChange = { seen.append($0) }
        presentation.update(trackID: "a", isPlaying: true)
        presentation.update(trackID: "a", isPlaying: true)
        presentation.pointerEntered()
        #expect(seen == [.title])
    }
}
