import React from 'react';
import {AbsoluteFill, Audio, Sequence, interpolate, staticFile} from 'remotion';
import {
  Cue,
  FPS,
  MUSIC,
  SCENES,
  SOUNDS,
  TOTAL_FRAMES,
  beats,
  framesPerBeat,
  sceneStarts,
} from './timeline';
import {SCENE_COMPONENTS} from './scenes';

const curve = (points: [number, number][]) => (frame: number) =>
  interpolate(
    frame / framesPerBeat,
    points.map((p) => p[0]),
    points.map((p) => p[1]),
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );

const endFade = (frame: number) =>
  interpolate(frame, [TOTAL_FRAMES - beats(MUSIC.fadeOutBeats), TOTAL_FRAMES], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

const CueAudio: React.FC<{cue: Cue}> = ({cue}) => {
  const len = cue.lengthBeats ? beats(cue.lengthBeats) : undefined;
  const fin = cue.fadeInBeats ? beats(cue.fadeInBeats) : 0;
  const fout = cue.fadeOutBeats ? beats(cue.fadeOutBeats) : 0;
  const v = cue.volume ?? 1;
  return (
    <Sequence from={beats(cue.at)} durationInFrames={len} layout="none">
      <Audio
        src={staticFile(SOUNDS[cue.sound])}
        loop={cue.loop}
        volume={(f) => {
          let g = v;
          if (fin) g *= Math.min(1, f / fin);
          if (fout && len) g *= Math.min(1, Math.max(0, (len - f) / fout));
          return g;
        }}
      />
    </Sequence>
  );
};

/** Cues listed in timeline.ts plus the generated stone clicks. */
const cuesFor = (s: (typeof SCENES)[number]): Cue[] => {
  const cues: Cue[] = [...s.cues];
  if (s.id === 'ignition') {
    const step = s.stonesOverBeats / s.stones;
    for (let j = 0; j < s.stones; j++) {
      cues.push({sound: 'click', at: s.dropAt + j * step, volume: s.stoneClickVolume});
    }
  }
  return cues;
};

export const Film: React.FC = () => {
  const start = beats(MUSIC.dropAtBeat) - Math.round(MUSIC.dropInFileSeconds * FPS);
  const vol = curve(MUSIC.volumeCurve);
  return (
    <AbsoluteFill style={{background: '#000'}}>
      {sceneStarts.map(({id, from, duration}, i) => {
        const Scene = SCENE_COMPONENTS[id];
        return (
          <Sequence key={id} from={from} durationInFrames={duration} name={`${i + 1} · ${id}`}>
            <Scene />
            {cuesFor(SCENES[i]).map((c, k) => (
              <CueAudio key={k} cue={c} />
            ))}
          </Sequence>
        );
      })}
      {/* Music: delayed (or trimmed) so its drop lands on MUSIC.dropAtBeat */}
      <Sequence from={Math.max(0, start)} layout="none" name="Music">
        <Audio
          src={staticFile(MUSIC.file)}
          trimBefore={Math.max(0, -start)}
          volume={(f) => vol(f + Math.max(0, start)) * endFade(f + Math.max(0, start))}
        />
      </Sequence>
    </AbsoluteFill>
  );
};
