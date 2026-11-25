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
  riser: 'audio/sfx-riser.mp3', // "Tense filtered synth riser, 2.4 seconds, ending abruptly"
  click: 'audio/sfx-click.mp3', // "Small stone placed on stone, dry and close"
  whoosh: 'audio/sfx-whoosh.mp3', // "Short airy whoosh of a card sliding past, very subtle"
  type: 'audio/sfx-type.mp3', // "Fast quiet typing on a mechanical keyboard, close mic, 3 seconds"
  tick: 'audio/sfx-tick.mp3', // "Glassy soft UI confirmation tick, very short, high"
  thread: 'audio/sfx-thread.mp3', // "Thin rising string-like shimmer, 0.5 seconds"
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
// ElevenLabs music v2.5, take 2 (30 s), time-stretched from 99.4 to exactly
// 100 BPM. Its own drop sits 9.49 s into the file; the track is placed so that
// drop lands on the storyboard's drop (film beat 20 = 0:12.0). That makes the
// music enter at about 0:02.5, under the countdown.
export const MUSIC = {
  file: 'audio/music-s1-6.mp3',
  dropInFileSeconds: 9.49,
  dropAtBeat: 20, // film beat where the drop must land
  // Volume over the film: [film beat, volume] points.
  volumeCurve: [
    [0, 0.85],
    [20, 1],
  ] as [number, number][],
  fadeOutBeats: 1, // fade at the very end of this cut
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
      { sound: 'hit', at: 0, volume: 0.55 },
      { sound: 'hit', at: 2, volume: 0.55 },
      { sound: 'hit', at: 4, volume: 0.65 },
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
    cues: [
      // Night wind was cut (Kai: "meh").
    ] as Cue[],
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
  {
    id: 'slides',
    bars: 2,
    copy: {
      headline: ['You read.', 'You decide what matters.'], // second line is dimmed
      noteLabel: 'Note on slide 12',
      note: 'Exam asks this as a booking entry',
    },
    slides: 7,
    agendaSlides: 2, // the first N slides drop out of line
    activeSlide: 3, // glowing slide (slide 12)
    raceIn: [0, 1], // beats: strip races in from the right
    dropAt: 1, // beat the agenda slides drop out
    focusAt: [2, 2.5], // beats: rack focus from the strip to the note
    typeFrom: [2.5, 6.5], // beats: the note types itself
    cues: [
      { sound: 'whoosh', at: 0, volume: 0.7 },
      { sound: 'whoosh', at: 1, volume: 0.5 },
      { sound: 'type', at: 2.5, volume: 0.6, lengthBeats: 4, fadeOutBeats: 0.5 },
    ] as Cue[],
  },
  {
    id: 'ask',
    bars: 2,
    copy: {
      headline: ['Answers that show', 'what they read.'],
      receipt: 'Read slides 12–14',
      answer:
        "The cash left when the machine was bought. Depreciation spreads that cost over the years it's used",
    },
    markDraw: [0, 1.25], // beats: the Lectern mark draws itself
    receiptAt: 1.5, // beat the receipt ticks in
    streamFrom: [2, 7], // beats: the answer streams in
    cues: [
      { sound: 'tick', at: 1.5, volume: 0.8 },
      { sound: 'type', at: 2, volume: 0.45, lengthBeats: 5, fadeOutBeats: 0.5 },
    ] as Cue[],
  },
  {
    id: 'generate',
    bars: 2,
    copy: {
      headline: ['Flashcards from every slide.', "Some you don't flip. You solve."],
      slides: [11, 12, 14, 13],
      emptySlide: 14, // outlined red: no cards yet
      emptyLabel: 'No cards yet',
      cards: [
        ['FLIP', 'What depreciation spreads'],
        ['FLIP', 'Straight-line formula'],
        ['SOLVE', 'Book a year of depreciation'],
        ['FLIP', "Why it isn't a cash outflow"],
        ['SOLVE', 'Book value after n years'],
        ['SOLVE', 'Partial-year depreciation'],
      ],
      aside: 'One Generate. Both kinds, from the same slides.',
    },
    // [slide index, card index]; threads from one slide shoot together
    links: [[0, 0], [1, 1], [1, 4], [3, 2], [3, 3], [3, 5]],
    slideAt: [0.5, 1.5, -1, 2.5], // beat each slide's threads shoot (-1: never)
    threadBeats: 0.5, // how long a thread takes to reach its card
    emptyAt: 3.5, // beat slide 14 turns red
    cues: [
      { sound: 'thread', at: 0.5, volume: 0.6 },
      { sound: 'thread', at: 1.5, volume: 0.6 },
      { sound: 'thread', at: 2.5, volume: 0.6 },
      { sound: 'tick', at: 3, volume: 0.7 },
    ] as Cue[],
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
