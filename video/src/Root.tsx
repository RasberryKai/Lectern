import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {Film} from './Film';
import {FPS, HEIGHT, TOTAL_FRAMES, WIDTH} from './timeline';

const Root: React.FC = () => (
  <Composition
    id="LaunchFilm"
    component={Film}
    durationInFrames={TOTAL_FRAMES}
    fps={FPS}
    width={WIDTH}
    height={HEIGHT}
  />
);

registerRoot(Root);
