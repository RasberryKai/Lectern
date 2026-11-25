// ─────────────────────────────────────────────────────────────────────────────
// Lectern launch film: the ONE file to tweak.
//
// Everything is in musical time: 100 BPM, 4 beats per bar, 1 bar = 2.4 s.
// Scene lengths are in bars, cue times are in beats from the start of their
// scene (0 = the scene's first frame, 4 = its second bar, 0.5 = an eighth).
// Change a number, save, and Remotion Studio updates live.
// ─────────────────────────────────────────────────────────────────────────────

export const FPS = 30;
export const BPM = 100;
export const BEATS_PER_BAR = 4;
export const WIDTH = 1920;
export const HEIGHT = 1080;

export const framesPerBeat = (FPS * 60) / BPM; // 18 at 30 fps
export const beats = (b: number) => Math.round(b * framesPerBeat);
export const bars = (b: number) => beats(b * BEATS_PER_BAR);

// ── Colors (Lectern v3, dark) ───────────────────────────────────────────────
export const C = {
  bg: '#0A0B0A',
  grid: '#151614',
  ink: '#ECECE8',
  quiet: '#A3A39C',
  faint: '#7C7C75',
  dim1: '#2E2F2C', // oldest line in the countdown
  dim2: '#4A4B46', // previous line in the countdown
  line: '#41423E',
  green: '#8DB591', // the only light
  greenBright: '#A9CFAC',
  greenDeep: '#4F7553',
};

// ── Sounds (files live in public/audio, all made with ElevenLabs) ───────────
export const SOUNDS = {
  hit: 'audio/sfx-hit.mp3', // "Deep cinematic sub-bass impact, short, tight, no reverb"
  wind: 'audio/sfx-wind.mp3', // "Soft high-altitude wind at night, distant, airy, seamless loop"
  riser: 'audio/sfx-riser.mp3', // "Tense filtered synth riser, 2.4 seconds, ending abruptly"
  click: 'audio/sfx-click.mp3', // "Small stone placed on stone, dry and close"
} as const;
export type SoundName = keyof typeof SOUNDS;

export type Cue = {
  sound: SoundName;
  at: number; // beats from scene start
  volume?: number; // 0..1, default 1
  lengthBeats?: number; // cut the sound after this many beats (default: play it out)
  loop?: boolean;
  fadeInBeats?: number;
  fadeOutBeats?: number;
};

// ── Music ───────────────────────────────────────────────────────────────────
// The ElevenLabs take came back at one flat energy level (no build, no drop),
// so the build is made in the mix: a low-passed copy of the same track plays
// first and crossfades into the full track on the drop.
export const MUSIC = {
  full: 'audio/music-s1-3.mp3',
  filtered: 'audio/music-s1-3-filtered.mp3', // same track, low-pass 320 Hz
  // Seconds trimmed off the start of the file so its beat lands on our grid.
  offsetSeconds: 0.07,
  // Volume of the filtered copy: [beat from film start, volume] points.
  filteredCurve: [
    [0, 0.22],
    [8, 0.3], // fog: the build starts (0:04.8)
    [16, 0.32],
    [19.9, 0.5], // riser bar
    [20, 0], // the drop (0:12.0): gone
  ] as [number, number][],
  // Volume of the full track.
  fullCurve: [
    [0, 0],
    [19.9, 0],
    [20, 1], // the drop (0:12.0)
    [24, 1],
  ] as [number, number][],
  fadeOutBeats: 2, // fade at the very end of this test cut
};

// ── Scenes ──────────────────────────────────────────────────────────────────
export const SCENES = [
  {
    id: 'countdown',
    bars: 2,
    copy: {
      lines: ['12 lectures.', 'One exam.', '23 days.'],
    },
    lineAt: [0, 2, 4], // beat each line hard-cuts in
    squares: 8, // days ticking away, one per beat
    pushIn: 0.04, // slow camera push over the scene (0.04 = 4 %)
    cues: [
      { sound: 'hit', at: 0, volume: 0.9 },
      { sound: 'hit', at: 2, volume: 0.9 },
      { sound: 'hit', at: 4, volume: 1 },
    ] as Cue[],
  },
  {
    id: 'fog',
    bars: 2,
    copy: {
      headline: ["More material", "isn't a route."],
      routes: ['Summaries', 'Mind maps', '600 generated cards'],
      examChip: '16 Dec',
    },
    routeDrawBeats: [0.5, 1.5, 2.5], // beat each dashed route starts crawling up
    routeDrawLength: 3, // beats a route takes to reach the fog
    pushIn: 0.03,
    cues: [{ sound: 'wind', at: 0, volume: 0.55, fadeInBeats: 1, fadeOutBeats: 1.5, lengthBeats: 8 }] as Cue[],
  },
  {
    id: 'ignition',
    bars: 2,
    copy: {
      wordmark: 'Lectern',
      tagline: ['Your lectures,', 'turned into one route.'],
      examChip: '16 Dec',
    },
    trailDraw: [1, 3.85], // beats: green line shoots from the base to the summit
    dropAt: 4, // beat of the drop (0:12.0): stones + lockup
    stonesOverBeats: 2, // twelve stones slam on over two beats
    stones: 12,
    diveAt: 6, // beat the camera starts flying up the trail into stone 3
    diveStone: 2, // 0-based: the third stone
    cues: [
      { sound: 'riser', at: 0, volume: 0.7 },
      { sound: 'hit', at: 4, volume: 1 },
      // stone clicks: one every sixth of a beat, generated below
    ] as Cue[],
    stoneClickVolume: 0.35,
  },
] as const;

export type SceneId = (typeof SCENES)[number]['id'];

export const sceneStarts = (() => {
  let t = 0;
  return SCENES.map((s) => {
    const start = t;
    t += bars(s.bars);
    return { id: s.id, from: start, duration: bars(s.bars) };
  });
})();

export const TOTAL_FRAMES = sceneStarts.reduce((a, s) => a + s.duration, 0);
