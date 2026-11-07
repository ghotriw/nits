# Measurements

Tests that measure instead of assert: each is skipped (`.enabled(if:)` on an environment variable) unless asked for, so
a normal `swift test` only compiles them. They use `@testable` internals, which is why they live in the test target.
Run with the bundled FFmpeg: `PKG_CONFIG_PATH=$PWD/.build/dependencies/lib/pkgconfig swift test --filter <suite>`.
Every output line starts with `MEASURE`; keep results in `docs/` (ROADMAP / OPEN_ISSUES), not here.

**The environment is part of the result.** Network Link Conditioner (NLC) can't be scripted: agree the profile with the
person at the machine before each series, write the RTT (`ping -c 3 -q devstreaming-cdn.apple.com`) next to it, and
don't change it until the run says it is over. Apple's CDN keeps its HLS examples `max-age=600`: a cold-cache run needs
ten minutes without one before it, and a series throws away its first (warm-up) run. Run the local suites with NLC off
(it slows `TestHTTPServer` too).

| Suite (file) | Question | Enabled by | Other variables |
|---|---|---|---|
| `Ladder seek measurement` (`LadderSeekMeasurement.swift`) | How long a seek takes on a real ladder (demuxer vs. decode, bytes, request latency), cache or network | `NITS_MEASURE_URL` | `NITS_MEASURE_N` (rounds, 6) |
| `Ladder ABR seek measurement` (same file) | In real-time playback with adaptive bitrate, how many seeks back the cache serves, and how many cross a variant splice | `NITS_MEASURE_ABR` + `NITS_MEASURE_URL` | `NITS_MEASURE_ABR_SECONDS` (150), `NITS_MEASURE_ABR_SEEK_EVERY` (20, playhead seconds) |
| `ABR start measurement` (`ABRStartMeasurement.swift`) | Start on a slow link: opening, time to the first picture, stalls, the width over time. Synthetic ladder behind `TestHTTPServer` at a rate | `NITS_MEASURE_START` | `NITS_LINK_KBPS` ("1500,600"), `NITS_MEASURE_START_SECONDS` (60) |
| `ABR start measurement, real stream` (same file) | The opening's prefetch rate (wait and bodies told apart) against the estimate playback reaches; when the picture changes against when ABR decided | `NITS_MEASURE_START_URL` | `NITS_MEASURE_START_SECONDS` (25; 90-120 on a slow link), `NITS_MEASURE_LABEL` (e.g. "RTT+150 cold"), `NITS_MEASURE_START_KBPS` (start on the switchable variant nearest that bandwidth, adaptive bitrate on) |

Streams used so far (`https://devstreaming-cdn.apple.com/videos/streaming/examples/`): `bipbop_adv_example_hevc/master.m3u8`
(54 variants), `av1-sample/av1-sample.m3u8`; see `docs/ROADMAP.md` (Stage 3.5) for the series already recorded.

## Reading the output

- `LadderSeek`: `seek=` is the demuxer's, `decode=` the preview's; `bytes=0 latency=0` means the cache served it.
- `LadderABRSeek`: `fromCache=false` with `splicesBetween` > 0 is the splice rule working; the stall count includes the
  start. A seek back every 10 s of playhead leaves almost no net progress, so the network is barely used (nothing to
  adapt to): keep `NITS_MEASURE_ABR_SEEK_EVERY` at 30 or more for ABR to move.
- `ABRStart` real stream: `prefetch=[... wait ... bodies ... window ...]` needs `HLSPlaylistPrefetcher.measuredThroughput`
  (logs when the opening ends); `decided=` is the read position's choice, `shown=` what the picture was.
