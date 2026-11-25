import React from 'react';
import {AbsoluteFill, staticFile} from 'remotion';
import {loadFont} from '@remotion/fonts';
import {C} from './timeline';

// Fonts ship with the project (public/fonts, Google Fonts variable files),
// so renders never depend on the network.
export const fonts = {display: 'Inter Tight', text: 'Inter', logo: 'Newsreader'};
loadFont({family: 'Inter Tight', url: staticFile('fonts/InterTight-latin-var.woff2'), weight: '100 900'});
loadFont({family: 'Inter', url: staticFile('fonts/Inter-latin-var.woff2'), weight: '100 900'});
loadFont({family: 'Newsreader', url: staticFile('fonts/Newsreader-latin-var.woff2'), weight: '200 800'});

/** Near-black void with the v3 grid and a vignette. */
export const Void: React.FC<{children?: React.ReactNode}> = ({children}) => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(120% 90% at 60% 40%, #141513 0%, ${C.bg} 60%, #050505 100%)`,
      fontFamily: fonts.text,
      color: C.ink,
      overflow: 'hidden',
    }}
  >
    {children}
  </AbsoluteFill>
);

export const Grid: React.FC<{opacity?: number}> = ({opacity = 0.8}) => (
  <AbsoluteFill
    style={{
      backgroundImage: `linear-gradient(${C.grid} 2px, transparent 2px), linear-gradient(90deg, ${C.grid} 2px, transparent 2px)`,
      backgroundSize: '80px 80px',
      opacity,
    }}
  />
);

export const Vignette: React.FC = () => (
  <AbsoluteFill
    style={{
      background: 'radial-gradient(110% 85% at 50% 50%, transparent 55%, rgba(0,0,0,.65) 100%)',
      pointerEvents: 'none',
    }}
  />
);

/** Lectern mark (the L-lectern polygon from the brand files). */
export const Mark: React.FC<{size: number; color?: string; glow?: boolean}> = ({
  size,
  color = C.green,
  glow,
}) => (
  <svg
    viewBox="0 0 256 256"
    width={size}
    height={size}
    style={glow ? {filter: 'drop-shadow(0 0 24px rgba(141,181,145,.45))'} : undefined}
  >
    <polygon points="50,32 94,32 94,146.4 184.5,94.2 206.5,132.3 50,222.6" fill={color} />
  </svg>
);

export const Headline: React.FC<{lines: readonly string[]; style?: React.CSSProperties}> = ({
  lines,
  style,
}) => (
  <div
    style={{
      position: 'absolute',
      left: 104,
      top: 88,
      fontFamily: fonts.display,
      fontWeight: 800,
      fontSize: 84,
      lineHeight: 1,
      letterSpacing: '-0.05em',
      ...style,
    }}
  >
    {lines.map((l) => (
      <div key={l}>{l}</div>
    ))}
  </div>
);
