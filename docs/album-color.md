# Album cover glow

When the notch opens, a soft gradient made from the cover's colors drifts behind the album art,
so every song gets a look of its own. The text, the sound bars and the progress line stay white.

It shipped on 2026-11-06. The first idea was to color the text, and it turned into a glow behind
the cover after the tests below.

## The color test

I tried a color picker on 11 real covers, drawn on black. The "Blinding Lights" cover failed to
download. The script was a one-off and isn't in the repo.

The method:

1. Shrink the cover to 32×32.
2. Skip gray or dark pixels (saturation under 0.25, brightness under 0.2).
3. Sort the rest into 24 hue buckets, weighted by saturation × brightness.
4. Take the heaviest bucket. If fewer than 8% of the pixels have color, use white.
5. Lighten it until its contrast against black reaches 4.5:1.

| Result | Examples |
|---|---|
| Accurate and distinctive | Hati-Hati di Jalan (blue), Shape of You (light blue), Yellow (golden yellow), Sial (purple) |
| Fell back to white, correctly | bad guy (black and white) |
| Right but dull | Novacane, Love Galore, Young Wild & Free: skin in the photo turns into a salmon brown |
| Off | Bound 2: red, though the cover is mostly white and pink |

Two findings changed the design:

- **Dim colored text is hard to read.** Dark colors at 40% almost vanish on black, red and blue
  most of all. Words that haven't been sung yet should stay a dim white.
- **Photos with a lot of skin give dull colors.** That needs an extra rule, such as giving less
  weight to low-saturation orange hues.

## How it works

| Part | Behavior |
|---|---|
| Color picker | `ArtworkPalette` in `NotchUI`, up to 3 colors, pure and testable |
| When it runs | Once per song, off the main thread, after `ArtworkStore` loads the cover |
| The glow | Three irregular blobs in `ArtworkGlow`. Their cores hide behind the cover, so only tongues of color show. Each blob orbits (17, 23, 29 s), spins (41, 53, 47 s) and changes shape (13, 19, 11 s), and none of them ever stops |
| CPU cost | The blobs are `shadowPath`s, so Core Animation handles the blur and the morphing outside the app. They only exist while the notch is open |
| Song change | The color fades to the new one in 0.3 s, and stays white until the cover loads |
| Covers with no lively color | A soft white glow at strength 0.11 |
| Small clashing colors | Dropped when their weight is under 40% of the strongest color, because they muddy the glow |
| Single-color covers | Two neighboring hues join in, so it's still a gradient |
| Reduce motion | When it's on in macOS, the glow holds still |
| Setting | "Cahaya dari sampul album" (Album cover glow) in the Notch tab, on by default |
| Floating lyrics | Unchanged |

## Risks

| Risk | Mitigation |
|---|---|
| The color feels wrong on some covers | White as a fallback, and a switch to turn the glow off |
| Apple Music gives no cover URL | White for now. Apple Music isn't tested yet |

## Decisions

1. A gradient glow around the cover, only while the notch is open.
2. The text, sound bars and progress line stay white.
3. The motion is very slow and keeps looping.
4. A dull cover uses a livelier color from the same cover, or white if it has none.
5. The floating lyrics window doesn't change.
6. My first glow was a circle. It was too big and too literal, so I switched to smaller irregular
   blobs.
7. I made the glow thinner and softer so it reads as ambient light: strength 0.32, blur 28.
