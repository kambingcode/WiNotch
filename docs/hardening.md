# Hardening

I went through every check below by hand on 2026-11-06, and they all passed. Still open: a full
day of use, and Apple Music, which I haven't tested yet.

## Fixes from code review

| Gap | What happened | Fix |
|---|---|---|
| Permission checked only when Spotify had just opened | The app stayed silent until relaunched | It asks again on the next player notification |
| Permission granted later in System Settings | The app needed a relaunch | It checks again when it reads the player |
| Spotify in the middle of quitting | A read could launch Spotify again | A process that is shutting down counts as closed |
| Spotify hanging | The app stuttered every second, because reads run on the main thread | A 1 s timeout, and after a slow read the next five reads are skipped |
| Ads without a title | Wasted searches on the lyrics services | No search for them |
| Display unplugged | The floating lyrics window stayed off screen | Its position is recalculated when the displays change |

## Test matrix

| Scenario | Status | Based on |
|---|---|---|
| Song change, seek, pause | Pass | Unit tests and manual testing |
| Two players active | Unit tests only | Fake players only, and Apple Music isn't tested yet |
| The player quits mid-song | Pass | Unit tests and manual testing |
| Network down | Pass | Unit tests and manual testing |
| Sleep and wake | Pass | Manual testing |
| External display plugged in and out | Unconfirmed | Optional, since it needs an external display |
| Full screen and switching Spaces | Pass | Manual testing |

## Resource use

| Metric | Result | Target |
|---|---|---|
| CPU with the player stopped | 0% | ≈ 0% |
| Memory with the player stopped | about 23 MB | < 150 MB |
| CPU while playing, plain window version | 0.7% in one reading | < 3% average |
| CPU while playing, line by line | 2.8% average over 50 s, down from 15% | < 3% average |
| CPU while playing, word by word | 4.8% average over 63 s, down from 5.2–5.5%, on a dense song | < 3% average. Not met, and I accepted it |
| Memory after 30 minutes | 42 MB, peak 107 MB | < 150 MB |
| Leaks after 30 minutes | 296 objects, 10.7 KB, up from 1.4 KB | – |

## Where the CPU went

The sound bars, animated in SwiftUI, used about 15% CPU because SwiftUI redrew them every frame.
Moving the animation to Core Animation brought it under the target by a thin margin. I only
measured that with the notch closed, not open.

Word highlighting adds load, since every word triggers a SwiftUI update and a text layout pass. I
replaced the hover area with a mouse monitor, and cut Spotify reads down to one position call per
second with a full read every 5 seconds. What's left grows with how dense the words are, so it
changes from song to song. I measured one song, which averages 8.5 words per line.

## Accepted risks

- A small leak grows with use, mostly `NSError` objects. I haven't found the source, because the
  `leaks` report is limited for this process. It grows by about 0.5 MB a day, far below the
  memory limit.
- Player reads run on the main thread. A normal read takes about 3 ms, but the position prototype
  logged an 87 ms peak, so an animation can stutter now and then.
- After the network drops, lyrics are fetched again on the next song change, not when the network
  comes back.
