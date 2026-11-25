# Lectern launch film

Remotion project for the beta launch film (storyboard draft 3). It currently
holds scenes 1 to 6 (Countdown, Fog, Ignition, Slides, Ask, Generate):
28.8 s, 1920×1080, 30 fps.

## Run it

```sh
cd video
npm install
npm run studio    # live preview with a scrubber, hot-reloads on save
npm run render    # writes out/lectern-launch-s1-6.mp4 (audio normalised to -14 LUFS)
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
| Music volume | `MUSIC.volumeCurve` (`[beat, volume]` points) |
| Where the music sits | `MUSIC.dropInFileSeconds` + `MUSIC.dropAtBeat` (the track is shifted so its drop lands on that beat) |
| Colours | `C` |

Shapes and motion live in `src/scenes.tsx` (one component per scene) and
`src/Mountain.tsx` (the mountain from the storyboard).

## Audio

All audio is made with ElevenLabs (music v2.5, sound effects v3), one take each:

- `music-s1-6.mp3`: take 2, 30 s, time-stretched from 99.4 to 100 BPM. Its own
  drop is 9.49 s in, so the track starts at about 0:02.5 and the drop lands on
  0:12.0 as in the storyboard. (Take 1 was a 65 Hz drone with nothing audible
  on laptop speakers and was discarded.)
- SFX: `hit`, `riser`, `click`, `whoosh`, `type`, `tick`, `thread` (the last two
  boosted, the takes were quiet). Night wind was cut.

Fonts (Inter, Inter Tight, Newsreader) are bundled in `public/fonts` so renders
never need the network.
