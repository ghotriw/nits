// One run of a player behind the shaping proxy (proxy.mjs must be running).
//
//   node scripts/hls-stand/run.mjs --player hlsjs|nits --label NAME [--src /videos/.../master.m3u8] [--seconds 90]
//                [--schedule "0:none,45:2000"] [--rtt 0] [--maxBuf 30] [--browser chrome|safari] [--port 8410]
//
// Schedule: "at:kbps" steps from the first request, "none" = unlimited. Results go to .agents/hls-stand/NAME.* (--results).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => (arg.startsWith('--') ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs), []),
);
const player = args.player;
const label = args.label;
if (!['hlsjs', 'nits'].includes(player) || !label) {
  console.error('usage: node run.mjs --player hlsjs|nits --label NAME [...]');
  process.exit(2);
}
const port = Number(args.port ?? 8410);
const base = `http://127.0.0.1:${port}`;
const src = args.src ?? '/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8';
const seconds = Number(args.seconds ?? 90);
const schedule = (args.schedule ?? '0:none').split(',').map((step) => {
  const [at, kbps] = step.split(':');
  return { at: Number(at), kbps: kbps === 'none' ? null : Number(kbps) };
});
const resultsDir = path.resolve(args.results ?? path.join(repo, '.agents/hls-stand'));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const control = async (p, body) => (await fetch(base + p, body ? { method: 'POST', body: JSON.stringify(body) } : {})).json();

await control('/control/reset', { label, schedule, rttMs: Number(args.rtt ?? 0) });

if (player === 'hlsjs') {
  const query = new URLSearchParams({ src, seconds: String(seconds), label });
  if (args.maxBuf) query.set('maxBuf', args.maxBuf);
  const page = `${base}/stand/stand.html?${query}`;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'hls-stand-'));
  const browser = args.browser ?? 'chrome';
  const child =
    browser === 'safari'
      ? spawn('open', ['-W', '-n', '-a', 'Safari', page])
      : spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
          `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--disable-extensions',
          '--autoplay-policy=no-user-gesture-required', '--disable-background-timer-throttling',
          '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', '--new-window', page,
        ], { stdio: 'ignore' });
  const deadline = Date.now() + (seconds + 120) * 1000;
  while ((await control('/control/status')).results === 0 && Date.now() < deadline) await sleep(500);
  if (browser === 'safari') console.log('close the Safari window by hand');
  else child.kill();
  await sleep(500);
  fs.rmSync(profile, { recursive: true, force: true });
  summarizeHlsjs();
} else {
  const env = {
    ...process.env,
    PKG_CONFIG_PATH: path.join(repo, '.build/dependencies/lib/pkgconfig'),
    NITS_MEASURE_START_URL: base + src,
    NITS_MEASURE_START_SECONDS: String(seconds),
    NITS_MEASURE_LABEL: label,
  };
  const output = fs.createWriteStream(path.join(resultsDir, `${label}.nits.txt`));
  const child = spawn('swift', ['test', '--skip-build', '--filter', 'ABRStartRealMeasurement'], { cwd: repo, env });
  let text = '';
  for await (const chunk of child.stdout) {
    output.write(chunk);
    text += chunk;
  }
  output.end();
  for (const line of text.split('\n')) if (line.includes('MEASURE-REAL')) console.log(line.replace(/^.*MEASURE-REAL/, ''));
}
summarizeRequests();

function summarizeHlsjs() {
  const r = JSON.parse(fs.readFileSync(path.join(resultsDir, `${label}.hlsjs.json`), 'utf8'));
  const at = (t) => ((t - r.proxyStartEpoch) / 1000).toFixed(1);
  const drop = schedule.find((s) => s.at > 0)?.at;
  console.log(`hls.js ${r.hlsVersion} label=${label} config=${JSON.stringify(r.config)} levels=${r.levels.map((l) => `${l.height}p@${Math.round(l.bitrate / 1000)}k`).join(' ')}`);
  console.log(`firstPicture=${r.firstPicture ? at(r.firstPicture) : 'none'} s stalled=${r.stalled.toFixed(1)} s`);
  for (const s of r.stalls) console.log(`  stall ${at(s.start)}-${at(s.end)} s (${((s.end - s.start) / 1000).toFixed(1)} s) at position ${s.position.toFixed(1)}`);
  const timeline = r.events.filter((e) => ['decided', 'shown', 'abandoned', 'error', 'manifest'].includes(e.type));
  let lastShown = null;
  for (const e of timeline) {
    if (e.type === 'shown') {
      if (e.level === lastShown) continue;
      lastShown = e.level;
    }
    const { t, type, ...rest } = e;
    console.log(`  ${at(t)} s ${type} ${JSON.stringify(rest)}`);
  }
  if (drop !== undefined) {
    const sample = r.samples.reduce((best, s) => (Math.abs(s.t - r.proxyStartEpoch - drop * 1000) < Math.abs(best.t - r.proxyStartEpoch - drop * 1000) ? s : best));
    console.log(`at the change (${drop} s): buffer=${sample.buffer.toFixed(1)} s estimate=${sample.estimate}k level=${sample.level}`);
  }
}

function summarizeRequests() {
  const file = path.join(resultsDir, `${label}.requests.jsonl`);
  if (!fs.existsSync(file)) return;
  const requests = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  const aborted = requests.filter((q) => q.aborted);
  const bytes = requests.reduce((sum, q) => sum + (q.bytes ?? 0), 0);
  console.log(`requests=${requests.length} bytes=${(bytes / 1e6).toFixed(1)} MB aborted=${aborted.length} (log: ${path.relative(repo, file)})`);
  for (const q of aborted) console.log(`  aborted ${q.t0.toFixed(1)}-${q.end.toFixed(1)} s ${q.path} ${q.bytes}/${q.length}`);
}
