import Foundation
import LyricsKit
import Testing
@testable import LyricsFinder

private let query = TrackQuery(title: "Blinding Lights", artist: "The Weeknd", duration: 200)

private func facts(
    title: String = "Blinding Lights",
    artist: String = "The Weeknd",
    length: TimeInterval? = 200,
    lines: Int = 40,
    span: TimeInterval = 180
) -> CandidateFacts {
    CandidateFacts(title: title, artist: artist, length: length, lineCount: lines, span: span)
}

@Suite struct TitleTests {
    @Test func searchTitleDropsReleaseSuffixes() {
        #expect(TrackQuery(title: "Bohemian Rhapsody - Remastered 2011", artist: "Queen", duration: 355).searchTitle == "Bohemian Rhapsody")
        #expect(TrackQuery(title: "Stay (feat. Justin Bieber)", artist: "X", duration: 1).searchTitle == "Stay")
    }

    @Test func hyphenInsideTitleIsKept() {
        #expect(TextMatch.coreTitle("Hati-Hati di Jalan") == "Hati-Hati di Jalan")
        #expect(TextMatch.sameTitle("Anti-Hero", "Anti Hero"))
    }

    @Test func searchArtistUsesFirstListedArtist() {
        #expect(TrackQuery(title: "x", artist: "Mark Ronson, Bruno Mars", duration: 1).searchArtist == "Mark Ronson")
    }

    @Test func artistMatchesAnyListedArtist() {
        #expect(TextMatch.sameArtist("Bruno Mars", "Mark Ronson, Bruno Mars"))
        #expect(!TextMatch.sameArtist("Adele", "Mark Ronson, Bruno Mars"))
        #expect(!TextMatch.sameArtist("", "Adele"))
    }

    @Test(arguments: ["Yellow (Live)", "Yellow - Live in Buenos Aires", "Yellow (Acoustic Version)", "Yellow (Remix)"])
    func variantsAreRecognised(title: String) {
        #expect(TextMatch.isVariant(title))
    }

    @Test(arguments: ["Yellow", "Yellow - Remastered 2011", "Yellow (Album Version)", "Oliver"])
    func plainReleasesAreNotVariants(title: String) {
        #expect(!TextMatch.isVariant(title))
    }
}

@Suite struct RankingTests {
    @Test func acceptsMatchingSong() {
        #expect(CandidateRanking.score(facts(), for: query) != nil)
    }

    @Test func rejectsDifferentTitleEvenWithSameArtistAndLength() {
        #expect(CandidateRanking.score(facts(title: "Hong Kong"), for: query) == nil)
    }

    @Test func rejectsVariantUnlessRequested() {
        #expect(CandidateRanking.score(facts(title: "Blinding Lights (Live)"), for: query) == nil)
        let live = TrackQuery(title: "Blinding Lights (Live)", artist: "The Weeknd", duration: 200)
        #expect(CandidateRanking.score(facts(title: "Blinding Lights (Live)"), for: live) != nil)
    }

    @Test func rejectsLengthOutsideTolerance() {
        #expect(CandidateRanking.score(facts(length: 206), for: query) == nil)
        #expect(CandidateRanking.score(facts(length: 205), for: query) != nil)
    }

    @Test func rejectsTooFewLines() {
        #expect(CandidateRanking.score(facts(lines: 4), for: query) == nil)
    }

    @Test func withoutLengthUsesSpanAndRequiresArtist() {
        #expect(CandidateRanking.score(facts(length: nil, span: 180), for: query) != nil)
        #expect(CandidateRanking.score(facts(length: nil, span: 90), for: query) == nil)
        #expect(CandidateRanking.score(facts(artist: "One Direction", length: nil), for: query) == nil)
    }

    @Test func unknownDurationRequiresArtist() {
        let unknown = TrackQuery(title: "Blinding Lights", artist: "The Weeknd", duration: 0)
        #expect(CandidateRanking.score(facts(), for: unknown) != nil)
        #expect(CandidateRanking.score(facts(artist: "Someone"), for: unknown) == nil)
    }

    @Test func prefersMatchingArtistThenCloserLength() throws {
        let exact = try #require(CandidateRanking.score(facts(length: 200), for: query))
        let close = try #require(CandidateRanking.score(facts(length: 203), for: query))
        let otherArtist = try #require(CandidateRanking.score(facts(artist: "Cover Band", length: 200), for: query))
        #expect(exact > close)
        #expect(close > otherArtist)
    }
}

@Suite struct CreditFilterTests {
    @Test(arguments: ["Written by：Giring", "Recorded by: Someone at Studio", "作词 : A", "词：A", "Background Vocals by：B", "Lirik: A"])
    func creditsAreRemoved(line: String) {
        #expect(CreditFilter.isCredit(line))
    }

    @Test(arguments: ["Hati-hati di jalan", "I said, ooh, I'm blinded by the lights", "Baby: come home", "Music is my life"])
    func sungLinesStay(line: String) {
        #expect(!CreditFilter.isCredit(line))
    }

    @Test func headingIsRecognisedInEitherOrder() {
        #expect(CreditFilter.isHeading("Blinding Lights - The Weeknd", for: query))
        #expect(CreditFilter.isHeading("The Weeknd - Blinding Lights", for: query))
        #expect(!CreditFilter.isHeading("Blinding lights - all night long", for: query))
    }

    @Test func variantNamedOnlyInTheFirstLinesIsDetected() {
        func lyrics(_ first: String) -> Lyrics {
            Lyrics(lines: [LyricsLine(content: first, position: 0), LyricsLine(content: "Isi", position: 5)], idTags: [:])
        }
        #expect(CreditFilter.announcesVariant(lyrics("Blinding Lights (Live) - The Weeknd"), for: query))
        #expect(CreditFilter.announcesVariant(lyrics("Blinding Lights (Chromatics Remix) - The Weeknd"), for: query))
        #expect(!CreditFilter.announcesVariant(lyrics("Blinding Lights (Explicit) - The Weeknd"), for: query))
        #expect(!CreditFilter.announcesVariant(lyrics("Live my life tonight"), for: query))

        let live = TrackQuery(title: "Blinding Lights (Live)", artist: "The Weeknd", duration: 200)
        #expect(!CreditFilter.announcesVariant(lyrics("Blinding Lights (Live) - The Weeknd"), for: live))
    }

    @Test func cleanRemovesHeadingOnlyNearTheStart() {
        let heading = "Blinding Lights - The Weeknd"
        let lyrics = Lyrics(lines: [
            LyricsLine(content: heading, position: 0),
            LyricsLine(content: "Written by：A", position: 1),
            LyricsLine(content: "First line", position: 10),
            LyricsLine(content: "Second line", position: 20),
            LyricsLine(content: heading, position: 30),
        ], idTags: [:])
        CreditFilter.clean(lyrics, for: query)
        #expect(lyrics.lines.map(\.content) == ["First line", "Second line", heading])
    }
}

@Suite struct SecureHTTPClientTests {
    private func secured(_ address: String) -> String? {
        SecureHTTPClient.secured(URLRequest(url: URL(string: address)!)).url?.absoluteString
    }

    @Test func plainRequestsBecomeSecure() {
        #expect(secured("http://music.163.com/api/search/pc?s=a") == "https://music.163.com/api/search/pc?s=a")
    }

    @Test func secureRequestsStayTheSame() {
        #expect(secured("https://lrclib.net/api/search?q=a") == "https://lrclib.net/api/search?q=a")
    }

    @Test func hostWithABadCertificateIsReplaced() {
        #expect(secured("http://mobilecdn.kugou.com/api/v3/search/song") == "https://mobileservice.kugou.com/api/v3/search/song")
    }

    @Test func methodHeadersAndBodySurvive() {
        var request = URLRequest(url: URL(string: "http://music.163.com/api")!)
        request.httpMethod = "POST"
        request.httpBody = Data("a=1".utf8)
        request.setValue("x", forHTTPHeaderField: "Referer")

        let result = SecureHTTPClient.secured(request)
        #expect(result.httpMethod == "POST")
        #expect(result.httpBody == Data("a=1".utf8))
        #expect(result.value(forHTTPHeaderField: "Referer") == "x")
    }
}

@Suite struct WordTimingCheckTests {
    private func lines(shift: Double, count: Int = 10, drift: Double = 0) -> Lyrics {
        Lyrics(lines: (0..<count).map {
            LyricsLine(content: "Baris \($0)", position: Double($0) * 10 + shift + Double($0) * drift)
        }, idTags: [:])
    }

    @Test func smallShiftFits() {
        #expect(WordTimingCheck.fits(lines(shift: 0.2), base: lines(shift: 0)))
    }

    @Test func differentRecordingDoesNotFit() {
        #expect(!WordTimingCheck.fits(lines(shift: 24), base: lines(shift: 0)))
    }

    @Test func driftingRecordingDoesNotFit() {
        #expect(!WordTimingCheck.fits(lines(shift: 0, drift: 0.3), base: lines(shift: 0)))
    }

    @Test func tooFewSharedLinesDoesNotFit() {
        #expect(!WordTimingCheck.fits(lines(shift: 0, count: 4), base: lines(shift: 0, count: 4)))
    }

    @Test func repeatedChorusMatchesTheNearestOccurrence() {
        let base = Lyrics(lines: (0..<8).map { LyricsLine(content: "Reff", position: Double($0) * 30) }, idTags: [:])
        let candidate = Lyrics(lines: (0..<8).map { LyricsLine(content: "Reff", position: Double($0) * 30 + 0.2) }, idTags: [:])
        #expect(WordTimingCheck.fits(candidate, base: base))
    }
}

@Suite struct LRCLIBParsingTests {
    @Test func skipsMalformedEntriesAndKeepsTheRest() throws {
        let json = """
        [
          {"trackName": "Monokrom", "artistName": "Tulus", "albumName": "A", "duration": 214.0,
           "syncedLyrics": "[00:10.00]Satu\\n[00:20.00]Dua"},
          {"trackName": "Monokrom", "artistName": "Tulus", "albumName": null, "duration": null,
           "syncedLyrics": "[00:10.00]Tiga"},
          {"trackName": 5, "duration": "broken", "syncedLyrics": "[00:10.00]Empat"},
          {"trackName": "Monokrom", "artistName": "Tulus", "duration": 214.0, "syncedLyrics": null}
        ]
        """
        let parsed = try LRCLIBClient.parse(Data(json.utf8))
        #expect(parsed.count == 2)
        #expect(parsed[0].idTags[.title] == "Monokrom")
        #expect(parsed[0].length == 214)
        #expect(parsed[0].lines.map(\.content) == ["Satu", "Dua"])
        #expect(parsed[1].length == nil)
    }
}
