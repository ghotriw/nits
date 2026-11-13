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

- **Xcode previews need the `NitsUIPreviews` product.** The preview host does not find the symbols of a
  `systemLibrary` + `pkgConfig` target (`CFFmpeg`, `CLibass`): with the `NitsUI` scheme, or an app target linking the
  package (tried as a separate `Showcase` app, with explicit `-l` flags too), it fails with "Runtime linking failure,
  symbols not found". Only a dynamic library product (`type: .dynamic`) loads, with its FFmpeg and libass. It holds
  `NitsCore` a second time, so it is for previews, never for a host that also uses `NitsKit`; `bundle_app.sh` builds
  `--product Nits` and skips it. The way out is FFmpeg and libass as `binaryTarget` XCFrameworks, which the bundle's
  `scripts/setup_dependencies.sh` build could produce (not tried: previews may stop on something else). Splitting the
  views that take no engine into a target without `NitsCore` covers few (23 of 62 files of `NitsUI` don't import it).
- **A launch flag over a setting shows the saved value in Settings.** With `--no-osd`, the OSD switch reads "on"; the
  flag holds until that setting is changed (`LaunchArguments.dropOverrides`), so turning it on takes off-then-on.
- **Subtitles dropped with a playlist file are not attached.** `MediaOpenRequest.open` attaches them only to the path
  it loaded; a `.m3u` hands on to its first item, so `engine.currentPath` differs and they are only logged.
- **Closed captions in the pictures: a second caption track is not decoded while playing, and the decoder keeps the first
  variant's stream.** The captions are decoded as a picture is handed out of the queue (`MediaDemuxer.takeQueuedVideo`),
  and only into the main subtitle tracker (as when they were decoded at the read): a second CC track in the pictures
  (`secondarySubtitleTracker`) gets none. `ClosedCaptionDecoder` takes its codec and the size of the NAL length prefix
  from the stream it was made on; after an HLS variant switch the stream read is another one, which matters only for
  fMP4 variants with different length sizes (MPEG-TS is Annex B throughout).
- **An exact seek into audio past the video's end lands on the last frame.** With audio longer than video (video to
  50 s, audio to 60 s), a seek to 54 s lands on the last frame's 49.96 s: the position is the picture's, while audio
  starts at 54 s, so playback resumes with ~4 s of silence, and the next arrow press steps from 49.96 s again, never
  into the audio-only part. The position after such a seek should be its target.
- **The packet cache serves files, single-variant streams and ladders within one variant's stretch; not live streams.**
  Seeks back (and forward into what was read) skip the input (`seekWithinCache`). A ladder's seek that would cross a
  variant splice is a slow one (`format.variantGeneration` of the landing keyframe against the cursor's), so after an
  adaptive switch a seek back past it reads the input again; a journal of variant changes would serve those too.
  Measured on Apple's `bipbop_adv_example_hevc` (54 variants, one variant played, 2026-11-06): exact seek back 10 s
  1.1–1.5 s (RTT 25 ms) / 4.4 s (RTT 175 ms) before, 7–10 ms after; keyframe seek back 0.6 s / 3.2 s before, 2 ms after;
  no bytes. Adaptive playback in real time with a seek back every 10-30 s (probe `LadderABRSeekMeasurement`, 2026-11-07):
  Wi-Fi alone, no switch, 60 of 60 served from the cache; with NLC "DSL" (2 Mbit/s) the stream mostly stalled (the
  start was the top variant, ~10 Mbit/s, before the slow-link start of 2026-11-07; one run lost a segment, "failed too many times") and the few switches came
  when the cursor was past them: 7 of 8 and 3 of 3 served. One seek of 8, at the up-switch the line's release caused
  (target before the splice at 68 s, cursor after it), was slow (447 ms, 1.3 MB); its reason was not recorded (it did not
  repeat), the splice rule explains it. How often seeks cross a splice on a real stream is therefore unmeasured; a
  journal of variant changes waits for that. Not done: history behind the splice stays until the size limit evicts it (up to the 64 MB); the engine's
  ABR sees the read-ahead as the cache holds it (frontier minus the cursor, larger after a seek back: a false step up
  is possible; not measured); live. mpv caches both (it picks one HLS variant at open), and keeps several
  cached ranges where we keep one. Live needs to agree with `LiveStream.clamp` and `trackLiveWindow` (a seek back would
  no longer depend on the playlist's window).
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
  For HLS the client's offsets per discontinuity sequence ("Timeline and discontinuities" in `docs/HLS.md`) remove the
  break, and with it this; it stays for what they do not reach (an MPEG-TS file with a reset in it, a playlist with the
  discontinuity left out).
- **A stream with breaks gets no cache after the end of its input.** The end is trusted only when what was read reaches
  the container's duration (`cachedFrontierSeconds`), measured on the last timeline; with a break it falls short of the
  playlist's total, so the seek reads again. Safe (a slow seek), and only after the end of the input.
- **HLS and adaptive bitrate: see "State and known limitations" in `docs/HLS.md`.** The client's and adaptive bitrate's
  limitations (the start on a middle link, the estimate after a slow segment, a rung at the edge flapping, what breaks
  leave, subtitle renditions, advertisements on streams of their own, variant switches at the edges, AES-128) are kept
  there, with the open work in order.
- **The Metal shader's colour is set once per load.** `ToneMapController.mediaDidLoad` sets the matrix, primaries,
  transfer, bit depth and range (`ShaderColorimetry`) and the static peak; an HLS variant switch rereads the stream's
  colour (`configureVideoStream`) but not into the uniforms, so a ladder mixing `VIDEO-RANGE` SDR and PQ, or
  primaries, is drawn with the first variant's. The static peak has the same lifetime: `hasStaticPeak` is never reset,
  so a later variant's mastering display does not replace an earlier one's peak.
- **Metal colour approximations.** DCI-P3 (SMPTE 431) is converted with P3-D65's white, without adapting from the DCI
  white. ICtCp and IPT outside Dolby Vision Profile 5 are decoded as BT.2020 Y'CbCr. `FrameLuminanceMeter` measures
  max(R, G, B) in the stream's primaries, while the shader maps it in BT.2020: for PQ / HLG with BT.709 primaries the
  measured peak is at or above the shader's (converting into BT.2020 does not raise max(RGB)), so the curve is at
  most a little more cautious, never clipped.

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
- **`PlaybackStressTests` "Holding backward seek key produces monotonic non-increasing time values..."** failed once
  in three runs, then none in ten (2026-11-06), and once in ten on the same build without the HLS timeline patch:
  `Expectation failed: curr <= prev + 0.05` (`PlaybackStressTests.swift:395`), a time that stepped forward by more than
  50 ms in a backward series. Not looked into; a local file, so no HLS in it. Fell again in a full run of 343 s (2026-11-06,
  after the origin change, which does not touch a Matroska/MP4 file): at 25.0 → 25.050201 s, the sixth press of ~15
  (the series goes 45, 43, 40, 35, 30, 25, 20 … 0), 0.2 ms over the allowance; the time then rose in microsecond steps to
  25.066596 (the PTS of the picture that landed), and the next press took it to 20.0. So the clock reads a little ahead
  of the seek target in the middle of a series, between two presses (30–70 ms apart), not at its end. 3 of 3 alone it
  passes (1.6 s against 9.95 s in the run). Cause not shown.
- **`ExternalAudioTests` "A dub next to the media is a track of it…"** failed once in a full local run (2026-11-01):
  the dub's first audio fed at 1.04 s against `fed < 1`; it passes alone. The dub is joined to the picture's clock
  (`AudioJoin`), which cuts the audio to where the clock is plus the output latency, so under load the first buffer
  moves on with the clock. If it recurs, judge it against the clock at the selection, not a fixed second.
- **`FormatDescriptionCacheTests`** failed twice on CI with VideoToolbox returning 1–3 frames of 30 (always 30
  locally). The failure message now reports fed samples, session creation status, decode error statuses and the
  last callback status.
- **The HTTP, HLS and DASH suites together, with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`** (`--filter
  "HLSOverHTTPTests|AdaptiveBitrateTests|DASH|MediaDemuxer|InlineDASH|LiveStreamTests"`, a one-thread pool, 121 tests,
  about 165 s) fail on timing at the last commit (33d5fe9, 2026-11-07, with the bundled FFmpeg 1.5.0 build), without any of
  the live-history work: run 1, `AdaptiveBitrateTests.swift:117` (`consumer.stalled - stalledSlow < 0.5`) and
  `DASHLadderTests.swift:289` (`consumer.stalled < 1.5`); run 2, `DASHLadderTests.swift:289` alone. With the live-history
  suites and their two loops (`seeksRepeatedlyWhileReading`, `cancelsAReadAtAnyMoment`, which hold a thread for 3 s and
  8 s) the failures were more, in two runs (2 and 4): `SegmentIndexTests.swift:334`, `DASHLadderTests.swift:289`, three
  tests of `HLSOverHTTPTests` (`engine.waitUntil` timeouts) and `AdaptiveBitrateTests.swift:146`. With the loops skipped
  (`notInStrictPool`, so in this mode they are) it was 2 and 1 again: `AdaptiveBitrateTests.swift:117` with
  `HLSOverHTTPTests.swift:312` (`waitForPlayback`, an engine playing an HLS URL: the one that also failed in the first
  run with the loops), then `DASHLadderTests.swift:289` alone. Each passes alone (`HLSOverHTTPTests` 18 of 18, twice, in
  the strict mode), and the run without the strict mode passes (134 and 140 tests). So the strict mode is at the edge of
  the pool by itself, and a suite that blocks its thread for seconds tips more tests over it. Not looked into: the stall
  measures of the two ladder tests are the ones to judge first; `HLSOverHTTPTests.swift:312` showed up in 2 of 6 runs with
  the live-history suites and in none of 2 without, too few to tell if they have a part in it. Two runs more with the head
  of the stream added (`LiveSegmentGate`, `YouTubeLive` suites; 4 and 2 failures): `DASHLadderTests.swift:289`,
  `HLSOverHTTPTests.swift:312` and `AdaptiveBitrateTests.swift:146` (twice); then one of the new engine tests, which
  asserted that a stream was not yet ended right after its load, that took 45 s there (fixed: a load in a one-thread pool
  can outlast any wait a test sets).

## Live streams: a window of a few segments, and an outage that stands the picture

**A live stream's history is capped at 1080p60 SDR H.264, as HLS is (2026-11-07).** The segments of the streams called 4K
or HDR hold more: 2160p in VP9 (WebM), and on one of seven, AV1 with HDR10 in MP4. Not taken: a WebM has no `moof` for
`FragmentStartTime` (its clusters' timecodes would be read instead), and AV1 at 4K60 is software decoding (dav1d) on a Mac
without a hardware decoder. To judge first: which formats the Mac decodes in hardware (`VideoDecoderFactory`), so that the
selector (`YTDLPResolver.liveHistorySelector`) asks for the best of those; HDR10 AV1 MP4 is the case that costs nothing in
the parser. The load times are logged by part now (`YouTubeLiveHistory.Timings` in the yt-dlp log, "Opened … in" in the
engine's), for the 43 s load seen once (the likeliest the search for the edge of the history, which takes 41 s on a
server that answers 404, 500 and 503 for seconds each: the line says "by looking for the edge of the history" if so).

**A premiere's history counts the countdown; the video after it does not (2026-11-09).** A premiere on the air plays
from its history as a live stream does (`source=yt_premiere_broadcast`, `YTDLPInfo.isBroadcastSegment`), and its
position is saved in the stream's time (`PlayerEngine.playbackProgress(at:)`: `timelineOrigin` plus the engine's),
which `PlaybackProgress` takes the recording that follows to count in too. For a premiere it does not: the broadcast's
time holds the countdown, the video has none. Seen once: a position saved during a premiere and restored after its end
(the page an ordinary video by then) landed about a minute further on, the premiere having had a countdown. Restoring
while it is on the air is right (both sides in the stream's time). The fix is at saving: the countdown's length taken
off a premiere's stream time (and added back when resuming on the air). Where to read that length from is not known:
needs the yt-dlp JSON of a premiere on the air (`release_timestamp` against the head's time is the first to look at).
Not checked, from the review of the same change:

- Chapters and SponsorBlock segments (`resolvedChapters`, `buttons` in `YTDLPInfo.resolvedMedia`) are in the video's
  time and are attached to the history's timeline as they are: with a countdown they would stand that much early. A live
  stream had none; a premiere has. The same length fixes both.
- A premiere that ends while its history is played behind the edge: the next renewal of the signature
  (`YTDLPResolver.liveSegmentURLs`, at the expiry margin or a 403) may find no broadcast formats on what is a video's
  page by then, throw, and the segments be refused: the picture stands, with no fallback to resolving it as a video.
  Whether the server keeps a premiere's segments after its end, as it does a live stream's, is the thing to see.
- The end of a premiere at the edge: the manifest goes on past the head for a day (`futureSegments`) though the end is
  known (`duration`), so `LiveSegmentGate` waits `segmentWaitLimit` (60 s) and then asks yt-dlp before `hasEnded` is set:
  a minute of buffering at the end, and no limit to it if yt-dlp still says `is_live` then.

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
