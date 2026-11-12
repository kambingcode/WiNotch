# Lyrics sources

WiNotch targets English and Indonesian songs. I tested four providers on 30 songs to choose the
search order, and that order is what `app/NotchLyricsCore` uses today.

## How I tested

- 30 songs: 15 Indonesian, 15 English. One search per song per provider, up to 5 candidates, 1 s
  between requests, all from one Mac.
- Reference duration: the iTunes catalog, exact title matches only, taking the most common value.
  I set "Uptown Funk" to 270 s by hand, because its most common value came from another version.
  In the app, the duration comes from the player.
- A result counts as found when the title matches, it isn't another version, it has at least 5
  lines, and the duration is within 5 s. When a provider gives no duration, the lines must span
  60–100% of the song.
- I compared the lyrics text across providers. Every chosen result matched at least one other
  provider.

Thirty popular songs is a small sample. It's enough to pick an order, but it says little about
songs people rarely play.

## Results per provider

Measured with LyricsKit's built-in clients, before the LRCLIB fix (finding 2 below).

| Provider | Found (of 30) | Indonesian | English | First result p50 | First result p90 | Slowest | Word timing |
|---|---|---|---|---|---|---|---|
| LRCLIB | 29 | 14 | 15 | 0.5 s | 1.0 s | 1.3 s | 0 |
| NetEase | 28 | 13 | 15 | 1.2 s | 1.3 s | 6.3 s | 10 |
| QQMusic | 26 | 12 | 14 | 1.2 s | 2.0 s | 4.9 s | 26 |
| Kugou | 28 | 13 | 15 | 2.1 s | 4.8 s | 14.2 s | 28 |

"Slowest" is the total search time. Combined:

| Combination | Found |
|---|---|
| LRCLIB alone | 29 |
| LRCLIB + NetEase | 30 |
| LRCLIB + QQMusic | 30 |
| LRCLIB + Kugou | 30 |
| LRCLIB + NetEase + QQMusic | 30 |

## Results from the module

I ran `LyricsFinder` against the real services on the same 30 songs, then ran it again:

| Metric | Result | Target |
|---|---|---|
| Found | 30 of 30, all from LRCLIB | – |
| From the network | p50 0.32 s, p90 0.44 s, max 0.55 s | ≤ 2 s (p90) |
| Second run | 30 of 30 from the cache, no network | – |
| From the cache | p50 0.6 ms, max 1.9 ms | ≤ 200 ms |

LRCLIB answered every song, so the fallback tier never ran in this final round. Unit tests cover
how it behaves.

## Provider order

| Tier | Provider | Why |
|---|---|---|
| Primary | LRCLIB | Open public API, the fastest, the best coverage |
| Fallback | NetEase and QQMusic, in parallel | For songs LRCLIB doesn't have. They only run when LRCLIB fails, so the unofficial APIs see little traffic |
| Word timing only | Kugou | Too slow for the main lyrics, but its word timing covers songs QQMusic misses |
| Not used | Musixmatch | Needs a user token, which I don't have. Not tested |

## Word-by-word lyrics

LRCLIB lyrics show first. In the background, WiNotch searches QQMusic, Kugou and NetEase at the
same time, and a result that passes the checks replaces the lyrics on screen. Each of these
unofficial APIs gets one call per new song, and the app caches the result.

| Source | Passed (of 30) | Notes |
|---|---|---|
| QQMusic | 24 | Every line has word timing |
| Kugou | 22 | Every line has word timing |
| QQMusic + Kugou | 26 (13 Indonesian, 13 English) | On the 30 test songs |
| NetEase | 5, English only | Adds nothing on the test songs, but covers hip-hop I listen to, like Ghost Town and White, which failed on the other two |

The test songs are all popular pop, so 26 of 30 won't hold for every taste. On five songs from my
own listening, QQMusic had no passing result and Kugou had two.

The checks: at least 80% of lines have word timing, at least 5 lines match the lyrics on screen,
the median shift is at most 0.75 s, and the spread is at most 0.35 s. Lines from these sources
usually start 0.23 s after LRCLIB's. Rejected results include Anti-Hero (shifted 50 s),
Tak Segampang Itu (24 s) and Tak Ingin Usai (3 s), which probably come from other recordings.
Rolling in the Deep failed on spread too, likely because of its repeated chorus, so it stays line
by line.

A full run against the real services moved 26 of 30 songs to word timing, at p50 0.68 s and max
2.1 s after the lyrics appeared, and all 26 came from the cache on the second run. The other four
stay line by line.

The services tag the end of each word, so a word lights up from the end of the one before it. The
highlight jumps from word to word instead of flowing, because per-frame animation turned out to
be expensive.

## Findings that shaped the code

1. **NetEase and Kugou get called over `http`.** macOS blocks that in a bundled app (error -1022)
   but not in a command line tool. My provider test ran as a command line tool, so the failure
   only showed up in the app. `SecureHTTPClient` sends every request over `https`, which keeps
   the app's security rules strict. `mobilecdn.kugou.com` became `mobileservice.kugou.com`,
   because the first one's certificate doesn't match.
2. **A LyricsKit bug with LRCLIB.** One entry with a null `duration` made the whole search fail.
   "Monokrom" failed because of it, even though LRCLIB had 20 results. The module has its own
   LRCLIB client that skips broken entries, and with it "Monokrom" turns up.
3. **The first result is often wrong.** LRCLIB's first candidate was right for only 23 songs.
   Candidates need scoring, not just ordering.
4. **`Lyrics.quality` isn't enough.** Plenty of wrong candidates still score high: at a 0.8
   threshold, 91 candidates that broke the rules got through. The module scores candidates with
   the rules above.
5. **The title has to match.** Artist and duration alone return other songs, like "Hong Kong"
   for "Blinding Lights".
6. **Other versions have to go.** Live versions, remixes and covers often share the title. One
   Kugou result labeled as a version of "Laskar Pelangi" held the lyrics of a different song.
   QQMusic and Kugou sometimes keep a plain title in the metadata and name the version only in the
   first lyric line, so the first lines get checked as well.
7. **NetEase, QQMusic and Kugou often leave the duration out.** The check uses the line span
   instead.
8. **Title and credit lines are common in QQMusic and Kugou.** The first line was `Title - Artist`
   or a credit in 26 of 26 QQMusic results and 27 of 28 Kugou results, so the filter has to deal
   with them.
9. **QQMusic throws an error when it finds nothing.** "no candidates" means not found, not a
   broken provider, so it doesn't count as a failure.

## An earlier five-language test

Before I narrowed the focus, I tested 30 mixed songs. The providers together still covered
Mandarin, Japanese and Korean songs, but LRCLIB was weaker there. Mandarin lyrics can use
different scripts on different providers, so comparisons need to normalize the script first. I
didn't use this data to set the order.
