import React from 'react';
import {C} from './timeline';
import {fonts} from './ui';

// Geometry is the storyboard's mountain, in its own coordinate space.
// The visible window is x 166..1126, y 72..612 (960 x 540), drawn at 2x.
export const VIEW = {x: 166, y: 72, w: 960, h: 540};
export const toScreen = (x: number, y: number) => ({
  x: (x - VIEW.x) * 2,
  y: (y - VIEW.y) * 2,
});

const RIDGE =
  'M380 720 L520 470 L640 330 L700 300 L790 170 L860 250 L900 240 L1000 350 L1120 420 L1120 720 Z';

const ROUTES = [
  'M470 720 C 520 690, 430 660, 480 640 S 570 650, 545 612 S 465 592, 515 575 S 600 586, 612 558',
  'M722 720 C 805 702, 862 690, 832 652 S 738 642, 782 612 S 902 602, 882 562 S 818 522, 900 497 S 962 482, 942 466',
  'M985 720 C 1062 690, 1042 652, 992 640 S 940 602, 1010 582 S 1090 542, 1040 522 S 962 492, 1002 470',
];
const ROUTE_LABELS: [number, number, 'start' | 'end'][] = [
  [470, 606, 'start'],
  [860, 600, 'start'],
  [1092, 560, 'end'],
];
// Routes and fog sit 50 units higher than in the storyboard so they read on screen.
const ROUTE_SHIFT = -50;
// [cx, cy, rx, ry, drift direction]
const MIST: [number, number, number, number, number][] = [
  [590, 540, 150, 30, 1],
  [900, 470, 190, 34, -1],
  [1030, 470, 130, 26, 1],
  [760, 505, 320, 14, -1],
];

const TRAIL: [number, number][] = [
  [612, 720], [700, 640], [660, 590], [742, 520], [705, 470],
  [770, 400], [742, 350], [790, 290], [774, 240], [790, 172],
];
const TRAIL_D = `M${TRAIL.map((p) => p.join(' ')).join(' L')}`;

/** Stone centres along the trail, like the storyboard (evenly by segment). */
export const stonePositions = (count: number) => {
  const segs = TRAIL.length - 1;
  return Array.from({length: count}, (_, j) => {
    const f = ((j + 0.5) / count) * segs;
    const si = Math.min(segs - 1, Math.floor(f));
    const t = f - si;
    const [a, b] = [TRAIL[si], TRAIL[si + 1]];
    return {x: a[0] + (b[0] - a[0]) * t, y: a[1] + (b[1] - a[1]) * t};
  });
};

export type MountainProps = {
  routes?: {progress: number; label: string; labelOpacity: number}[];
  routesOpacity?: number;
  fogOpacity?: number;
  fogDrift?: number; // 0..1 over the scene
  trail?: number; // 0..1 drawn
  stones?: {scale: number; opacity: number}[]; // per stone
  highlightStone?: number;
  stoneFill?: string; // fill for the highlighted stone (used during the dive)
  chip?: string;
};

export const Mountain: React.FC<MountainProps> = ({
  routes,
  routesOpacity = 1,
  fogOpacity = 0,
  fogDrift = 0,
  trail = 0,
  stones = [],
  highlightStone,
  stoneFill = C.ink,
  chip,
}) => {
  const pos = stonePositions(stones.length || 12);
  return (
    <svg
      viewBox={`${VIEW.x} ${VIEW.y} ${VIEW.w} ${VIEW.h}`}
      width={1920}
      height={1080}
      style={{position: 'absolute', inset: 0, overflow: 'visible'}}
    >
      <defs>
        <filter id="blur9" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="9" />
        </filter>
        <filter id="blur22" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="22" />
        </filter>
        <filter id="blur18" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="18" />
        </filter>
        <linearGradient id="face" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#262724" />
          <stop offset="1" stopColor="#121311" />
        </linearGradient>
        <linearGradient id="fadeUp" gradientUnits="userSpaceOnUse" x1="0" y1="650" x2="0" y2="470">
          <stop offset="0" stopColor="#fff" />
          <stop offset="1" stopColor="#000" />
        </linearGradient>
        <clipPath id="ridge">
          <path d={RIDGE} />
        </clipPath>
        {routes?.map((r, i) => (
          <mask id={`reveal${i}`} key={i} maskUnits="userSpaceOnUse" x={0} y={0} width={2000} height={2000}>
            <path
              d={ROUTES[i]}
              pathLength={1}
              fill="none"
              stroke="url(#fadeUp)"
              strokeWidth={30}
              strokeDasharray={`${r.progress} 2`}
            />
          </mask>
        ))}
      </defs>

      {/* far ridges */}
      <path d="M300 720 L430 540 L478 566 L560 470 L612 500 L660 450 L700 720 Z" fill="#111210" />
      <path d="M900 720 L990 330 L1040 362 L1080 318 L1120 340 L1120 720 Z" fill="#111210" />
      {/* main face */}
      <path d={RIDGE} fill="url(#face)" stroke="#3A3B38" />
      <g clipPath="url(#ridge)">
        <path
          d="M790 170 L860 250 L900 240 L1000 350 L1120 420 L1120 720 L820 720 L846 612 L800 476 L832 384 L800 262 Z"
          fill="#0E0F0D"
          opacity={0.85}
        />
        <path
          d="M640 330 L684 378 L670 420 M520 470 L578 512 L566 560 M900 240 L884 300 L910 352 M1000 350 L962 420 L984 470"
          fill="none"
          stroke="#2E2F2C"
          strokeWidth={1.4}
        />
        <path d="M790 170 L748 228 L762 222 L771 238 L788 224 L803 241 L818 225 L846 234 Z" fill="#4A4B46" />

        {/* guessed routes: they crawl up and fade out into the mist */}
        {routes && (
          <g opacity={0.8 * routesOpacity} transform={`translate(0 ${ROUTE_SHIFT})`}>
            {routes.map((r, i) => (
              <path
                key={i}
                d={ROUTES[i]}
                fill="none"
                stroke={C.faint}
                strokeWidth={2.4}
                strokeDasharray="4 6"
                mask={`url(#reveal${i})`}
              />
            ))}
          </g>
        )}

        {/* mist: wide, soft bands drifting across where the routes give out */}
        {fogOpacity > 0 && (
          <g opacity={fogOpacity} transform={`translate(0 ${ROUTE_SHIFT})`} filter="url(#blur22)">
            {MIST.map(([cx, cy, rx, ry, dir], i) => (
              <ellipse key={i} cx={cx + dir * fogDrift * 40} cy={cy} rx={rx} ry={ry} fill="#34352F" opacity={0.24} />
            ))}
          </g>
        )}

        {/* the route */}
        {trail > 0 && (
          <g>
            <path
              d={TRAIL_D}
              pathLength={1}
              strokeDasharray={`${trail} 2`}
              fill="none"
              stroke={C.green}
              strokeWidth={14}
              opacity={0.35}
              filter="url(#blur9)"
              strokeLinejoin="round"
            />
            <path
              d={TRAIL_D}
              pathLength={1}
              strokeDasharray={`${trail} 2`}
              fill="none"
              stroke={C.greenBright}
              strokeWidth={3.5}
              strokeLinejoin="round"
              strokeLinecap="round"
            />
          </g>
        )}

        {/* stones */}
        {stones.map((s, j) => {
          if (s.opacity <= 0) return null;
          const big = j === highlightStone;
          const size = (big ? 24 : 12) * s.scale;
          const p = pos[j];
          return (
            <rect
              key={j}
              x={p.x - size / 2}
              y={p.y - size / 2}
              width={size}
              height={size}
              rx={(big ? 5 : 2.5) * s.scale}
              fill={big ? stoneFill : C.ink}
              opacity={s.opacity}
              stroke={big ? C.green : undefined}
              strokeWidth={big ? 3 : undefined}
            />
          );
        })}
      </g>

      {routes && (
        <g opacity={routesOpacity} transform={`translate(0 ${ROUTE_SHIFT})`}>
          {routes.map((r, i) => (
            <text
              key={i}
              x={ROUTE_LABELS[i][0]}
              y={ROUTE_LABELS[i][1]}
              textAnchor={ROUTE_LABELS[i][2]}
              fontSize={16}
              fill={C.quiet}
              fontWeight={600}
              fontFamily={fonts.text}
              opacity={r.labelOpacity * 0.85}
            >
              {r.label}
            </text>
          ))}
        </g>
      )}

      {/* flag + exam date */}
      <path d="M791 172 V118" stroke={C.ink} strokeWidth={2} />
      <path d="M791 120 L826 131 L791 142 Z" fill={C.ink} />
      {chip && (
        <g transform="translate(744 80)">
          <rect width={96} height={30} rx={8} fill="#1E1F1D" stroke="#41423E" />
          <text
            x={48}
            y={20}
            textAnchor="middle"
            fontSize={14}
            fontWeight={700}
            fill={C.ink}
            fontFamily={fonts.text}
          >
            {chip}
          </text>
        </g>
      )}
    </svg>
  );
};
