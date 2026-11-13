// A proxy in front of an HLS CDN that shapes the link to a schedule, the same for any player behind it.
//
//   node scripts/hls-stand/proxy.mjs [--port 8410] [--upstream https://devstreaming-cdn.apple.com] [--results DIR]
//
// Every path not under /control or /stand goes to the upstream host as is (relative URIs in the playlists keep working).
// All responses share one link: their bodies leave in 16 KB pieces through a single FIFO paced at the current rate,
// as a shaper on the interface does. The schedule's clock starts at the first proxied request after a reset.
//
// Control (JSON):
//   POST /control/reset  {label, schedule: [{at: s, kbps: n | null}], rttMs}  null = unlimited
//   POST /control/result {...}    the page's result, written to <results>/<label>.hlsjs.json
//   GET  /control/status          {label, started, results}
// Requests are logged to <results>/<label>.requests.jsonl; <results> defaults to .agents/hls-stand/.

import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => (arg.startsWith('--') ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs), []),
);
const port = Number(args.port ?? 8410);
const upstream = new URL(args.upstream ?? 'https://devstreaming-cdn.apple.com');
// Raw results stay out of git: .agents/ is ignored.
const resultsDir = path.resolve(args.results ?? path.join(here, '../../.agents/hls-stand'));
fs.mkdirSync(resultsDir, { recursive: true });

const agent = new (upstream.protocol === 'https:' ? https : http).Agent({ keepAlive: true, maxSockets: 16 });
const client = upstream.protocol === 'https:' ? https : http;

let run = { label: 'idle', schedule: [{ at: 0, kbps: null }], rttMs: 0, start: null, results: 0, seq: 0 };

const elapsed = () => (run.start === null ? 0 : (Date.now() - run.start) / 1000);
function rateBytesPerSecond() {
  const t = elapsed();
  let kbps = null;
  for (const step of run.schedule) if (step.at <= t) kbps = step.kbps;
  return kbps ? (kbps * 1000) / 8 : Infinity;
}

// One FIFO for every body: a piece leaves when the link is free, then holds it for its size at the current rate.
let linkFreeAt = 0;
function sendAt(bytes) {
  const rate = rateBytesPerSecond();
  const now = performance.now();
  if (rate === Infinity) {
    linkFreeAt = now;
    return now;
  }
  const at = Math.max(now, linkFreeAt);
  linkFreeAt = at + (bytes / rate) * 1000;
  return at;
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));

function logRequest(entry) {
  fs.appendFileSync(path.join(resultsDir, `${run.label}.requests.jsonl`), JSON.stringify(entry) + '\n');
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

function json(res, status, value) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(value));
}

const hopByHop = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'te', 'trailer']);

async function proxy(req, res) {
  if (run.start === null) {
    run.start = Date.now();
    linkFreeAt = 0;
  }
  const id = ++run.seq;
  const t0 = elapsed();
  if (run.rttMs) await sleep(run.rttMs);
  const headers = { ...req.headers, host: upstream.host };
  for (const h of hopByHop) delete headers[h];
  delete headers['accept-encoding'];
  const upReq = client.request(
    { protocol: upstream.protocol, host: upstream.hostname, port: upstream.port || undefined, path: req.url, method: req.method, headers, agent },
    async (upRes) => {
      const ttfb = elapsed();
      const out = { ...upRes.headers, 'cache-control': 'no-store' };
      for (const h of hopByHop) delete out[h];
      delete out['age'];
      delete out['expires'];
      res.writeHead(upRes.statusCode, out);
      let bytes = 0;
      let closed = false;
      res.on('close', () => (closed = true));
      try {
        for await (const chunk of upRes) {
          for (let offset = 0; offset < chunk.length; offset += 16384) {
            const piece = chunk.subarray(offset, offset + 16384);
            await sleep(sendAt(piece.length) - performance.now());
            if (closed) throw new Error('client closed');
            if (!res.write(piece)) await new Promise((resolve) => res.once('drain', resolve));
            bytes += piece.length;
          }
        }
        res.end();
        logRequest({ id, path: req.url, range: req.headers.range ?? null, status: upRes.statusCode, length: Number(upRes.headers['content-length'] ?? -1), bytes, t0, ttfb, end: elapsed(), aborted: false });
      } catch {
        upRes.destroy();
        logRequest({ id, path: req.url, range: req.headers.range ?? null, status: upRes.statusCode, length: Number(upRes.headers['content-length'] ?? -1), bytes, t0, ttfb, end: elapsed(), aborted: true });
      }
    },
  );
  upReq.on('error', (error) => {
    logRequest({ id, path: req.url, error: String(error), t0, end: elapsed() });
    if (!res.headersSent) json(res, 502, { error: String(error) });
    else res.destroy();
  });
  // The response's close, not the request's: a request closes as soon as its (empty) body is read.
  res.on('close', () => {
    if (!res.writableEnded) upReq.destroy();
  });
  req.pipe(upReq);
}

http
  .createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/control/reset' && req.method === 'POST') {
      const body = JSON.parse((await readBody(req)) || '{}');
      run = { label: body.label ?? 'run', schedule: body.schedule ?? [{ at: 0, kbps: null }], rttMs: body.rttMs ?? 0, start: null, results: 0, seq: 0 };
      linkFreeAt = 0;
      fs.rmSync(path.join(resultsDir, `${run.label}.requests.jsonl`), { force: true });
      console.log(`reset ${run.label} schedule=${JSON.stringify(run.schedule)} rtt=${run.rttMs}ms`);
      return json(res, 200, { ok: true });
    }
    if (url.pathname === '/control/result' && req.method === 'POST') {
      const body = JSON.parse(await readBody(req));
      body.proxyStartEpoch = run.start;
      fs.writeFileSync(path.join(resultsDir, `${run.label}.hlsjs.json`), JSON.stringify(body, null, 1));
      run.results += 1;
      console.log(`result ${run.label}`);
      return json(res, 200, { ok: true });
    }
    if (url.pathname === '/control/status') {
      return json(res, 200, { label: run.label, started: run.start, elapsed: elapsed(), results: run.results });
    }
    if (url.pathname.startsWith('/stand/')) {
      const file = path.join(here, path.basename(url.pathname));
      if (!fs.existsSync(file)) return json(res, 404, { error: 'no such file' });
      res.writeHead(200, { 'content-type': file.endsWith('.html') ? 'text/html' : 'application/javascript', 'cache-control': 'no-store' });
      return fs.createReadStream(file).pipe(res);
    }
    proxy(req, res);
  })
  .listen(port, '127.0.0.1', () => console.log(`proxy on http://127.0.0.1:${port} -> ${upstream.origin}`));
