import CoreGraphics
import Testing
@testable import NotchUI

private typealias Pixel = (red: CGFloat, green: CGFloat, blue: CGFloat)

private let red: Pixel = (0.9, 0.1, 0.1)
private let blue: Pixel = (0.1, 0.2, 0.9)
private let green: Pixel = (0.1, 0.8, 0.2)
private let black: Pixel = (0, 0, 0)
private let gray: Pixel = (0.5, 0.5, 0.5)
private let skin: Pixel = (0.8, 0.6, 0.48)

private func cover(_ parts: (Pixel, Int)...) -> [Pixel] {
    parts.flatMap { Array(repeating: $0.0, count: $0.1) }
}

@Suite struct ArtworkPaletteTests {
    @Test func solidCoverGivesItsColour() throws {
        let colors = ArtworkPalette.colors(fromPixels: cover((red, 100)))
        let first = try #require(colors.first)
        #expect(colors.count == 1)
        #expect(first.red > 0.7)
        #expect(first.green < 0.5)
        #expect(first.blue < 0.5)
    }

    @Test func blackAndWhiteCoverGlowsWhite() {
        #expect(ArtworkPalette.colors(fromPixels: cover((black, 50), (gray, 50))) == [.white])
    }

    @Test func aFewColouredPixelsDoNotCount() {
        #expect(ArtworkPalette.colors(fromPixels: cover((black, 95), (red, 5))) == [.white])
    }

    @Test func emptyCoverDoesNotCrash() {
        #expect(ArtworkPalette.colors(fromPixels: []) == [.white])
    }

    @Test func differentHuesAreKeptStrongestFirst() throws {
        let colors = ArtworkPalette.colors(fromPixels: cover((blue, 50), (red, 30), (green, 25)))
        #expect(colors.count == 3)
        let first = try #require(colors.first)
        #expect(first.blue > first.red)
    }

    @Test func smallAccentsAreLeftOutSoTheGlowStaysClean() {
        #expect(ArtworkPalette.colors(fromPixels: cover((blue, 80), (red, 20))).count == 1)
    }

    @Test func aSingleColourGainsNeighboursToMakeAGradient() throws {
        let base = ArtworkPalette.Color(red: 0.1, green: 0.2, blue: 0.9)
        let glow = ArtworkPalette.glowColors(from: [base])
        #expect(glow.count == 3)
        #expect(glow[0] == base)
        #expect(glow[1] != base)
        #expect(glow[2] != base)
        #expect(glow[1] != glow[2])
        for color in glow {
            #expect(color.blue > color.red || color.blue > color.green)
        }
    }

    @Test func redNeighboursWrapAroundTheColourWheel() {
        let glow = ArtworkPalette.glowColors(from: [ArtworkPalette.Color(red: 0.9, green: 0.1, blue: 0.12)])
        #expect(glow.count == 3)
        #expect(glow.allSatisfy { $0.red > 0.5 })
    }

    @Test func whiteStaysWhite() {
        #expect(ArtworkPalette.glowColors(from: [.white]) == [.white])
    }

    @Test func severalColoursAreLeftAlone() {
        let colors = [ArtworkPalette.Color(red: 1, green: 0, blue: 0), ArtworkPalette.Color(red: 0, green: 0, blue: 1)]
        #expect(ArtworkPalette.glowColors(from: colors) == colors)
    }

    @Test func neverMoreThanThreeColours() {
        let yellow: Pixel = (0.9, 0.85, 0.1)
        let colors = ArtworkPalette.colors(fromPixels: cover((blue, 30), (red, 30), (green, 30), (yellow, 30)))
        #expect(colors.count == 3)
    }

    @Test func nearlyIdenticalHuesCountOnce() {
        let nearlyRed: Pixel = (0.9, 0.12, 0.1)
        #expect(ArtworkPalette.colors(fromPixels: cover((red, 50), (nearlyRed, 50))).count == 1)
    }

    @Test func livelyColourBeatsSkinEvenWhenSmaller() throws {
        let colors = ArtworkPalette.colors(fromPixels: cover((skin, 70), (blue, 30)))
        let first = try #require(colors.first)
        #expect(first.blue > first.red)
    }

    @Test func dullCoverWithoutALivelyColourGlowsWhite() {
        let dull: Pixel = (0.5, 0.42, 0.37)
        #expect(ArtworkPalette.colors(fromPixels: cover((dull, 100))) == [.white])
    }

    @Test func darkColoursAreBrightenedSoTheyGlow() throws {
        let darkBlue: Pixel = (0.05, 0.08, 0.3)
        let first = try #require(ArtworkPalette.colors(fromPixels: cover((darkBlue, 100))).first)
        #expect(max(first.red, first.green, first.blue) >= 0.75)
    }

    @Test func readsARealImage() throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())

        let first = try #require(ArtworkPalette.colors(from: image).first)
        #expect(first.blue > first.red)
    }
}
