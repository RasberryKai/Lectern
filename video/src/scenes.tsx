import React from 'react';
import {AbsoluteFill, Easing, interpolate, useCurrentFrame} from 'remotion';
import {C, SCENES, beats, framesPerBeat} from './timeline';
import {Grid, Headline, Mark, Vignette, Void, fonts} from './ui';
import {Mountain, stonePositions, toScreen} from './Mountain';

const scene = <T extends (typeof SCENES)[number]['id']>(id: T) =>
  SCENES.find((s) => s.id === id) as Extract<(typeof SCENES)[number], {id: T}>;

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
const easeOut = Easing.bezier(0.16, 1, 0.3, 1);
const easeInOut = Easing.bezier(0.65, 0, 0.35, 1);

/** Slow camera push over the whole scene, around the frame centre. */
const Push: React.FC<{amount: number; from?: number; children: React.ReactNode}> = ({
  amount,
  from = 1,
  children,
}) => {
  const frame = useCurrentFrame();
  const dur = beats(8);
  const s = interpolate(frame, [0, dur], [from, from + amount], clamp);
  return <AbsoluteFill style={{transform: `scale(${s})`, transformOrigin: '50% 50%'}}>{children}</AbsoluteFill>;
};

// ── 1 · Countdown ───────────────────────────────────────────────────────────
export const Countdown: React.FC = () => {
  const s = scene('countdown');
  const beat = useCurrentFrame() / framesPerBeat;
  const shown = s.lineAt.filter((b) => beat >= b).length; // hard cuts, no fades
  const colorFor = (i: number) =>
    i === shown - 1 ? C.ink : i === shown - 2 ? C.dim2 : C.dim1;
  const filled = Math.min(s.squares, Math.floor(beat) + 1);

  return (
    <Void>
      <Grid />
      <Push amount={s.pushIn}>
        <div
          style={{
            position: 'absolute',
            left: 104,
            top: 172,
            fontFamily: fonts.display,
            fontWeight: 800,
            fontSize: 184,
            lineHeight: 0.98,
            letterSpacing: '-0.055em',
          }}
        >
          {s.copy.lines.map((l, i) => (
            <div key={l} style={{color: colorFor(i), visibility: i < shown ? 'visible' : 'hidden'}}>
              {l}
            </div>
          ))}
        </div>
        <div style={{position: 'absolute', left: 1280, top: 452, display: 'flex', gap: 20}}>
          {Array.from({length: s.squares}, (_, i) => (
            <i
              key={i}
              style={{
                display: 'block',
                width: 20,
                height: 20,
                borderRadius: 4,
                background: i < filled ? C.ink : C.dim1,
              }}
            />
          ))}
        </div>
      </Push>
      <Vignette />
    </Void>
  );
};

// ── 2 · Fog ─────────────────────────────────────────────────────────────────
export const Fog: React.FC = () => {
  const s = scene('fog');
  const frame = useCurrentFrame();
  const beat = frame / framesPerBeat;
  const routes = s.copy.routes.map((label, i) => {
    const t0 = s.routeDrawBeats[i];
    const progress = interpolate(beat, [t0, t0 + s.routeDrawLength], [0, 1], {
      ...clamp,
      easing: easeOut,
    });
    return {
      label,
      progress,
      labelOpacity: interpolate(progress, [0.35, 0.6], [0, 1], clamp),
    };
  });
  return (
    <Void>
      <Push amount={s.pushIn}>
        <Mountain
          routes={routes}
          fogOpacity={interpolate(beat, [0, 3], [0.6, 1], clamp)}
          fogDrift={beat / 8}
          chip={s.copy.examChip}
        />
      </Push>
      <Headline lines={s.copy.headline} />
      <Vignette />
    </Void>
  );
};

// ── 3 · Ignition ────────────────────────────────────────────────────────────
export const Ignition: React.FC = () => {
  const s = scene('ignition');
  const frame = useCurrentFrame();
  const beat = frame / framesPerBeat;

  const trail = interpolate(beat, s.trailDraw, [0, 1], {...clamp, easing: Easing.in(Easing.cubic)});
  const step = s.stonesOverBeats / s.stones;
  const stones = Array.from({length: s.stones}, (_, j) => {
    const t0 = s.dropAt + j * step;
    const k = interpolate(beat, [t0, t0 + 0.25], [0, 1], clamp);
    return {opacity: k > 0 ? 1 : 0, scale: interpolate(k, [0, 1], [1.9, 1], {easing: easeOut})};
  });

  // Camera: continues the fog push, then dives into the third stone.
  const base = interpolate(beat, [0, 8], [1.03, 1.07], clamp);
  const diveT = interpolate(beat, [s.diveAt, 8], [0, 1], clamp);
  const dive = easeInOut(diveT); // stone travels to the centre
  const zoomK = Easing.in(Easing.cubic)(diveT); // and the camera falls into it
  const zoom = Math.exp(interpolate(zoomK, [0, 1], [0, Math.log(90)]));
  const p = stonePositions(s.stones)[s.diveStone];
  const sp = toScreen(p.x, p.y);
  const stoneFill = interpolate(zoomK, [0.15, 0.55], [0, 1], clamp);

  const lockupIn = beat >= s.dropAt; // hard cut on the drop
  const lockupOut = interpolate(beat, [s.diveAt, s.diveAt + 1], [1, 0], clamp);

  return (
    <Void>
      <AbsoluteFill style={{transform: `scale(${base})`, transformOrigin: '50% 50%'}}>
        <AbsoluteFill
          style={{
            transformOrigin: `${sp.x}px ${sp.y}px`,
            transform: `translate(${(960 - sp.x) * dive}px, ${(540 - sp.y) * dive}px) scale(${zoom})`,
          }}
        >
          <Mountain
            fogOpacity={interpolate(beat, [0, 3], [1, 0], clamp)}
            fogDrift={1 + beat / 8}
            trail={trail}
            stones={stones}
            highlightStone={s.diveStone}
            stoneFill={mix(C.ink, C.bg, stoneFill)}
            chip={s.copy.examChip}
          />
        </AbsoluteFill>
      </AbsoluteFill>
      {lockupIn && (
        <div style={{opacity: lockupOut}}>
          <div style={{position: 'absolute', left: 104, top: 96, display: 'flex', alignItems: 'center', gap: 22}}>
            <Mark size={92} glow />
            <span style={{fontFamily: fonts.logo, fontWeight: 600, fontSize: 86, letterSpacing: '-0.01em'}}>
              {s.copy.wordmark}
            </span>
          </div>
          <div
            style={{
              position: 'absolute',
              left: 104,
              top: 232,
              maxWidth: 560,
              fontFamily: fonts.display,
              fontWeight: 700,
              fontSize: 44,
              lineHeight: 1.2,
              letterSpacing: '-0.03em',
              color: C.quiet,
            }}
          >
            {s.copy.tagline.map((l) => (
              <div key={l}>{l}</div>
            ))}
          </div>
        </div>
      )}
      <Vignette />
    </Void>
  );
};

/** Blend two #rrggbb colours. */
function mix(a: string, b: string, t: number) {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  return `rgb(${pa.map((v, i) => Math.round(v + (pb[i] - v) * t)).join(',')})`;
}

export const SCENE_COMPONENTS: Record<string, React.FC> = {
  countdown: Countdown,
  fog: Fog,
  ignition: Ignition,
};
