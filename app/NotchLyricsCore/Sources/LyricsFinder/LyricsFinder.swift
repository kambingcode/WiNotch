import Foundation
import LyricsKit
import os

private let log = Logger(subsystem: "local.notchlyrics.app", category: "lyrics")

/// A lyric service with the name shown as the lyric's source.
public struct LyricsSource: Sendable {
    public let name: String
    public let provider: LyricsProvider

    public init(name: String, provider: LyricsProvider) {
        self.name = name
        self.provider = provider
    }
}

public struct FoundLyrics: @unchecked Sendable {
    public let lyrics: Lyrics
    public let source: String
    public let fromCache: Bool
    /// The user's timing offset for this song, in seconds.
    public let offset: TimeInterval

    public var hasWordTiming: Bool { WordTimingCheck.hasWordTiming(lyrics) }

    public init(lyrics: Lyrics, source: String, fromCache: Bool, offset: TimeInterval) {
        self.lyrics = lyrics
        self.source = source
        self.fromCache = fromCache
        self.offset = offset
    }
}

/// One result of a manual search.
public struct LyricsCandidate: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let lyrics: Lyrics
    public let source: String
    public let title: String
    public let artist: String
    public let length: TimeInterval?
    public let lineCount: Int
    /// Nil when the automatic search would have rejected it.
    let score: Double?

    public var isLikelyMatch: Bool { score != nil }

    init(
        lyrics: Lyrics, source: String, title: String, artist: String,
        length: TimeInterval?, lineCount: Int, score: Double?
    ) {
        self.lyrics = lyrics
        self.source = source
        self.title = title
        self.artist = artist
        self.length = length
        self.lineCount = lineCount
        self.score = score
    }
}

public enum LookupResult: @unchecked Sendable {
    case found(FoundLyrics)
    /// Every service answered and none had this song.
    case notFound
    /// At least one service could not answer, so trying later may help.
    case unavailable
}

/// Finds lyrics for a song: cache first, then each tier of services in turn.
///
/// Services in one tier run together and the first acceptable answer wins. A
/// later tier only runs when the one before it found nothing, so unofficial
/// services are called as rarely as possible. Cancelling the calling task,
/// as a song change does, stops the search without caching anything.
public actor LyricsFinder {
    /// The order chosen in docs/lyrics-sources.md.
    public static let defaultTiers: [[LyricsSource]] = [
        [LyricsSource(name: "LRCLIB", provider: LRCLIBClient())],
        [
            LyricsSource(name: "NetEase", provider: LyricsProviders.Service.netease.create(httpClient: SecureHTTPClient())),
            LyricsSource(name: "QQMusic", provider: LyricsProviders.Service.qq.create(httpClient: SecureHTTPClient())),
        ],
    ]

    /// Each covers songs the others miss. See docs/lyrics-sources.md.
    public static let defaultWordSources = [
        LyricsSource(name: "QQMusic", provider: LyricsProviders.Service.qq.create(httpClient: SecureHTTPClient())),
        LyricsSource(name: "Kugou", provider: LyricsProviders.Service.kugou.create(httpClient: SecureHTTPClient())),
        LyricsSource(name: "NetEase", provider: LyricsProviders.Service.netease.create(httpClient: SecureHTTPClient())),
    ]

    private struct Health {
        var failures = 0
        var pausedUntil: Date?
    }

    private enum Outcome {
        case answered
        case failed
        case cancelled
    }

    private struct SearchResult: @unchecked Sendable {
        let source: String
        let best: Lyrics?
        let outcome: Outcome
    }

    private let tiers: [[LyricsSource]]
    private let wordSources: [LyricsSource]
    private let wordTimeout: TimeInterval
    private let cache: LyricsDiskCache
    private let timeout: TimeInterval
    private let failureLimit: Int
    private let pause: TimeInterval
    private let now: @Sendable () -> Date
    private var health: [String: Health] = [:]

    public init(
        tiers: [[LyricsSource]] = LyricsFinder.defaultTiers,
        wordSources: [LyricsSource] = LyricsFinder.defaultWordSources,
        cache: LyricsDiskCache,
        timeout: TimeInterval = 6,
        wordTimeout: TimeInterval = 10,
        failureLimit: Int = 3,
        pause: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tiers = tiers
        self.wordSources = wordSources
        self.wordTimeout = wordTimeout
        self.cache = cache
        self.timeout = timeout
        self.failureLimit = failureLimit
        self.pause = pause
        self.now = now
    }

    public func find(_ query: TrackQuery) async throws -> LookupResult {
        if let entry = await cache.entry(for: query), let lyrics = Lyrics(entry.lyrics) {
            return .found(FoundLyrics(lyrics: lyrics, source: entry.source, fromCache: true, offset: entry.offset))
        }

        let request = LyricsSearchRequest(
            searchTerm: .info(title: query.searchTitle, artist: query.searchArtist),
            duration: query.duration,
            limit: 5
        )
        var someoneFailed = false

        for tier in tiers {
            let sources = tier.filter(isAvailable)
            someoneFailed = someoneFailed || sources.count < tier.count
            let results = await search(sources, request: request, query: query, timeout: timeout) { _ in true }
            try Task.checkCancellation()

            for result in results { record(result) }
            someoneFailed = someoneFailed || results.contains { $0.outcome == .failed }

            if let winner = results.first(where: { $0.best != nil }), let lyrics = winner.best {
                let entry = LyricsDiskCache.Entry(lyrics: lyrics.description, source: winner.source, offset: 0)
                try? await cache.store(entry, for: query)
                return .found(FoundLyrics(lyrics: lyrics, source: winner.source, fromCache: false, offset: 0))
            }
        }
        return someoneFailed ? .unavailable : .notFound
    }

    /// Looks for word-timed lyrics that can replace what is already showing.
    ///
    /// Runs after the lyrics appear, so slower services cost no waiting. Each
    /// song is searched once: the answer is remembered, unless a service
    /// could not reply.
    public func findWordTimed(_ query: TrackQuery, base: FoundLyrics) async throws -> FoundLyrics? {
        guard !base.hasWordTiming,
              let entry = await cache.entry(for: query),
              entry.wordChecked != true,
              entry.isManual != true else { return nil }

        let request = LyricsSearchRequest(
            searchTerm: .info(title: query.searchTitle, artist: query.searchArtist),
            duration: query.duration,
            limit: 5
        )
        let sources = wordSources.filter(isAvailable)
        let baseLyrics = base.lyrics
        let results = await search(sources, request: request, query: query, timeout: wordTimeout) { candidate in
            WordTimingCheck.hasWordTiming(candidate) && WordTimingCheck.fits(candidate, base: baseLyrics)
        }
        log.notice("Word results for \(query.title, privacy: .public): \(results.map { "\($0.source)=\($0.outcome),\($0.best != nil)" }.joined(separator: " "), privacy: .public), cancelled \(Task.isCancelled)")
        try Task.checkCancellation()
        for result in results { record(result) }

        // The offset may have changed while searching.
        guard var latest = await cache.entry(for: query), latest.isManual != true else { return nil }
        if let winner = results.first(where: { $0.best != nil }), let lyrics = winner.best {
            latest.lyrics = lyrics.description
            latest.source = winner.source
            latest.wordChecked = true
            try? await cache.store(latest, for: query)
            return FoundLyrics(lyrics: lyrics, source: winner.source, fromCache: false, offset: latest.offset)
        }
        let everyoneAnswered = sources.count == wordSources.count && !results.contains { $0.outcome == .failed }
        if everyoneAnswered {
            latest.wordChecked = true
            try? await cache.store(latest, for: query)
        }
        return nil
    }

    private func isAvailable(_ source: LyricsSource) -> Bool {
        guard let until = health[source.name]?.pausedUntil else { return true }
        return now() >= until
    }

    private func record(_ result: SearchResult) {
        var state = health[result.source] ?? Health()
        switch result.outcome {
        case .answered:
            state = Health()
        case .failed:
            state.failures += 1
            if state.failures >= failureLimit {
                state.failures = 0
                state.pausedUntil = now().addingTimeInterval(pause)
            }
        case .cancelled:
            break
        }
        health[result.source] = state
    }

    /// Runs a tier, stopping the other services once one has an acceptable answer.
    private func search(
        _ sources: [LyricsSource],
        request: LyricsSearchRequest,
        query: TrackQuery,
        timeout: TimeInterval,
        accepts: @escaping @Sendable (Lyrics) -> Bool
    ) async -> [SearchResult] {
        await withTaskGroup(of: SearchResult.self) { group in
            for source in sources {
                group.addTask {
                    await Self.ask(source, request: request, query: query, timeout: timeout, accepts: accepts)
                }
            }
            var results: [SearchResult] = []
            for await result in group {
                results.append(result)
                if result.best != nil { group.cancelAll() }
            }
            return results
        }
    }

    /// Written only by the task reading the service, and read after it ends.
    private final class Collected: @unchecked Sendable {
        var best: Lyrics?
        var bestScore = -Double.infinity
    }

    private static func ask(
        _ source: LyricsSource,
        request: LyricsSearchRequest,
        query: TrackQuery,
        timeout: TimeInterval,
        accepts: @escaping @Sendable (Lyrics) -> Bool
    ) async -> SearchResult {
        let collected = Collected()
        let outcome = await read(source, request: request, timeout: timeout) { lyrics in
            if CreditFilter.announcesVariant(lyrics, for: query) { return }
            CreditFilter.clean(lyrics, for: query)
            guard let score = CandidateRanking.score(CandidateFacts(lyrics), for: query),
                  score > collected.bestScore,
                  accepts(lyrics) else { return }
            collected.best = lyrics
            collected.bestScore = score
        }
        return SearchResult(source: source.name, best: collected.best, outcome: outcome)
    }

    /// Reads a service until it finishes or runs out of time.
    private static func read(
        _ source: LyricsSource,
        request: LyricsSearchRequest,
        timeout: TimeInterval,
        each: @escaping @Sendable (Lyrics) -> Void
    ) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group -> Outcome in
            group.addTask {
                do {
                    for try await lyrics in source.provider.lyrics(for: request) {
                        each(lyrics)
                    }
                    return Task.isCancelled ? .cancelled : .answered
                } catch is CancellationError {
                    return .cancelled
                } catch LyricsProviderError.processingFailed {
                    // QQMusic reports an empty result this way; the service is healthy.
                    return .answered
                } catch {
                    return Task.isCancelled ? .cancelled : .failed
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return Task.isCancelled ? .cancelled : .failed
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }

    // MARK: Manual search

    private final class Gathered: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LyricsCandidate] = []

        func add(_ item: LyricsCandidate) {
            lock.withLock { items.append(item) }
        }

        var all: [LyricsCandidate] { lock.withLock { items } }
    }

    /// Asks every service at once and returns all results, likeliest first, so
    /// the user can pick one the automatic search rejected.
    public func candidates(title: String, artist: String, duration: TimeInterval) async -> [LyricsCandidate] {
        let query = TrackQuery(title: title, artist: artist, duration: duration)
        let term: LyricsSearchRequest.SearchTerm = artist.isEmpty
            ? .keyword(title)
            : .info(title: query.searchTitle, artist: query.searchArtist)
        let request = LyricsSearchRequest(searchTerm: term, duration: duration, limit: 5)
        let timeout = self.timeout
        let gathered = Gathered()

        await withTaskGroup(of: Void.self) { group in
            for source in tiers.joined() {
                group.addTask {
                    _ = await Self.read(source, request: request, timeout: timeout) { lyrics in
                        CreditFilter.clean(lyrics, for: query)
                        let facts = CandidateFacts(lyrics)
                        guard facts.lineCount > 0 else { return }
                        gathered.add(LyricsCandidate(
                            lyrics: lyrics,
                            source: source.name,
                            title: facts.title,
                            artist: facts.artist,
                            length: facts.length,
                            lineCount: facts.lineCount,
                            score: CandidateRanking.score(facts, for: query)
                        ))
                    }
                }
            }
        }
        return gathered.all.sorted { ($0.score ?? -1) > ($1.score ?? -1) }
    }

    /// Makes a chosen result the lyrics for this song from now on.
    public func use(_ candidate: LyricsCandidate, for query: TrackQuery) async -> FoundLyrics {
        let entry = LyricsDiskCache.Entry(
            lyrics: candidate.lyrics.description,
            source: candidate.source,
            offset: 0,
            isManual: true
        )
        try? await cache.store(entry, for: query)
        return FoundLyrics(lyrics: candidate.lyrics, source: candidate.source, fromCache: false, offset: 0)
    }

    public func setOffset(_ offset: TimeInterval, for query: TrackQuery) async {
        try? await cache.setOffset(offset, for: query)
    }

    public func clearCache() async {
        try? await cache.removeAll()
    }
}
