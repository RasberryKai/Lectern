// Renders the film, then brings the audio to web loudness (-14 LUFS).
// Usage: npm run render  [-- any extra `remotion render` flags]
import {execFileSync} from 'node:child_process';
import {mkdirSync, rmSync} from 'node:fs';

const out = 'out/lectern-launch-s1-3.mp4';
const raw = 'out/_raw.mp4';
const extra = process.argv.slice(2);
mkdirSync('out', {recursive: true});
const run = (args) => execFileSync('npx', args, {stdio: 'inherit'});

run(['remotion', 'render', 'LaunchFilm', raw, ...extra]);
run([
  'remotion', 'ffmpeg', '-y', '-v', 'error', '-i', raw,
  '-c:v', 'copy',
  '-af', 'loudnorm=I=-14:TP=-1.5:LRA=11',
  '-ar', '48000', '-c:a', 'aac', '-b:a', '256k',
  '-movflags', '+faststart', out,
]);
rmSync(raw);
console.log(`\nDone: ${out}`);
