import CoreGraphics
import Testing
@testable import FloatingUI

@Suite struct FloatingLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1131)
    private let size = CGSize(width: 640, height: 80)

    @Test func hiddenUnlessEnabled() {
        #expect(!FloatingLayout.isVisible(enabled: false, hasLyrics: true, isPlaying: true, hidesOnPause: false))
    }

    @Test func hiddenWithoutLyrics() {
        #expect(!FloatingLayout.isVisible(enabled: true, hasLyrics: false, isPlaying: true, hidesOnPause: false))
    }

    @Test func pauseHidesOnlyWhenAsked() {
        #expect(!FloatingLayout.isVisible(enabled: true, hasLyrics: true, isPlaying: false, hidesOnPause: true))
        #expect(FloatingLayout.isVisible(enabled: true, hasLyrics: true, isPlaying: false, hidesOnPause: false))
    }

    @Test func nextLineMakesItTaller() {
        #expect(FloatingLayout.height(fontSize: 26, showsNextLine: true) > FloatingLayout.height(fontSize: 26, showsNextLine: false))
    }

    @Test func savedPositionOnScreenIsKept() {
        let saved = CGPoint(x: 100, y: 200)
        #expect(FloatingLayout.origin(saved: saved, size: size, screens: [screen]) == saved)
    }

    @Test func positionOnAnUnpluggedScreenFallsBack() {
        let origin = FloatingLayout.origin(saved: CGPoint(x: 4000, y: 200), size: size, screens: [screen])
        #expect(origin == CGPoint(x: 580, y: 80))
    }

    @Test func noSavedPositionSitsLowAndCentred() {
        #expect(FloatingLayout.origin(saved: nil, size: size, screens: [screen]) == CGPoint(x: 580, y: 80))
    }

    @Test func noScreensDoesNotCrash() {
        #expect(FloatingLayout.origin(saved: nil, size: size, screens: []) == .zero)
    }
}
