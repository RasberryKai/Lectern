// Renders the film. The mix is set in timeline.ts (no loudness pass afterwards,
// so the quiet piano intro stays quiet and the drop keeps its jump).
// Usage: npm run render  [-- any extra `remotion render` flags]
import {execFileSync} from 'node:child_process';

const out = 'out/lectern-launch-s1-6.mp4';
execFileSync(
  'npx',
  ['remotion', 'render', 'LaunchFilm', out, '--audio-bitrate=256k', ...process.argv.slice(2)],
  {stdio: 'inherit'},
);
console.log(`\nDone: ${out}`);
