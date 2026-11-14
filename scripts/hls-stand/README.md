# HLS stand: Nits and hls.js behind one shaped link

Plays a real HLS stream through Nits or through hls.js in Chrome, behind a proxy that shapes the link to a schedule, so
both see the same network to the tenth of a second and a series runs unattended. Method and results: "Measuring" in
`docs/HLS.md`.

- `proxy.mjs`: forwards every path to the CDN (`--upstream`, Apple's by default), relative URIs in the playlists
  unchanged. All bodies share one FIFO paced at the schedule's rate (16 KB pieces), as a shaper on the interface does;
  the schedule's clock starts at the first request after a reset. Logs each request (`t0`, `ttfb`, `end`, `bytes`,
  `length`, `aborted`).
- `stand.html`: hls.js 1.7.3 (jsdelivr) on a muted `<video>`. Logs stalls (the position still after the first picture),
  the levels decided and shown, `FRAG_LOAD_EMERGENCY_ABORTED`, buffer and estimate each second, and posts it all back.
- `run.mjs`: one run. Resets the proxy with the schedule, starts Chrome with a fresh profile (no HTTP cache) or Nits'
  `ABRStartRealMeasurement`, waits, and prints a summary.

```sh
node scripts/hls-stand/proxy.mjs &      # once; stop with: pkill -f hls-stand/proxy.mjs
PKG_CONFIG_PATH=$PWD/.build/dependencies/lib/pkgconfig swift build --build-tests   # for Nits' runs
node scripts/hls-stand/run.mjs --player hlsjs --label drop-hlsjs-1 --seconds 90 --schedule "0:none,45:2000"
node scripts/hls-stand/run.mjs --player hlsjs --label drop-hlsjs30-1 --seconds 90 --schedule "0:none,45:2000" --maxBuf 30
node scripts/hls-stand/run.mjs --player nits  --label drop-nits-1 --seconds 90 --schedule "0:none,45:2000"
```

Results go to `.agents/hls-stand/` (out of git). A series is a loop over these lines, the players interleaved.

Read the results with care:
- The shaper is deterministic: three runs of a scenario come out nearly the same, so they are one sample of it, not
  three. Vary the scenario (moment of the drop, rates, buffer) rather than repeating it.
- Nits' summary names a variant by its **width** (`640p@1240k` is 640×360), hls.js's by its **height**. Compare by the
  rung's size, and only within one ladder: on Apple's HEVC example Chrome plays HEVC + AAC, Nits AVC + AC-3.
- hls.js buffers up to 60 MB by default (`maxBufferSize`; ~75 s at 6.6 Mbit/s): `maxBufferLength` is only its floor.
  `--maxBuf N` caps `maxBufferLength` and `maxMaxBufferLength` at N, to compare at Nits' 30 s read-ahead.
- Clocks: the schedule and hls.js's events count from the proxy's first request; Nits' `asked=` / `decided=` / `shown=` from
  the end of its opening (add `open=`).
- Nits' `decided=` is when a switch spliced, not when it began (`asked=`): a step down begun at 10 s and spliced after a
  slow segment read as a step up at 45.8 s (2026-11-14).
- Nits' measurement takes no sound through an audio renderer; hls.js plays muted sound in the browser.
- RTT is the real one to the CDN (the proxy adds none unless `--rtt`): check the node first (`dig`, `ping -c 10`) and
  measure on one without loss.
- Chrome needs hardware HEVC for that example (Apple Silicon); `--browser safari` opens Safari, closed by hand.
