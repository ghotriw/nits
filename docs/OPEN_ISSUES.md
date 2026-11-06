# Open Issues

Problems that still need data or a real-world check. Fixed issues live on in the code, `docs/ARCHITECTURE.md`,
`AGENTS.md` and git history; remove an entry here once it is resolved.

## PRIORITY: changing the audio delay while playing external audio starts buffering, and it can stay on

**Observed by hand (2026-11-01)**: playing a video with an external audio track (an added audio file) and turning the
audio delay (`stepAudioDelay` / `setAudioDelay`) shows the preloader, and sometimes everything stops: pause / play or a
seek helps. Seeks with external audio are fine. **Not caused by the seek / `AudioJoin` rework of that day**: reproduced
the same on the last commit before it (`c1917d3`). With the audio inside the video file it does not happen.

**Reproduction** (a test, not committed; the file is in `.agents/scratch/ExternalAudioDelayRepro.swift.txt`, to be
copied to `Tests/NitsCoreTests/` as a `.swift`; `.agents` is untracked, so only on this machine): `wideGOPH264` as the video, `multiTrackH264` attached as external
audio and selected, `waitForPlayback`, then 10 steps of ±0.1 s of delay, 150 ms apart, and poll `isBuffering` for 8 s.
Four trials: buffering in 4 of 4, still on after 6 s with the clock advanced 0.1–0.2 s in 1 of 4 (on both the current
code and `c1917d3`); the same with the audio inside the video: none.

**What is known, not verified:** for audio on an input of its own `BufferingPolicy.isStarved` takes the renderer running
dry as enough (`isAudioDry`), where for shared audio the frame queue has to be low too; `applyAudioDelay` flushes the
renderer under the running clock (`DelayedAudioSink.changeDelay`) and puts the held audio back, so the renderer is empty
for a moment and the check holds the clock. Why buffering does not end: unknown. Suspects: a second step of the delay
flushing again while the first replay is on its way (`decoder.requeue(_, generation:)` drops a replay of an older
generation), so the audio from the held position is not there when `isReadyToResume` wants `audioResume` seconds ahead of
it; or the feeder run being restarted while the clock is held.

**Directions:** the renderer emptied by a delay change is not a shortage (hold the starvation check, or the separate-audio
rule, for the length of the replay); and find why the resume does not come, starting from the reproduction above with
`NITS`-level logging of `bufferedEnd` and the held clock.

## Root cause of the hardware VP9 decoder stall

**Observed once** (October 2026) playing a 1080p50 VP9 MP4 with hardware decoding (supplemental decoder), after
heavy UI activity and a `sample` of the process. The feeder was blocked in `VTDecompressionSessionDecodeFrame →
RemoteVideoDecoder_DecodeFrameWithOptions → FigSemaphoreWaitRelative` while the session's `VTDecoderXPCService`
sat idle (0 % CPU): waiting for something, not decoding. `vmmap` showed no IOSurface build-up in Nits.

The stall itself is now recovered from (see "Stalls and buffering" in `docs/ARCHITECTURE.md`); the cause is
unknown. Hypotheses: output-buffer pool exhaustion (surfaces held by the display layer / a busy WindowServer), the
process suspension by `sample` disturbing the XPC exchange, or a VideoToolbox bug in the VP9 supplemental decoder.

**If it recurs:** the `Video decoder stalled: …` log line records the display layer's status and
`requiresFlushToResumeDecoding`, the session's frames in flight, the frame queue fill, frame and clock positions
and the playing / seeking / stepping state. The decoder is replaced within 3 s, so run
`sample VTDecoderXPCService` as soon as video freezes.

## `fontd` not answering libass' font requests

**Observed three times** (October 2026, macOS 27) in full test runs, never in the app: every libass thread of the
test process waited in `match_fonts → CopyMatchingFontDescriptors → XTCopyPropertiesForFontsMatchingRequest →
xpc_connection_send_message_with_reply_sync`, `fontd` at 0 % CPU; once 12 threads at once, the whole cooperative
pool, so the run hung. Killing the test process (or `fontd`) cleared it. A probe of 12 threads in 4 processes asking
Core Text for 20 000 unknown families didn't reproduce it. Hypothesis, unchecked: requests that reach `fontd` just
as launchd starts it (in the first hang its PID followed the test process's).

Since then libass calls run one at a time on their own queue, the engine shows the text cues for the rest of the
media once one is stuck (see "libass" in `docs/ARCHITECTURE.md`), and tests reach libass through `LibassRenderer`,
which fails a test after 20 s instead of holding a thread of the run.

**If it recurs:** the `libass has been stuck in a call for …` log line; `sample` the process and check whether `fontd`
was started at about the same time (`ps -o lstart -p $(pgrep fontd)`).

## The line between a Bluetooth device's start and its switch from a placeholder

`AudioOutputInterruptionDetector` re-anchors the clock when a Bluetooth output stops its IO under the started clock after
running `minimumRunDuration` (30 ms): that is how a start that waits for the real A2DP stream (a restart within ~10 ms,
or 24 ms on the built-in speakers, which the Bluetooth-only gate leaves out) is told from the switch away from a
placeholder (AirPods last used by an iPhone). The line is **empirical and drawn from one pair of AirPods**: the switch
came ~100 ms after the run began on 2026-10-24 and 41–43 ms on 2026-11-01 (four starts in a row), so 50 ms missed it,
and what it will be on the next macOS or other earbuds is not known.

A better criterion would be a property of the device that changes only at the switch. The HAL properties watched on
2026-10-24 (`livn`, `goin`, `gone`, `stpd`, `nsrt`, `fsiz`, `ltnc`, `saft`, `stm#`, `slay`) gave `goin` alone, and the
BT plugin reports the A2DP latency on the placeholder already (7680 frames), so the device latency tells nothing. The
IO gap does not separate them either (healthy restarts returned after 200–480 ms, switches after 660–900 ms).
Captures: `.agents/bluetooth-audio-logs/`.

**If choppy Bluetooth audio returns:** find the stop in `player.log` (`Output device N started its IO` → `stopped its
IO`), compare its run length with the line, and look for `Audio output restarted its IO under the running clock`;
record the run length here before moving the line.

## Buffering needs a real-world check

`PlayerEngine+Buffering` (holding the clock while media runs out) is covered only by tests that stop the
feeders. To check in the app:
- a network stream on a throttled connection (e.g. Network Link Conditioner) and a file on a slow share: the
  `Buffering at …` / `Buffering ended after …` log lines should bracket each stall, and playback should resume
  where it stopped;
- a video decoder too slow for realtime (e.g. software 8K AV1), which starves audio through the demuxer's
  read-ahead limit: expected to alternate between buffering and playing rather than drift;
- possible side effect: an audio track that ends before the video, with under 20 frames queued (decoder
  barely keeping up), would alternate between buffering and playing.

The UI does not show `isBuffering` yet.

## A 200 ms frame hold on the display link

**Observed once** (October 2026, 25p Dolby Vision over HTTP from Emby, LG UltraFine at 60 Hz, audio on AirPods): one
frame stayed up 12 ticks (200 ms) and the next four frames never showed
(`held 12×1`, `skipped 4`), with no buffering, network or drop messages; it followed a `−8.6 ms` clock jump. A
negative jump of that kind is what a tick blocked between reading the synchronizer clock and `CACurrentMediaTime()`
produces, so the display-link thread may have been blocked. Not seen in 6 minutes of later runs. The AirPods also
step the clock early in playback (see "Display pacing" in `docs/ARCHITECTURE.md`), so the audio device may matter:
note it when this recurs.

**If it recurs:** the `Frame held …` line (see `docs/LOGGING.md`) tells a link that stopped calling, a tick blocked
on our side (`max tick`, `max clock read`) and an empty frame queue apart.

## Known limitations

Accepted for now, noted for later.

- **A launch flag over a setting shows the saved value in Settings.** With `--no-osd`, the OSD switch reads "on"; the
  flag holds until that setting is changed (`LaunchArguments.dropOverrides`), so turning it on takes off-then-on.
- **Subtitles dropped with a playlist file are not attached.** `MediaOpenRequest.open` attaches them only to the path
  it loaded; a `.m3u` hands on to its first item, so `engine.currentPath` differs and they are only logged.
- **An exact seek into audio past the video's end lands on the last frame.** With audio longer than video (video to
  50 s, audio to 60 s), a seek to 54 s lands on the last frame's 49.96 s: the position is the picture's, while audio
  starts at 54 s, so playback resumes with ~4 s of silence, and the next arrow press steps from 49.96 s again, never
  into the audio-only part. The position after such a seek should be its target.
- **The packet cache serves files and single-variant streams only.** Seeks back (and forward into what was read) skip
  the input only for those (`seekWithinCache`). Multi-variant HLS/DASH, the main network case, and live streams read
  the input again: they keep no history (`maxBackBytes = 0`). mpv caches both (it picks one HLS variant at open, and
  checks `seekable` only on a cache miss), and keeps several cached ranges where we keep one. For ladders a seek in the
  cache would have to account for the variant at the landing (`reportVariant`, the packet's `format`, the decoder) and
  an unfinished `variantSwitch`, as adaptive bitrate switches in the stream and a history can hold several variants;
  for live, to agree with `LiveStream.clamp` and `trackLiveWindow` (a seek back would no longer depend on the playlist's
  window). Each needs tests and measurements of its own.
- **How long a read-ahead takes to end after its server goes away is not known.** A test stopped the server mid-file
  and waited for `readAheadEnded` for 10 s; it did not come (the test was dropped, as a read error cannot be made to
  happen the same way every time). FFmpeg's reconnects or the input's read timeout (`rw_timeout`) may be waiting; not
  checked. Until it is, the time the picture stands after a dropped connection, and when `readAheadEnded` (so the
  cache's refusal of a seek short of the duration) takes effect, are guesses.
- **A timeline break leaves the read-ahead's measure on the old timeline.** After a discontinuity (HLS
  `EXT-X-DISCONTINUITY`: ad insertions, splices) FFmpeg passes the timestamps back from zero. `readAheadState` is the
  furthest time read and does not go back, while `consumedSeconds` follows the packets taken: after 20 minutes of
  media `readAheadState` stays at ~1200 s and `consumedSeconds` starts again from 0, so the next ~20 minutes read as
  "full" and the thread reads only when the queue is empty, with no margin. Expected from the code, not seen on a real
  stream: `bufferedTime` in the UI would be wrong, and adaptive bitrate would see a huge buffer and could step up
  instead of down. It predates the packet cache. A plain reset does not do: `consumedSeconds` stays on the old
  timeline while it plays out. Check before ladders, on a stream with ad insertions; also how the engine (clock,
  position, frame queue) takes the break at all, which the demuxer-level tests do not cover.
- **A stream with breaks gets no cache after the end of its input.** The end is trusted only when what was read reaches
  the container's duration (`cachedFrontierSeconds`), measured on the last timeline; with a break it falls short of the
  playlist's total, so the seek reads again. Safe (a slow seek), and only after the end of the input.

## Revisit only if

- **The picture's stop on an audio track switch is noticed.** A switch is an exact seek to the current frame, so the
  picture stands while it lands (barely visible). A track from an added file has a demuxer of its own
  (`PlaybackInputs`): switching to or from it needs no seek of the picture, only the audio input positioned at the
  picture and an audio join. A track of the media itself needs the seek unless the demuxer kept every audio stream's
  packets (`applyStreamSelection` reads only the selected one).
- **A second engine in one process** (e.g. a preview player): make `PlayerPerformanceMonitor` per engine instead of
  `.shared`.
- **A second view reading `currentMetrics` live**: `PlayerEngine.isCollectingMetrics` is one `Bool` set from
  `ContentView` (its `didSet` starts and stops `metricsTimer`); the first reader to turn it off would stop it for the
  other, so it would need to count its readers.

## Flaky tests to watch

- **`BackwardFrameSteppingTests`** failed once locally with `engine.frameStep.cache.count → 0` after a paused
  exact seek. Suspected: the pause did not hold (the seek ran as a resuming seek, which does not seed the cache) or
  feeding restarted after it (`startFeeding()` clears the cache). The failure message reports cache size, play
  state and current frame to tell these apart.
- **`ExternalAudioTests` "A dub next to the media is a track of it…"** failed once in a full local run (2026-11-01):
  the dub's first audio fed at 1.04 s against `fed < 1`; it passes alone. The dub is joined to the picture's clock
  (`AudioJoin`), which cuts the audio to where the clock is plus the output latency, so under load the first buffer
  moves on with the clock. If it recurs, judge it against the clock at the selection, not a fixed second.
- **`FormatDescriptionCacheTests`** failed twice on CI with VideoToolbox returning 1–3 frames of 30 (always 30
  locally). The failure message now reports fed samples, session creation status, decode error statuses and the
  last callback status.

## Live streams: a window of a few segments, and an outage that stands the picture

**Not checked on a real stream (2026-11-04)**:

- A window shorter than about 10 s (three segments of 2 s) cannot be seeked in without the picture falling out of it
  again: the start moves on while the seek prerolls and lands a keyframe before its target, and
  `PlayerEngine.trackLiveWindow` brings the picture back at most every 15 s (`LiveStream.windowRecoveryInterval`), so it
  jerks back every 15 s. Such windows are rare (YouTube's is 15 minutes to an hour); a window that short is a stream to
  watch at its edge.
- While a live stream's playlist fails to load (a server error for a minute), the demuxer stops reading, the picture
  stands, the clock goes on and the badge says LIVE: `trackLiveWindow` seeks to the place to read again, ever less often
  (5 s, 10 s, 20 s, then 30 s apart, for as long as it lasts), and the stream plays again when the server does, but there
  is no buffering shown meanwhile, nor an error after a while. The clock is not held: `holdForBuffering` ends at once
  for an input that has ended (`isReadyToResumeAfterBuffering`), and the tick that drives recovery does not fire with the
  clock held.
- A live stream's variants numbered from other bases, on a playlist that grows from the stream's beginning and has not
  slid: the first switch to the other numbering moves the start of the window by all the time since the stream opened
  (`first_timestamp_updated` is set when `first_timestamp` is, and only a slide moves it), up to an hour. Needs both a
  growing playlist and variants that do not share a base; not seen.
