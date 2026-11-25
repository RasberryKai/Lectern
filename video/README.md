# Lectern launch film

Remotion project for the beta launch film (storyboard draft 3). It currently
holds scenes 1 to 3 (Countdown, Fog, Ignition): 14.4 s, 1920×1080, 30 fps.

## Run it

```sh
cd video
npm install
npm run studio    # live preview with a scrubber, hot-reloads on save
npm run render    # writes out/lectern-launch-s1-3.mp4 (audio normalised to -14 LUFS)
```

## Tweak it

Everything you'd want to change is in **`src/timeline.ts`**, in musical time
(100 BPM, 1 bar = 4 beats = 2.4 s):

| To change | Edit |
| --- | --- |
| Scene length | `SCENES[].bars` |
| On-screen text | `SCENES[].copy` |
| When a countdown line lands | `countdown.lineAt` (beats) |
| When the routes crawl up | `fog.routeDrawBeats`, `fog.routeDrawLength` |
| Trail, drop, stones, dive | `ignition.trailDraw`, `dropAt`, `stonesOverBeats`, `diveAt`, `diveStone` |
| Camera push | `pushIn` per scene |
| A sound effect | `cues`: `{sound, at (beats), volume, lengthBeats, fadeInBeats, fadeOutBeats}` |
| Music build and drop | `MUSIC.filteredCurve` and `MUSIC.fullCurve` (`[beat, volume]` points) |
| Music beat alignment | `MUSIC.offsetSeconds` |
| Colours | `C` |

Shapes and motion live in `src/scenes.tsx` (one component per scene) and
`src/Mountain.tsx` (the mountain from the storyboard).

## Audio

All audio is made with ElevenLabs (music v2.5, sound effects v3), one take each:

- `music-s1-3.mp3`: 15 s. The take came back at one flat energy level with no
  build or drop, so the build is faked in the mix: `music-s1-3-filtered.mp3`
  (same track, low-passed at 320 Hz) plays first and hands over to the full
  track on the drop at 0:12.0.
- `sfx-hit`, `sfx-wind` (boosted +18 dB, the take was very quiet),
  `sfx-riser`, `sfx-click`.

Fonts (Inter, Inter Tight, Newsreader) are bundled in `public/fonts` so renders
never need the network.
