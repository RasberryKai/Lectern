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

const Caret: React.FC<{size: number}> = ({size}) => (
  <span
    style={{
      display: 'inline-block',
      width: Math.max(3, size * 0.07),
      height: '0.95em',
      background: C.green,
      verticalAlign: '-0.12em',
      marginLeft: 4,
      boxShadow: `0 0 16px ${C.green}`,
    }}
  />
);

/** Text that types in between two beats, character by character. */
const typed = (text: string, beat: number, [a, b]: readonly number[]) =>
  text.slice(0, Math.round(interpolate(beat, [a, b], [0, text.length], clamp)));

// ── 4 · Slides ──────────────────────────────────────────────────────────────
export const Slides: React.FC = () => {
  const s = scene('slides');
  const beat = useCurrentFrame() / framesPerBeat;
  const race = interpolate(beat, s.raceIn, [1, 0], {...clamp, easing: easeOut});
  const drift = interpolate(beat, [s.raceIn[1], 8], [0, -60], clamp);
  const drop = interpolate(beat, [s.dropAt, s.dropAt + 0.5], [0, 1], {...clamp, easing: easeOut});
  const focus = interpolate(beat, s.focusAt, [0, 1], {...clamp, easing: easeInOut});
  const text = typed(s.copy.note, beat, s.typeFrom);

  return (
    <Void>
      <Grid />
      <Headline
        lines={[s.copy.headline[0]]}
        style={{fontSize: 72}}
      />
      <div style={{position: 'absolute', left: 104, top: 160, fontFamily: fonts.display, fontWeight: 800, fontSize: 72, lineHeight: 1, letterSpacing: '-0.05em', color: '#5C5D58'}}>
        {s.copy.headline[1]}
      </div>
      <div
        style={{
          position: 'absolute',
          left: 560,
          top: 270,
          transformOrigin: '0 50%',
          transform: `perspective(2200px) rotateY(30deg) rotateX(4deg) translateX(${race * 1800 + drift}px)`,
          filter: `blur(${focus * 6}px)`,
          opacity: 1 - focus * 0.35,
        }}
      >
        <div style={{display: 'flex', gap: 36}}>
          {Array.from({length: s.slides}, (_, i) => {
            const agenda = i < s.agendaSlides;
            const active = i === s.activeSlide;
            return (
              <div
                key={i}
                style={{
                  flex: 'none',
                  width: 420,
                  height: 262,
                  borderRadius: 16,
                  background: active ? '#232421' : '#1A1B19',
                  border: active ? `4px solid ${C.green}` : '2px solid #34352F',
                  padding: 28,
                  opacity: agenda ? 1 - drop * 0.82 : 1,
                  transform: `translateY(${agenda ? drop * 120 : 0}px)`,
                  boxShadow: active ? '0 0 80px rgba(141,181,145,.35)' : undefined,
                }}
              >
                <div style={{height: 12, width: '70%', background: '#4A4B46', borderRadius: 6}} />
                <div style={{height: 8, width: '90%', background: '#34352F', borderRadius: 4, marginTop: 24}} />
                <div style={{height: 8, width: '60%', background: '#34352F', borderRadius: 4, marginTop: 14}} />
              </div>
            );
          })}
        </div>
      </div>
      <div
        style={{
          position: 'absolute',
          left: 104,
          top: 720,
          width: 1040,
          padding: '32px 40px',
          background: '#1E1F1D',
          border: '2px solid #41423E',
          borderRadius: 24,
          boxShadow: '0 60px 160px rgba(0,0,0,.6)',
          filter: `blur(${(1 - focus) * 4}px)`,
          opacity: 0.45 + focus * 0.55,
          transform: `scale(${0.97 + focus * 0.03})`,
          transformOrigin: '0 0',
        }}
      >
        <div style={{fontSize: 22, color: C.faint, fontWeight: 600, marginBottom: 12}}>{s.copy.noteLabel}</div>
        <div style={{fontFamily: fonts.display, fontWeight: 600, fontSize: 48, lineHeight: 1.25, letterSpacing: '-0.02em', minHeight: 60}}>
          {text}
          {beat >= s.focusAt[0] && <Caret size={48} />}
        </div>
      </div>
      <Vignette />
    </Void>
  );
};

// ── 5 · Ask ─────────────────────────────────────────────────────────────────
export const Ask: React.FC = () => {
  const s = scene('ask');
  const beat = useCurrentFrame() / framesPerBeat;
  const draw = interpolate(beat, s.markDraw, [0, 1], {...clamp, easing: easeInOut});
  const receipt = beat >= s.receiptAt;
  const receiptK = interpolate(beat, [s.receiptAt, s.receiptAt + 0.25], [0, 1], {...clamp, easing: easeOut});
  const text = typed(s.copy.answer, beat, s.streamFrom);
  const push = interpolate(beat, [0, 8], [1, 1.03], clamp);

  return (
    <Void>
      <Grid />
      <AbsoluteFill style={{transform: `scale(${push})`, transformOrigin: '30% 60%'}}>
        <div
          style={{
            position: 'absolute',
            right: -120,
            top: 120,
            width: 680,
            height: 840,
            borderRadius: 28,
            background: '#151614',
            border: '2px solid #2A2B28',
            filter: 'blur(6px)',
            opacity: 0.6,
          }}
        />
        <svg viewBox="0 0 256 256" width={128} height={128} style={{position: 'absolute', left: 104, top: 392}}>
          <polygon
            points="50,32 94,32 94,146.4 184.5,94.2 206.5,132.3 50,222.6"
            fill="none"
            stroke={C.green}
            strokeWidth={10}
            strokeLinejoin="round"
            pathLength={1}
            strokeDasharray={`${draw} 1`}
            style={{filter: 'drop-shadow(0 0 12px rgba(141,181,145,.6))'}}
          />
        </svg>
        {receipt && (
          <div
            style={{
              position: 'absolute',
              left: 280,
              top: 428,
              fontSize: 32,
              fontWeight: 500,
              color: C.quiet,
              opacity: receiptK,
              transform: `translateY(${(1 - receiptK) * 10}px)`,
            }}
          >
            <span style={{color: C.green}}>✓</span> {s.copy.receipt}
          </div>
        )}
        <div
          style={{
            position: 'absolute',
            left: 104,
            top: 572,
            width: 1520,
            fontFamily: fonts.display,
            fontWeight: 500,
            fontSize: 60,
            lineHeight: 1.3,
            letterSpacing: '-0.02em',
          }}
        >
          {text}
          {beat >= s.streamFrom[0] && <Caret size={60} />}
        </div>
      </AbsoluteFill>
      <Headline lines={[s.copy.headline[0]]} style={{fontSize: 72}} />
      <div style={{position: 'absolute', left: 104, top: 160, fontFamily: fonts.display, fontWeight: 800, fontSize: 72, lineHeight: 1, letterSpacing: '-0.05em', color: '#5C5D58'}}>
        {s.copy.headline[1]}
      </div>
      <Vignette />
    </Void>
  );
};

// ── 6 · Generate ────────────────────────────────────────────────────────────
export const Generate: React.FC = () => {
  const s = scene('generate');
  const beat = useCurrentFrame() / framesPerBeat;
  const sy = (i: number) => 328 + i * 156;
  const cy = (i: number) => 292 + i * 124;
  const cardAt = (c: number) => {
    const link = s.links.find(([, cc]) => cc === c)!;
    return s.slideAt[link[0]] + s.threadBeats;
  };
  const red = beat >= s.emptyAt;

  return (
    <Void>
      <Grid />
      <Headline lines={[s.copy.headline[0]]} style={{fontSize: 72}} />
      <div style={{position: 'absolute', left: 104, top: 160, fontFamily: fonts.display, fontWeight: 800, fontSize: 72, lineHeight: 1, letterSpacing: '-0.05em', color: '#5C5D58'}}>
        {s.copy.headline[1]}
      </div>
      <svg width={1920} height={1080} style={{position: 'absolute', inset: 0}}>
        <defs>
          <filter id="tb" x="-20%" y="-50%" width="140%" height="200%">
            <feGaussianBlur stdDeviation="8" />
          </filter>
        </defs>
        {s.links.map(([sl, c], k) => {
          const t0 = s.slideAt[sl];
          const p = interpolate(beat, [t0, t0 + s.threadBeats], [0, 1], {...clamp, easing: easeOut});
          if (p <= 0) return null;
          const d = `M424 ${sy(sl) + 46} C 680 ${sy(sl) + 46}, 720 ${cy(c) + 44}, 940 ${cy(c) + 44}`;
          return (
            <g key={k}>
              <path d={d} pathLength={1} strokeDasharray={`${p} 1`} fill="none" stroke={C.green} strokeWidth={12} opacity={0.3} filter="url(#tb)" />
              <path d={d} pathLength={1} strokeDasharray={`${p} 1`} fill="none" stroke={C.greenBright} strokeWidth={3.2} />
            </g>
          );
        })}
      </svg>
      {s.copy.slides.map((n, i) => {
        const empty = n === s.copy.emptySlide && red;
        return (
          <div
            key={n}
            style={{
              position: 'absolute',
              left: 144,
              top: sy(i),
              width: 280,
              height: 92,
              background: '#1A1B19',
              border: empty ? '4px solid #E88E7D' : '2px solid #34352F',
              borderRadius: 14,
              padding: '12px 20px',
              fontWeight: 600,
              fontSize: 25,
              boxShadow: empty ? '0 0 60px rgba(232,142,125,.35)' : undefined,
            }}
          >
            Slide {n}
            {empty && <div style={{color: '#E88E7D', fontSize: 23}}>{s.copy.emptyLabel}</div>}
          </div>
        );
      })}
      {s.copy.cards.map(([kind, label], i) => {
        const k = interpolate(beat, [cardAt(i) - 0.05, cardAt(i) + 0.25], [0, 1], {...clamp, easing: easeOut});
        const solve = kind === 'SOLVE';
        return (
          <div
            key={label}
            style={{
              position: 'absolute',
              left: 940,
              top: cy(i),
              width: 660,
              height: 88,
              background: solve ? '#1F2A20' : '#1A1B19',
              border: `2px solid ${solve ? C.greenDeep : '#34352F'}`,
              borderRadius: 16,
              padding: '0 24px',
              display: 'flex',
              alignItems: 'center',
              gap: 20,
              fontSize: 26,
              opacity: k,
              transform: `translateX(${(1 - k) * 24}px)`,
              boxShadow: solve ? '0 0 48px rgba(141,181,145,.2)' : undefined,
            }}
          >
            <span
              style={{
                display: 'inline-flex',
                height: 36,
                alignItems: 'center',
                padding: '0 12px',
                borderRadius: 8,
                fontSize: 20,
                fontWeight: 700,
                ...(solve ? {background: C.ink, color: '#111'} : {border: '2px solid #4A4B46', color: C.quiet}),
              }}
            >
              {kind}
            </span>
            {label}
          </div>
        );
      })}
      <div
        style={{
          position: 'absolute',
          left: 1640,
          top: 500,
          width: 220,
          color: C.quiet,
          fontSize: 26,
          lineHeight: 1.35,
          opacity: interpolate(beat, [3, 3.5], [0, 1], clamp),
        }}
      >
        {s.copy.aside}
      </div>
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
  slides: Slides,
  ask: Ask,
  generate: Generate,
};
