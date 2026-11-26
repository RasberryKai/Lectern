import React from 'react';
import {AbsoluteFill, Audio, Easing, Sequence, interpolate, staticFile, useCurrentFrame} from 'remotion';
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
  TRANSITION,
  Enter,
} from './timeline';
import {SCENE_COMPONENTS} from './scenes';

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
const exits = (i: number) => SCENES[i + 1]?.enter === 'zoom';

const cuesFor = (s: (typeof SCENES)[number]): Cue[] => {
  const cues: Cue[] = [...s.cues];
  if (s.enter === 'zoom' && TRANSITION.whooshVolume > 0) {
    cues.push({sound: 'whoosh', at: 0, volume: TRANSITION.whooshVolume});
  }
  if (s.id === 'ignition') {
    const step = s.stonesOverBeats / s.stones;
    for (let j = 0; j < s.stones; j++) {
      cues.push({sound: 'click', at: s.dropAt + j * step, volume: s.stoneClickVolume});
    }
  }
  return cues;
};

const ease = Easing.bezier(0.65, 0, 0.35, 1);
const T = () => beats(TRANSITION.beats);

/** Applies a scene's way in, and its way out when the next scene zooms in. */
const Shell: React.FC<{enter: Enter; exits: boolean; duration: number; children: React.ReactNode}> = ({
  enter,
  exits,
  duration,
  children,
}) => {
  const f = useCurrentFrame();
  const t = T();
  const inK = enter === 'cut' ? 1 : ease(Math.min(1, f / t));
  const outK = exits ? ease(Math.max(0, Math.min(1, (f - duration) / t))) : 0;
  const scaleIn = enter === 'emerge' ? 1.12 : TRANSITION.scaleIn;
  const scale = (scaleIn + (1 - scaleIn) * inK) * (1 + (TRANSITION.scaleOut - 1) * outK);
  const blur = (1 - inK) * TRANSITION.blur + outK * TRANSITION.blur;
  const opacity = inK * (1 - outK);
  return (
    <AbsoluteFill
      style={{
        transform: `scale(${scale})`,
        filter: blur > 0.05 ? `blur(${blur}px)` : undefined,
        opacity,
      }}
    >
      {children}
    </AbsoluteFill>
  );
};

export const Film: React.FC = () => {
  const drop = beats(MUSIC.dropAtBeat);
  const introStart = drop - Math.round(MUSIC.intro.dropInFileSeconds * FPS);
  const mainTrim = Math.round(MUSIC.main.firstBeatInFileSeconds * FPS);
  return (
    <AbsoluteFill style={{background: '#000'}}>
      {sceneStarts.map(({id, from, duration}, i) => {
        const Scene = SCENE_COMPONENTS[id];
        return (
          <Sequence
            key={id}
            from={from}
            durationInFrames={duration + (exits(i) ? T() : 0)}
            name={`${i + 1} · ${id}`}
          >
            <Shell enter={SCENES[i].enter} exits={exits(i)} duration={duration}>
              <Scene />
            </Shell>
            {cuesFor(SCENES[i]).map((c, k) => (
              <CueAudio key={k} cue={c} />
            ))}
          </Sequence>
        );
      })}
      {/* Music 1: piano intro, placed so its own drop would land on the film's drop, cut there */}
      <Sequence from={Math.max(0, introStart)} durationInFrames={drop - Math.max(0, introStart)} layout="none" name="Music · intro">
        <Audio
          src={staticFile(MUSIC.intro.file)}
          trimBefore={Math.max(0, -introStart)}
          volume={(f) => {
            const left = drop - Math.max(0, introStart) - f;
            return MUSIC.intro.volume * Math.min(1, left / MUSIC.intro.outFrames);
          }}
        />
      </Sequence>
      {/* Music 2: the energy, from the drop on */}
      <Sequence from={drop} layout="none" name="Music · main">
        <Audio
          src={staticFile(MUSIC.main.file)}
          trimBefore={mainTrim}
          volume={(f) => MUSIC.main.volume * endFade(f + drop)}
        />
      </Sequence>
    </AbsoluteFill>
  );
};
