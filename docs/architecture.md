# Architecture

Everything except the app shell lives in the Swift package `app/NotchLyricsCore`, so it can be
tested without UI. `app/build-app.sh` builds, bundles and signs the app. `NotchLyrics` is the
working name in code.

## Modules

| Module | Job | Depends on |
|---|---|---|
| `LXMusicPlayer` | MPL-2.0 copy that talks to the players | ScriptingBridge |
| `PlaybackCore` | Player state, the start-time model, Automation permission | `LXMusicPlayer` |
| `LyricsFinder` | Search, ranking, credit filter, cache, offsets | `LyricsKit` |
| `SyncEngine` | Picks the active line and schedules the next one | `PlaybackCore`, `LyricsFinder` |
| `AppState` | `@Observable` app state and settings | The three above |
| `NotchUI` | `NotchPanel`, the notch shape, four sizes, hover | `AppState` |
| `FloatingUI` | The floating lyrics window | `AppState` |
| App | Status item, settings, lifecycle | All of them |

The lyrics module is called `LyricsFinder` so it doesn't clash with the `LyricsCore` target
inside LyricsKit.

## Data flow

1. A player notification or the 1.0 s refresh reaches `PlaybackCore`.
2. `PlaybackCore` updates the song and its start time. It accepts a new position only when it
   moves more than 0.1 s, so the clock doesn't jitter.
3. A new song cancels the previous search and starts `LyricsFinder`: cache first, then the
   network.
4. `SyncEngine` works out the active line and schedules one wait until the next line.
5. `AppState` publishes the change, and `NotchUI` and `FloatingUI` draw it.

When no song is playing, no timer runs.

## Early prototypes

Before writing the app I tried the three riskiest pieces on their own. All three passed.

### Building against LyricsKit

| Attempt | Result |
|---|---|
| `LyricsKit` plus the full `MusicPlayer` package | Failed while resolving dependencies: `mediaremote-adapter` pulls in `OpenSoftLinking` 0.1.0, which needs tools 6.3, and the local Swift was 6.2 |
| `LyricsKit`, with `LXMusicPlayer` as a local target | Passed: a 60 s build that links and runs |

So `Sources/LXMusicPlayer` from the MxIris fork lives in the repo as a local target, with its
MPL-2.0 license and file headers kept, and Xcode didn't need an update.

### The notch panel

Tested on the built-in display:

| Check | Result |
|---|---|
| Position | `y + height` = 1169, flush with the top edge, and the system doesn't move it |
| Width | 291.5, rounded to 292 pt |
| Window level | 27 |
| Focus | The panel never became the key window. The front app stayed the same in a 20 s run. In a 60 s run it changed from Code to Safari, most likely because I switched apps myself |
| Look | Sits centered in the notch |
| Over full-screen apps | Not part of this prototype. It passed later, see [hardening.md](hardening.md) |

### Reading the playback position

60 samples, one every 0.25 s through ScriptingBridge, with a song playing:

| Metric | Spotify | Target |
|---|---|---|
| Read cost, median | 3.2 ms | – |
| Read cost, p95 | 5.0 ms | – |
| Read cost, max | 87 ms | – |
| Position drift against the clock | −2.2 to +0.4 ms | ≤ 150 ms |

For comparison, `osascript` takes about 150 ms per call, so WiNotch doesn't use it.

- This compares the position with the system clock, not with the sound coming out of the
  speakers. Audio latency, from Bluetooth for example, isn't included.
- Apple Music wasn't measured because it wasn't running.
- **Without Automation permission, the position reads 0.0 with no error.** The very first
  measurement came back like that. A 0 can't count as a real position, so the app checks the
  permission explicitly with `AEDeterminePermissionToAutomateTarget`.

## First working version

I tested a plain window with "Ghost Town" on Spotify, and the lyrics kept time with the song.

| Metric | Result | Target |
|---|---|---|
| Line change vs player position, p50 | 20 ms | ≤ 150 ms |
| Line change vs player position, max | 58 ms | ≤ 150 ms |
| Sample | 19 lines, one song, including a resume from pause | – |
| App CPU | 0.7% in one reading | < 3% average |
| App memory | 93 MB | < 150 MB |

The gap is measured against the position the player reports, not against the sound. CPU here is
a single reading. [hardening.md](hardening.md) has the full profile. Apple Music wasn't tested.

## Where WiNotch differs from the open-source player code

- **Spotify reports duration in milliseconds.** `Spotify.h` says seconds, but the real value is
  milliseconds, and `PlayerKind` converts it. Tests with a fake player missed this. A real song
  caught it.
- **The position tolerance is 0.1 s, not 1.5 s.** `LXMusicPlayer` lets the position drift up to
  1.5 s, far above the 150 ms target. `PlaybackCore` reads `playerPosition` directly every second
  while a song plays.
- **The Apple Music notification.** The open-source code listens for
  `com.apple.iTunes.playerInfo`, while the Music app posts `com.apple.Music.playerInfo`.
  `PlaybackMonitor` listens for the second one itself, so the `LXMusicPlayer` copy stays
  unchanged.
- **A 1 s player timeout.** The ScriptingBridge default of 2 minutes can freeze the app when a
  player hangs.

## Errors the app handles

| Situation | Behavior |
|---|---|
| Automation permission missing or denied | Show a guide, and never use a position of 0 |
| The player quits | Back to idle |
| No lyrics found | The text line shows the title, and manual search is available |
| The network is down | The cache still works, and the app retries on the next song change |
| The displays change | Recalculate the panel's size and position |
