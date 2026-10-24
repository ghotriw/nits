# Nits Architecture

Background and rationale behind the rules in [`AGENTS.md`](../AGENTS.md). `AGENTS.md` holds the
short, enforceable invariants; this document explains how the pieces fit together and why.

## Mission

Reference-grade playback of HDR and Dolby Vision (Profile 8.1 / HDR10) video on macOS:

- **SDR displays** (external 4K/5K monitors, EDR == 1.0): a custom Metal tone-mapper (ITU-R
  BT.2390 EETF with its black level lift, 203-nit reference white, Display P3, FidelityFX CAS) instead of the
  washed-out / crushed look of default OS tone mapping.
- **XDR / EDR displays** (EDR > 1.01): decoded frames go straight to `AVSampleBufferDisplayLayer`
  to use the panel's full 1000–1600 nit peak.

## Layers

```
[Presentation UI (NitsUI)]            observes PlayerEngine via @Observable, dispatches actions
              ↓
[Windowing & integration (NitsKit)]   windows, menus, NowPlaying
              ↓
[Engine core (NitsCore)]              PlayerEngineProtocol + PlayerEngine (@Observable, @MainActor)
              ↓
[Pipelines]                           demuxer, decoders, FrameQueue, Metal renderer, synchronizer
```

- **NitsCore** — demuxing, decoding, master clock, Metal rendering, frame queues, EDR/screen
  handover, playback history. No SwiftUI. `PlayerEngine` is `@Observable` directly, so there is no
  intermediate view-model; views re-evaluate only on the properties they read. Exports the
  `NativeVideoHostView` canvas. Builds only for macOS today but is kept portable to iOS / tvOS
  (see "Platform layer").
- **NitsKit** — `@MainActor` window lifecycle (`PlayerWindowController`, `PlayerWindow`), menu
  commands (`PlayerCommands`), system media integration (`NowPlayingController`).
- **NitsUI** — declarative views (`ContentView`, `ControlsOverlay`, `TimelineSlider`,
  `SettingsView`, `PerformanceHUDView`, `SubtitleOverlayView`). Transient UI state (fullscreen
  transitions, auto-hide) lives in `PlayerUIState`.

### Platform layer

Almost all of NitsCore uses frameworks that exist on every Apple platform (AVFoundation, CoreMedia,
VideoToolbox, Metal, QuartzCore). What doesn't sits in `Sources/NitsCore/Platform/`: an interface per
concern there, and each platform's implementation in `Platform/<os>/` (only `macOS/` so far),
picked at compile time through a `Platform…` typealias or type of the same name on every platform.

| Concern | Interface | macOS |
|---|---|---|
| The view showing the video: display link, screen, layout, visibility | `VideoHost` protocol | `NativeVideoHostView` (`NSView`) |
| The main screen, before a view is attached | `PlatformScreen` enum, repeated per platform | `NSScreen.main` |
| Audio output changes and latency | `AudioOutputRoute` protocol | `CoreAudioOutputRoute` (CoreAudio HAL, renderer device UID) |
| Keeping the display awake | `DisplaySleepAssertion` protocol | `IOKitDisplaySleepAssertion` (IOPM assertion) |

The engine holds a `VideoHost` as an existential (an embedding host may bring its own view). It reaches
`AudioOutputRoute` and `DisplaySleepAssertion` only through their `Platform…` typealiases: those
protocols are the contract a port's type is checked against at compile time, not dispatch points.

The layer tree and its layout (`VideoLayers`: clip layer, crop and zoom, PiP geometry, the Metal
drawable) are platform-neutral; a host view owns one and supplies its scale, its y-axis direction and
pixel alignment. Policy stays in the engine, so a port adds implementations, not engine changes:
`DisplaySleepManager` decides when to keep the display awake and the assertion only holds it; the host
reports its screen's EDR headroom and calls `videoHostScreenDidChange()`, and the engine decides
whether the screen is HDR (`minimumHDRDisplayHeadroom`) and the display-link rate.
`./scripts/format.sh lint` fails on AppKit / UIKit / IOKit / CoreAudio HAL code, and on the
one-platform members of shared frameworks NitsCore has used, outside `Platform/<os>/`, since nothing
compiles NitsCore for another platform yet.

What a port needs beyond that: FFmpeg, dav1d and libass built as xcframeworks (the `systemLibrary`
targets are pkg-config only), `AVAudioSession` for the session and route, and on tvOS display
criteria for the TV's HDR mode and refresh rate.

### Embedding (WKWebView / headless hosts)

The engine is designed to be embedded in hosts with web-driven UIs (e.g. an Emby client):

- `NativeVideoHostView` is a bare video canvas; a transparent `WKWebView` can sit on top.
- Commands in / events out go through `PlayerEngineProtocol`
  (`Sources/NitsCore/Protocols/PlayerEngineProtocol.swift`); the event callbacks
  (`onTimeUpdate`, `onPlaybackStateChanged`, `onTracksChanged`, `onBufferingChanged`, `onSeekingChanged`) are shaped for JSON
  bridging to `window.webkit.messageHandlers`. The bridge itself belongs to the host: its message schema is the
  web client's, not Nits'. Nits keeps the protocol complete enough that a bridge needs no engine internals.
- `bufferedTime` is the furthest timestamp the demuxer has read (`MediaDemuxer.readAheadSeconds`, behind its own
  lock because the demuxer lock is held through blocking network reads): for a network source, up to the
  read-ahead limit (see "Network read-ahead"); for a local file, the few seconds the feeders asked for.
- The demuxer accepts HTTP/HTTPS/HLS URLs with custom headers (`X-Emby-Token`, `Authorization`,
  User-Agent, cookies) passed as FFmpeg `AVDictionary` options.

## Video pipeline

### Decode → queue → present

Packets from `MediaDemuxer` are decoded by a `VideoDecoderProtocol` implementation chosen by
`VideoDecoderFactory`: `VTVideoDecoder` (hardware; AV1/VP9 are probed first because virtualised
CI runners advertise VT support without the decoder block) or `FFmpegVideoDecoder` (software
fallback). Decoded `CVPixelBuffer`s land in `FrameQueue`, and a `CADisplayLink` tick picks the
frame matching `synchronizer.currentTime()` and presents it in one of two modes:

- **`.metalToneMap`** — `MetalVideoRenderer` draws into `CAMetalLayer` with the BT.2390 curve.
- **`.system`** — the buffer is wrapped in a `CMSampleBuffer` with
  `kCMSampleAttachmentKey_DisplayImmediately = true` and enqueued to `AVSampleBufferDisplayLayer`.

Default mode is `.auto`, re-evaluated on display changes via
`screen.maximumExtendedDynamicRangeColorComponentValue > 1.01`. Because frames are decoded
continuously regardless of mode, switching modes only toggles `isMetalLayerVisible` and flushes the
display layer — no stall.

### Why the display layer is isolated from the synchronizer

On Apple Silicon, a fullscreen `AVSampleBufferDisplayLayer` on an XDR panel is promoted to IOMFB
Direct Scanout. Two things deadlock `WindowServer` on a hardware fence (`IOFenceTransaction`),
freezing input across all windows for up to ~30 s:

1. **Compressed passthrough** — enqueuing raw HEVC/H.264 NALUs with movie PTS, then seeking
   backwards, sends older PTS values that break the fence.
2. **Synchronizer attachment** — if the layer is attached to `AVSampleBufferRenderSynchronizer`,
   `setRate(0.0)` on pause blocks the fence until the rate goes back to 1.

Hence: only decoded buffers reach the layer; the layer's `controlTimebase` is an independent
host-clock timebase (`CMTimebaseCreateWithSourceClock(..., CMClockGetHostTimeClock(), ...)`, rate
1.0, never paused); pausing simply stops enqueuing; the synchronizer drives audio only.

Apple deprecated `enqueue(_:)` / `flush()` on the renderer in favour of
`synchronizer.sampleBufferReceiver`, which would require the attachment above. `PlayerEngine`
therefore calls `enqueueSampleBuffer:` / `flush` through cached selectors, with the
`enqueueSampleBuffer:` IMP resolved once at init for the display-link hot path. This is purely
to avoid the deprecation warning — the runtime behaviour is identical to `enqueue(_:)`.

### Seeking

Seeks run on the serial `seekQueue` and carry a generation token (`currentSeekId`); stale seeks are
dropped, so rapid scrubbing never runs concurrent demuxer seeks. A seek clears `FrameQueue`,
flushes the decoder and the renderer, but keeps the `VTDecompressionSession` alive. Before any
session invalidate/reset, `VTVideoDecoder` waits for in-flight frames
(`VTDecompressionSessionWaitForAsynchronousFrames`) so output callbacks can't race the replacement.

On the demuxer side, an exact seek flags every sample before the target `DoNotDisplay` and keeps
doing so for a second past it: in decode order the first sample past the target is often a P-frame,
followed by B-frames that still precede it. The window is bounded so an MPEG-TS timestamp
discontinuity can't hide every following frame. Container quirks:

- **MPEG-TS / MPEG-PS** have no index, so `av_seek_frame` bisects on timestamps and lands mid-GOP.
  `syncToVideoKeyframe` skips ahead to the next video keyframe and, for exact seeks, backs off
  1, 2, 4… s until that keyframe precedes the target. Audio read on the way is queued, since the
  muxer may interleave it ahead of the video of the same time.
- **MPEG-TS / MPEG-PS** timestamps continue the source clock (a DVD starts near 0.5 s, a broadcast
  capture hours in). `MediaDemuxer.timelineOrigin(of:)` makes the first one zero: every packet is
  read through `readPacket` / `MediaDemuxer.rebase`, and seek targets get the offset added back.
  Thumbnails and embedded subtitle extraction apply the same origin.
  After probing parameter sets at open, these formats rewind to byte 0: a timestamp rewind can land past
  the first packet and lose the keyframe that starts the file.
- **AVI** stores decode order only, so I/P packets have no PTS. The sample's PTS falls back to its
  DTS (the engine needs one), but it carries `presentationTimeUnknownAttachmentKey`, and
  `FFmpegVideoDecoder` then leaves the packet PTS unset so FFmpeg reorders B-frames correctly.
  Packet metadata (duration, `DoNotDisplay`) reaches the frame through `AV_CODEC_FLAG_COPY_OPAQUE`
  rather than timestamp matching. Exact-seek preroll on such samples carries the target
  (`exactSeekTargetAttachmentKey`), and the decoder decides on the frame's real PTS.

### FrameQueue

A fixed-capacity, pre-allocated ring buffer of `DecodedFrame?`:

- Pop advances `head` in O(1) and immediately nils the vacated slot — each `CVPixelBuffer` pins an
  `IOSurface` from the decoder's pool, and holding it for a full rotation starves
  `VTDecompressionSession`.
- Frames with non-decreasing PTS append at `tail` in O(1); out-of-order B-frames are placed by
  binary search, shifting only the few affected slots.
- `lastRenderedBuffer` keeps the frame on screen so mode switches and scrubbing while paused can
  re-render it (`renderCurrentFrame()`).

### Network read-ahead

Read on demand, the demuxer reads only when a feeder asks, and the feeders stop asking about a second and a half
ahead (a full `FrameQueue`, the audio renderer's second). Over a network that is all the margin playback has, and
FFmpeg's HLS demuxer, which downloads segments inside `av_read_frame`, can't be measured for throughput while
reads wait on the feeders. So a network source is read ahead, as mpv's demuxer cache does
(`MediaDemuxer+ReadAhead.swift`): a thread of its own reads packets into the demuxer's queues up to
`ReadAheadLimits` (30 s of media ahead of the packets taken, 192 MB) and waits there.

- **Locks.** The input (`AVFormatContext`) stays behind `lock`, held through blocking reads; the queues and what
  goes with them (`targetPts`, `targetAudioPts`, EOF), and the track selection, are behind `queueLock`, held
  briefly. Whatever holds `queueLock` releases it for a blocking FFmpeg call: the read-ahead thread for
  `av_read_frame`, a seek for its reads and `av_seek_frame` (the feeders are stopped then, and `lock` keeps the
  thread out). What a read does with a packet comes after the call returns, under `queueLock`. So consumers, which
  take packets under `queueLock` alone, and track selection on the main thread never wait for the network. The rest
  takes `lock` through `lockIO()`, and the thread steps aside between packets for it (the unfair lock would
  otherwise let it take the lock straight back and keep a seek waiting).
- **Consumers.** The feeders take what is queued and get nil at once when nothing is (`isVideoEOF` / `isAudioEOF`
  tell each stream's end, after the thread stopped at the end of the input, as reading on demand does; a stream
  ends when its own queue is empty, so the video decoder is drained while longer audio still plays, and an input
  with no audio track selected has ended its audio); the synchronous pumps on `seekQueue` (seek previews, frame steps)
  wait for the thread (`nextVideoSample(waitingForReadAhead:)`).
- **Seeks** clear the queues as before, and the thread reads on from where the seek left the input.
- **Limit.** The seconds ahead are counted from the video taken (the audio's, without video). A stream with nothing
  queued is read for up to the byte limit, as in mpv: video that ends (or starts) further than the limit from its
  audio would otherwise stop the thread for good, with no end of input.
- **Sources.** A URL, and a saved HLS manifest of network media (`MediaURL.isNetworkSource`). FFmpeg opens a
  manifest's segments with the I/O options of the manifest's own input, so that one is opened with the network
  options too, and with HTTP added to the protocol whitelist a file allows (file, crypto, data): by the demuxer and
  by the subtitle window reader alike (`MediaURL.applySourceOptions`).
- **HLS opening.** FFmpeg's HLS demuxer, before it plays anything, reads every playlist a master lists and probes
  every video and audio one (its init section and the segment it starts from), each a request after another, the
  probes on connections of their own. Apple's AV1 example (2026-10-22, Wi-Fi, 34 ms round trip) lists 36 playlists
  and probes 23: it opened in 54.5 s on a cold CDN cache (answers after 0.5–0.8 s; 20 s of playlists, 33 s of
  probes) and in 12 s on a warm one. FFmpeg has no option to skip it, so `HLSPlaylistPrefetcher` downloads it all
  side by side while FFmpeg opens: the master (again: FFmpeg reads its own), then every playlist it lists at once
  (up to 16 connections: the CDN speaks HTTP/1.1 only), then of each video and audio playlist the first 128 KB of
  its init section and of the segment the probe starts from (the first; the third from the end of a live one), as
  ranges: from their offset for byte ranges (`EXT-X-BYTERANGE`, a variant in one file, placed as FFmpeg places
  them). `FFmpegIOByteCounter`'s `io_open` serves FFmpeg those from memory (`PrefetchedInput`) when it asks for the
  same offset, and past what was downloaded reads on through FFmpeg's own `io_open` with the `offset` moved on (its
  `end_offset` kept: FFmpeg asks for a run of byte ranges at once). The same stream then opened in 3.9 s and 0.7 s,
  with a single request of FFmpeg's (the master); Dolby Vision / Atmos, 100 programs, in 8.3 s and 1.2 s instead
  of 142. Bipbop advanced (byte ranges, 54 programs) in 5–6 s instead of 47: FFmpeg reads 0.2–3 MB of each video
  variant's first fragment (8 s each), and goes on to the network for 13 of them. At 184 ms of round trip
  (Network Link Conditioner) the AV1 example opened in 7.2 s and 3.5 s instead of 51–80, Dolby Vision / Atmos in
  12.7 s and 5.7 s. Keep-alive is off while opening:
  FFmpeg would send the playlists over the master's connection without `io_open`. What isn't downloaded FFmpeg
  opens as before: a playlist served from elsewhere (a redirect: its segments resolve against that place, which
  FFmpeg reading from memory wouldn't know), a failed download, encrypted segments, a probe starting elsewhere
  (`EXT-X-START`), a URI resolved otherwise than by FFmpeg. The downloads carry the source's headers; the user
  agent is URLSession's when the source sets none, and cookies a master's answer sets stay apart from FFmpeg's.
  The playlists of variants that can't switch with the one played on opening (the highest `BANDWIDTH`: its video
  codec, `SUPPLEMENTAL-CODECS`, `VIDEO-RANGE` and rendition groups), and of renditions only they refer to, are
  refused to FFmpeg (`playlistsOutsideLadder`): it marks them broken and never reads them, nor probes them. Not
  read empty: FFmpeg counts a playlist without streams as needed and reads it, its demuxer never opened (a crash).
  Not cut from a master served from memory either: FFmpeg takes the I/O options of every later request (headers,
  user agent, cookies, timeout) from the master's input. The first variant listed stays: FFmpeg takes the duration
  from its playlist. Dolby Vision / Atmos opened so in 2.7 s and 0.6 s, bipbop advanced in 3.5 s and 1.8 s.
- **HLS variants.** A switch splices at the read position, up to the read-ahead limit ahead of playback, so a
  manual switch seeks to the current frame instead (as an audio track switch does). The engine shows a splice when
  playback reaches it (`variantWillPlay`); the changes reach the main thread in order (`DispatchQueue.main`, not a
  task each). The splice rewrites the stream description (`timebase`, `formatDescription`, the audio track's streams,
  …) on the reading thread, under `queueLock`: the engine reads it before starting the read-ahead at the end of a
  load, and through `readingDescription` after that. An audio track selected during a switch is spliced to in place of
  the one selected when it began.
- **Adaptive bitrate** (`AdaptiveBitrateLogic`, `MediaDemuxer+AdaptiveBitrate.swift`) chooses the variant while
  reading ahead, until one is chosen by hand.
  - *Throughput* is measured by the read-ahead thread: a read waits on the network, so bytes over the time spent
    reading is the link's rate. The bytes are what came over the network (`FFmpegIOByteCounter`: FFmpeg's own
    `io_open` / `io_close2`, summing each input's `bytes_read`), not packet sizes: container overhead and what FFmpeg
    reads and drops (a variant switched to is caught up from the start of a segment) are a third and more. Reads
    served from what the socket buffered while the thread idled at its limit don't count until one waits again. HLS
    downloads one segment at a time (`http_multiple` off): FFmpeg's prefetch of the next would share the link with
    the one read and halve what is measured. A sample ends after 0.5 s of transfer, or 2 s of media read in at least
    0.1 s of it, and weighs the media it read, or its transfer's seconds when slower than real time. Weighed by the
    transfer, and taken per half a second of it, a fast link's samples came dozens of segments apart and weighed
    little for their media: a low variant's small segments left the estimate unset for minutes, and one measured low
    (a slow start) held long after the network got faster.
  - *Latency* of a request on a new connection is measured apart. An HTTP input opens once its response's headers
    are in, so the time inside `io_open` (connection, TLS, the server's answer) is left out of the throughput:
    counted, it capped the estimate at a segment's size over it. On Apple's AV1 example (2026-10-22, every segment
    on a connection of its own) the 480p variant's 121 KB segments measured
    3.4 Mbit/s of a 170 Mbit/s link, and a start on a cold CDN cache (answers after 0.5–1 s) 225 kbit/s. It counts
    instead as seconds per second of media read (`latencyShare`), the same for every variant: a variant fits when a
    second of it reads, transfer and latency, within `safety` of a second (dash.js weighs latency so too; FFmpeg reads
    the playlists one request after another, so the latency adds up). A server slower to answer than its segments
    last brings the variant down however fast the link, to the lowest when the latency alone takes `safety` of the
    media, with no estimate yet too. A request counts once answered, ahead of its media: the share counts from 6 s of
    media read on, which the few requests answered ahead (a segment per playlist read, an init section) overstate
    by their latency over the media read, less and less. Nothing ties an opening to its playlist: FFmpeg's URLs
    don't say which (variants and renditions often share a directory, signed URLs carry `/` in the query). Openings
    while a variant switch catches the new variant up count neither: a cost of the switch, not of the variant, read
    without media.
  - *Connections* are kept open (FFmpeg's `http_persistent`), but for live streams. Kept alive, FFmpeg sends the
    requests over the open connection without `io_open`: their latency, a round trip and the server's answer, counts
    in the transfer, as in VLC and GStreamer (`.ref`), and only a new connection's is measured apart. A connection
    per segment costs every request, video's and audio's, a handshake (TCP, TLS: about three round trips) and TCP's
    slow start. Measured on Apple's AV1 example (2026-10-22, Wi-Fi, three runs each):
    - 34 ms round trip: kept, 20 s read ahead in 2.8–4.7 s, 3840 wide throughout, throughput 132–203 Mbit/s; a
      connection per segment, 5.6–15.4 s, down to 1920 for 13 s in two runs of three on its 81–170 ms/s of latency.
    - 184 ms (Network Link Conditioner): kept, 20 s ahead in 9.9–17.8 s, down to 864–1280 wide and back up to
      1920–3840, no stall, 16–23 Mbit/s; a connection per segment, 459–552 ms/s of latency, never 20 s ahead, down
      to 480–1280 for good, 4–8 s of stalls.

    A live stream opens a connection per segment all the same (`http_persistent` off once open; opening keeps it
    for probing every playlist): its read-ahead thread tells the wait at the edge for the next segment by
    `io_open` (`noteRead`), which a kept connection hides. TCP's slow start makes small segments measure low (a few
    round trips for 100 KB), and the first bytes of a body, in with the headers, count at no time and offset some
    of it.
  - *Decisions*: an estimate (the lower of two exponential averages, as dash.js and GStreamer) that doesn't carry
    the current variant brings it down while the read-ahead is under two thirds of its limit; a full read-ahead
    steps up to what a recent estimate carries, or probes one step up without one (at its limit the thread measures
    nothing, however fast the network). A probe that comes down soon doubles the wait before the next.
  - FFmpeg hands out the packet a discarded variant held when it is enabled again, from back then: a splice comes
    only at a keyframe at or after the old variant's latest decode time.
- **Renditions** (`EXT-X-MEDIA` audio and subtitles) are playlists of their own, downloaded while one of their
  streams isn't discarded. Only the video, audio track and subtitle track selected are read (`applyStreamSelection`):
  on opening, at a variant switch (the new variant's video and the rendition of the selected audio track, not all its
  streams), and after a track selection, which the main thread only flags (`streamSelectionChanged`) for the reading
  thread to apply under `lock` at its next read or seek, as FFmpeg reads the discard flags inside `av_read_frame`. An
  audio track switch seeks anyway; a subtitle rendition selected on a network source seeks to the current frame too,
  or FFmpeg would start it at the read position.
- Tests play local files only: `NITS_READ_AHEAD_LOCAL=1` reads them ahead too, to run the suites that way.

### Backpressure

- **Video** — the feeding task stops decoding once `FrameQueue` holds 40 frames and resumes below
  25, polling with `Task.sleep` (no thread blocking).
- **Audio** — buffers go through `AudioRendererSink.enqueue`, which suspends under renderer
  backpressure: on macOS 27+ via `AVSampleBufferAudioRenderer.Receiver.enqueue`, on macOS 15–26 by
  waiting on `isReadyForMoreMediaData` with `Task.sleep` before a direct `enqueue(_:)`. Both throw
  `CancellationError` if cancelled before the buffer is accepted, so pause keeps it pending.

### Stalls and buffering

**Stalled decoders.** A hardware decoder runs in `VTDecoderXPCService`, and `VTDecompressionSessionDecodeFrame`
waits for it synchronously; when the service stops answering, the call never returns, and nothing can unblock
it: flushing or invalidating the session starts by waiting for the same service. So the engine never calls a
decoder where a stall would hang it. The video feeder and the work on the serial `seekQueue` (seek previews,
frame-step pumps, the flush after a load) go through `StallGuardedVideoDecoder`, which runs each blocking call on
its own queue and waits at most `decoderStallTimeout` (3 s; calls normally return in milliseconds). On an overrun
the decoder is silenced and later calls return at once, so the caller finishes without it (a seek lands without a
preview frame) and `recoverFromStalledDecoder` installs a replacement, a new session first and software
decoding after a second stall, then seeks to the target of a seek in flight, else to the last presented frame.
The stalled call keeps its GCD thread for good; the feeder awaits its calls, so no cooperative-pool thread is
lost. Without the guard on `seekQueue`, one stalled seek would hold every later seek, step and load behind it.

**Buffering.** The synchronizer starts with `delaysRateChangeUntilHasSufficientMediaData = false` and, once
running, never waits for data. When media runs out mid-playback (a slow network or disk; a video decoder too slow
for realtime, which also starves audio because the demuxer reads no audio past a full video packet queue), the
clock would run on through silence, and everything arriving later would be late. `PlayerEngine+Buffering` stops
the clock instead, sets `isBuffering` (`isPlaying` stays set) and restarts it where it stopped, like mpv's cache
pause:
- **Units.** Audio in seconds of playback (media seconds ÷ rate): the renderer queues about a second of playback
  at any rate (0.9–1.4 s of media at 1x, 2.8–3.9 s at 4x). Video in frames: while frames arrive the feeder keeps
  25–40 queued whatever the frame rate, which at 60 or 120 fps is well under half a second, so a threshold in
  seconds would read a full queue as running low.
- **Trigger** (checked by the 20 Hz periodic time observer): under 0.15 s of audio queued in the renderer
  (`BufferTrackingAudioSink` tracks the end of the latest enqueued buffer) *and* under 20 frames queued. Audio
  alone is not a shortage: a track ending before the video must not stop playback, and then the frame queue stays
  in its range. A low frame queue alone isn't either (a decoder briefly behind), and waiting for an empty one would
  let the clock run into silence for however much more video than audio was queued. Without audio: frame queue
  empty with the clock two frames past the last frame.
- **Resume**: 30 frames *and* 0.5 s of audio queued, or demuxer EOF, starting the clock as a resume from pause
  does. Both are above the trigger, so a resume does not run straight back into a hold. Audio that has not changed
  for 0.5 s counts as all there is (the held renderer is full, or the demuxer reads no audio past a full video
  packet queue): playback then resumes with it if it is above the trigger or video is ready, and stays held if
  neither, as nothing is arriving.
- Every path that stops or re-anchors the clock goes through `cancelPreroll()`, which also ends buffering;
  buffering never starts while seeking, prerolling or after demuxer EOF.

**Audio renderer behind the clock.** Starting playback on a Bluetooth route, the device can stop its IO for most
of a second while the audio queue starts (seen with spatial audio being switched on). The renderer then anchors
its timebase back in time: the clock leaps ahead (a burst of dropped frames), and the audio queue stays that far
(~0.6 s) behind it for the rest of playback. The renderer's backpressure releases audio at the queue's pace, so
every buffer arrives late and is discarded, and the queue resyncs several times a second: choppy audio that never
recovers by itself. A pause and resume fixes it, and `PlayerEngine+AudioLag` does the same on its own: when the
feeder has waited for 0.5 s for the renderer to take audio that is due (`BufferTrackingAudioSink.pendingStart`
under 0.15 s of playback ahead of the clock), it re-anchors the clock, at most once every 5 s. A healthy renderer
takes audio about a second ahead, and a real shortage leaves the feeder waiting on the demuxer, not the renderer.

### Display pacing

`CADisplayLink` from `view.displayLink(target:selector:)` / `screen.displayLink(...)`. Unlike
`CVDisplayLink`, it follows the window across screens, tracks ProMotion/VRR, and needs no
`Unmanaged` C callbacks. Lifecycle: `isPaused` / `invalidate()`.

The links are created and configured on the main thread but fire on the run loop of a dedicated thread
(`DisplayLinkThread`). On the main run loop every UI stall became a skipped tick and a dropped frame:
SwiftUI redrawing the window waits synchronously for WindowServer (a repeating symbol animation alone
did that every frame), and resizes, panels and sheets all run there. The tick touches only lock-guarded
engine state, the Metal renderer (own lock) and the display layer, whose enqueues and flushes share
`displayLayerLock` with the main-thread previews, seeks and loads; UI state goes to the main actor.

Every tick presents a frame (`DisplayImmediately` / Metal draw), so the tick rate is the presentation
cadence. The link only delivers rates that divide the screen's maximum refresh (120 Hz ProMotion:
120/60/40/30/24), so `preferredDisplayLinkRate` picks the lowest such rate ≥ 48 Hz that is a whole multiple
of the content fps (29.97 → 60, 24 on 144 Hz → 48) and otherwise the screen maximum, whose finer ticks keep
the unavoidable cadence error smallest (25 / 50 fps on 120 Hz; 23.976 counts as 24 within a 1% tolerance).
A fixed 60 Hz request would give 24p film 3:2 pulldown judder; a fixed 120 Hz one wastes ProMotion power on 30/60 fps content.

Frames are chosen for the clock at the vsync they will appear on — `synchronizer.currentTime()` projected to
`link.targetTimestamp` — because callback latency jitters by milliseconds; sampling the clock at callback
time skips frames whenever content fps is close to the link rate.

When no rate is a whole multiple of the content (25p on a 60 Hz-only external monitor: 2.4 ticks per frame),
frames are held 2 and 3 ticks in a fixed pattern; that judder is inherent to the screen. Their boundaries fall
on a lattice of phases against vsync (tick / 5 apart for 2.4), and as the audio clock drifts against the display a
lattice point passes over a vsync every few tens of seconds. The projected clock still wobbles by about a
millisecond from tick to tick, so the frame at that point used to flip between two vsyncs for seconds at a time
(shown a tick late, the next one held a single tick). `DisplayClockSmoother` stands between the projection and
`FrameQueue.popFrame`:
- **Smoothing.** `content time − host time × rate` is low-pass filtered (time constant 0.5 s). A step beyond 8 ms
  (seek, clock restart, rate change, a gap in ticks) restarts the filter from the raw value and is logged. A clock
  that has not moved since the previous tick — paused, or the synchronizer waiting for audio after a start while
  its rate is already 1 — is treated as stopped: returned raw, never projected or smoothed into motion.
- **Phase lock.** A bias of at most half a lattice step keeps the lattice centred between vsyncs. Each pick
  (slack past its threshold, modulo the step) nudges it towards the centre, so it follows the drift; past half a
  step it moves by a whole step, shifting one frame boundary across a vsync once. The bias is the only A/V offset
  added: ±1.7 ms for 25p on 60 Hz, ±8.3 ms at most. Rates without a lattice of ≤ 12 points are not locked.

On an LG UltraFine at 60 Hz with 25p this took the frames sitting on a vsync from about one in five to none: with
audio on the MacBook speakers, 90 s without a single one and without a clock step. With **Bluetooth audio**
(AirPods) the synchronizer follows the headphones' clock, which steps by ±10–13 ms, usually in pairs, in the first
tens of seconds while the link settles; each step makes the lock re-centre, and frames on a vsync flip between ticks
for a few seconds. The cadence diagnostics that measure all this are described in `docs/LOGGING.md`.

The built-in ProMotion panel does not keep an even vsync grid while playing: successive link targets sit 6.25, 8.33
or 10.42 ms apart (steps of 1/480 s), averaging ~118.5 Hz instead of 120, and 15–25 of every 600 ticks are skipped.
That irregularity, not clock jitter, decides where frame boundaries land there, so the phase lock neither helps nor
hurts (measured with and without it); at an 8.3 ms tick the resulting one-tick errors are hard to see.

### Picture in Picture

`NitsKit/PictureInPictureController` drives the public `AVPictureInPictureController` with a
`ContentSource(sampleBufferDisplayLayer:)` over `engine.displayLayer`; the engine only exposes
`isPictureInPictureActive` and `pictureInPictureLayerGeometry`, so embedding hosts can bring their
own PiP. The controller is public for hosts with their own window: it follows the engine through
observation (the engine's callbacks have one slot each, which the host uses), so a host only
toggles it and moves its window aside and back (`onActiveChanged`, `onRestoreUserInterface`). The
window settings in `PlayerConfiguration` are applied by `PlayerWindowController`. The private `PIP.framework` (IINA, VLC) was rejected: it would show any view (Metal
included), but a broken private API means no PiP at all, while AVKit's bugs below are cosmetic.

- **Render mode and pacing.** PiP only sees the display layer, so `.metalToneMap` falls back to
  `.system` while it is active. The window is usually ordered out, and a view-based
  `CADisplayLink` stops with it, so the link follows the screen until PiP ends.
- **Clock.** The layer's timebase is the host clock at rate 1.0 and is never paused, and PiP reads
  the position from it. `PictureInPicturePlaybackSnapshot` maps playback onto it: the time range
  starts at `hostNow - position` and, at other rates, is divided by the rate (wall-clock seconds,
  so progress and remaining time stay right; elapsed labels show wall-clock time). PiP is told to
  re-read its state on pause/resume, rate or duration changes and position jumps.
- **AVKit layout bugs (macOS only; developer forums thread 821582).** PiP shows the display layer
  1:1 inside an in-process panel and never scales it; its own view keeps the panel's start size,
  and an opaque, empty `…CALayerHostView` covers the video once the panel grows past a fixed
  offset. The display layer therefore takes the panel's content size
  (`.pipWindow(size)`), and the AVKit pieces are repaired only when found broken, so a fixed AVKit
  makes this a no-op. AVKit's "playing in picture in picture" indicator is a sublayer of the
  display layer, sized to it; `NativeVideoHostView` stretches it over the whole view.
- **Hand-back.** AVKit animates the panel onto the display layer's frame, at the video's aspect
  ratio. Right before that the layer takes the video's aspect-fit rect (`.videoRect`), so the
  panel lands on the picture without a band (a full-view layer on a 16:10 fullscreen screen left
  one); a minimized window is first restored from the Dock. The layer fills the view again once
  PiP stops; the picture does not move.
- **Known limitation.** On the first PiP after launch AVKit creates the panel late and animates it
  by transform, so the first frames of that animation show the layer unscaled. Finding the panel
  earlier (polling the window list) was worse: resizing the layer mid-transform shows a double
  image.
- **Not supported on macOS:** `canStartPictureInPictureAutomaticallyFromInline` and the video-call
  controller. Automatic PiP is limited to an opt-in "enter PiP when minimizing"; switching apps
  never triggers it, since macOS windows stay visible.

### Video geometry (aspect ratio, crop, zoom)

`PlayerEngine.videoGeometry` (`VideoGeometrySettings`) holds the aspect override, crop, scaling mode,
zoom and pan. It is presentation only: nothing in decoding, `FrameQueue`, pacing or the clock reads
it. `VideoGeometry.layout` is the single place that turns it, the view size, the coded size and the
SAR into rects (`VideoLayout`): the whole frame's rect, the cropped picture's rect, its visible part
clipped to the view, and the normalized part of the frame shown there. The host view, the subtitle
overlay, the timeline preview and PiP's hand-back rect all take their geometry from it, so they
can't drift apart.

- **Display layer.** It sits in a clip layer (`VideoLayers`, inside `NativeVideoHostView`). With the default
  settings the layer covers the view with `.resizeAspect` and nothing clips, the layout before
  geometry existed. Otherwise the clip layer takes the visible rect with `masksToBounds` and the
  display layer the whole frame's rect with `.resize`. Crop, stretch and zoom are layer geometry,
  so the buffers and the selector-based enqueue path stay as they are.
- **Metal.** The drawable covers only the visible rect, so a zoomed picture never costs more than
  the view, and the vertex shader maps texture coordinates through `MetalVideoRenderer.sourceRect`
  (vertex buffer 0). The fragment shader and `ToneMapUniforms` don't change; CAS samples
  neighbouring texels as before.
- **PiP** mirrors the display layer itself, not its clipped superlayer, so while it is active the
  host view lays the layer out with the default settings and gives the window's geometry back when
  it ends.
- **Pan** is stored per axis in `-1...1` of how far the picture overhangs the view, not in points,
  so it can't move the picture off the view and survives a resize. While the picture overhangs,
  `NativeVideoHostView.mouseDownCanMoveWindow` is `false`, so a drag pans instead of moving the
  window.
- **Persistence.** Aspect override and crop describe the file and go to `PlaybackHistoryStore`
  (`PlaybackPreferences.noGeometryOverride` records "none", since `nil` keeps the saved value);
  scaling is a session choice with a default in Settings; zoom and pan reset on load.

### Subtitles

Subtitles never touch the video pipeline: they are drawn by `SubtitleOverlayView` above the video, and a host that
draws its own gets the same data from `onCuesChanged`. `SubtitleController` (`engine.subtitles`) owns all of it: the
tracks and selection, the delay, the style, every read and the libass renderer. The engine calls it on load
(`mediaDidLoad`), as time moves (`timeDidChange`: the time tick, a seek's preview and landing, a frame step) and when
media goes (`reset`, from `resetMediaState`); the controller reads the engine through `SubtitleHost`. For ASS, each cue's `rawPayload` is a `Dialogue:` line
in one field order (`AssScript.eventFormat`) whether the track is a stream or a file, and `assHeader` (the
script without its events, ending in that `Format:`) plus those lines make a script libass in the host draws as the
player does; `assFonts` are the media's attached fonts.

- **Three kinds of track** (`SubtitleTrack.format`), all held in a `SubtitleDocument` that
  `updateShown(at:)` looks up each time tick (20 Hz) with the subtitle delay applied:
  - `.text` (SRT, WebVTT, mov_text, plain text; MicroDVD, SubViewer and SAMI files through FFmpeg's decoders,
    `FFmpegTextSubtitles`): `SubtitleCue`s, drawn by SwiftUI in the user's subtitle style.
  - `.bitmap` (PGS, VobSub, DVB): `BitmapSubtitleDecoder` (`avcodec_decode_subtitle2`) makes `SubtitleImageCue`s that
    keep palette indices, not pixels; a set ends at its duration, or, as PGS gives none, at the set that clears or replaces it, however late (5 s for the last).
    The overlay fits the cue's canvas over the whole decoded frame (`imageFrames`), whole and with equal scale on both
    axes when its proportions differ from the frame's (a 16:9 PGS on a rip with the bars cut off). A crop or zoom in
    the player scales the regions with the picture; those left off the visible part are moved inside it, each half
    of the frame as a block so lines keep their spacing. libass frames (`placement == .visiblePicture`) cover the
    visible picture instead, as they are drawn for it.
  - `.ass`: the plain-text `cues` (hosts, VoiceOver, the "plain text" setting) plus an `AssScript` (stream header,
    events, attached fonts, or the whole file) for libass.
- **libass** (`AssSubtitleRenderer`, ISC) draws at the pixel size of the visible picture, which the view reports as
  `renderSize`; the controller renders off the main thread, one render at a time, the latest requested time
  last. Every libass call of every renderer runs on one serial queue (`AssSubtitleRenderer.queue`), and only there
  (`dispatchPrecondition`): callers await it through `perform`, never holding a thread of Swift's pool. Core Text asks
  `fontd` for fonts with a synchronous XPC call that has no timeout. While the controller's calls are under way
  (`libassCallsInFlight`), one running past `libassStallTimeout` (5 s) counts as stuck (`watchLibass`; another's long
  call, with none of the controller's waiting, is not its business): the media's ASS tracks show their text cues from
  then on, as anything later put on the queue would wait behind it; the next media tries libass again. Fonts are set
  once per renderer: `ass_set_fonts` drops every font found so far, and libass takes fonts added later at the next
  render. A renderer is released on the queue asynchronously, so the main thread never waits for
  it. Tests reach libass through `LibassRenderer`, which gives up after 20 s with an issue. The result is a
  premultiplied BGRA picture per group of images near each other (a sign at the top and the
  dialogue at the bottom are two, not one the size of the frame), shown through the same image path as bitmap cues,
  without the fade the text gets. The
  controller keeps `isDrawingAuthored` so the overlay doesn't draw the text cues again. Fonts come from Core
  Text (no Fontconfig), plus the attachments of the container. The pixel aspect passed is the one the video is shown
  with (its SAR, or what a forced aspect ratio makes of it; not a crop): script coordinates are in the video's own
  pixels, the frame in square ones. Renders follow the 20 Hz time tick, and while one changes the picture (an
  animation) the next comes a video frame later, from the synchronizer clock. `assStyleOverride` lays the user's
  subtitle style over dialogue through libass' selective override (lines without positioning; signs keep theirs). Core
  Text doesn't list the system font's rounded, serif and monospaced designs, so their files are added to libass
  (`StyleOverride.libassFont`, from the one list of designs `SubtitleSystemFont`; SF Pro itself is found as
  "System Font"). `scale` and `position` reach libass as its
  font scale (dialogue only, `ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE`) and line position; the overlay applies them to
  text (position) and picture subtitles (both) itself. The frame is the visible part of the picture
  (after crop and zoom), so a script's whole play resolution is stretched over what is visible: dialogue stays on
  screen, but typeset signs no longer line up with the picture once it is zoomed or cropped. That is deliberate, the
  same rule as for text (subtitles stay inside the visible picture); drawing on the whole picture and clipping, as mpv
  does, would need a frame as large as the zoomed picture.
- **Embedded tracks** come from the packets playback reads, for every source, as in mpv and VLC
  (`LiveSubtitleTracker.processPacket`, `liveSubtitleVersion`): never from a read of the whole file, which for Matroska
  means every byte of it (matroskadec ignores `AVDISCARD_ALL` and reads every block), minutes on a network volume. That
  misses what lies before where playback reads from: the cue on screen when a track is chosen or a seek lands, and,
  for a track chosen mid-play, everything playback read ahead before. A second demuxer reads that window
  (`MediaDemuxer.subtitleWindow`: from 10 s before the time up to where playback reads from, to the end if it read
  there already; `EmbeddedSubtitleReader.readSubtitles`), as mpv's refresh seek and Matroska subtitle preroll do,
  and the result joins the lists (`mergeLiveSubtitles`) unless they cover it already (spans read since the track was
  chosen, restarted at each seek and raised to where it landed, and windows merged). It is read when a track is
  chosen, a load with a start time or a seek has landed (once, not per scrub step), and the subtitle delay changes.
  A negative delay can show the track ahead of everything playback has read: the time tick then reads ahead, up to
  10 s past the track's time, again once half of that is used (`windowLookahead`); a failed read isn't retried per
  tick.
  PGS sets carry the stretch of reading they came from (`readSpan`, a new one per seek): a set only ends a set of the
  same stretch, as a seek may have skipped the packet that really ended it. A window joins the stretch being read;
  its sets merge before the ends playback read in it are applied again (`merge(window:span:replaying:)`), so a clear
  read by playback before the window arrived still ends its set. A picture stream that isn't cover art (or else
  sound) tells how far the read has come, by decode time, 0.5 s past the window's end. Window reads run at
  `.utility`, below playback's own reads of the same file, and a failed one is logged. A network source gets a window
  read only where the file's index lists the track's packets, up to `networkWindowByteLimit` from the first: a whole
  window reads every stream for seconds, against playback refilling after a seek. A read past the limit gives nothing,
  and the window stays unread.
  The packets of every subtitle stream are kept as playback reads them (`SubtitlePacketStash`, by stretch of reading;
  picture streams share 64 MB): a track chosen later decodes them in the background first (`mergeStashed`), network
  sources included, and the window is what they leave out (`subtitleWindow` starts past what is covered, and ends
  before what is covered up to its end). The file's own index (Matroska Cues, an MP4 sample table) tells where a
  track's packets are: read once per media by a demuxer that discards every stream (`EmbeddedSubtitleReader.readIndex`),
  as FFmpeg adds the blocks it reads, its probing's too, to the playback demuxer's. A window it lists none in is merged
  empty, unread, and a read starts at the first it lists. MPEG-TS and the generic seek index what their seeks read, so
  only Matroska and MP4 count. The merge of the stash is a task of its own, never cancelled, that window reads wait for.
- **Closed captions** (CEA-608): ATSC `cc_data` in H.264 / HEVC prefix SEI or MPEG-2 picture user data
  (`ClosedCaptions`) is no stream of the container, and as VideoToolbox decodes the pictures FFmpeg's decoder never
  sees it: the bytes are read from the video packets, up to the first slice (unit lengths from `avcC` / `hvcC`). The
  first pictures read while opening tell which fields carry captions; each becomes a `.text` track of the video stream
  (CC1, CC3 for field 2 with more than null padding; `closedCaptionField`, `captionsInVideo`: a stream number never
  selects them, and the video's packets don't go to the subtitle path). An MP4 `c608` track is a subtitle stream
  FFmpeg lists, decoded the same way. FFmpeg's `cc_dec` decodes them in its real-time mode, as mpv does
  (`ClosedCaptionDecoder`): every change of the screen is a snapshot shown until the next, timed by its picture's PTS,
  its text drawn in the user's style, at the top when every row is in the upper half. Roll-up and paint-on change the
  screen with every two characters; `cc_dec`'s throttle for them counts from the decoder's start, so it is off and
  only the last change in each 200 ms step of the timeline is kept, the same for every decoder of the stream. An MP4
  caption track has packets only where it has pairs, so a step's screen comes out once the packet's duration passes
  the step, not with the next packet. Pictures come in decode order, so their captions wait until no picture decoded
  later can be shown before them (a PTS below the next packet's DTS, or more pictures behind than the stream reorders;
  Matroska has no DTS). Playback hands the decoder only the pictures it decodes (`processVideoPacket`): the screens
  build on each other. A decoder (`cc_dec` starts in roll-up) shows nothing until a command sets the mode (resume
  caption loading, roll-up, resume direct captioning, carriage return) and starts over then: one started while a
  pop-on caption loads would write it onto the screen. A screen ends the cue before it. A step listed already keeps a
  screen read through it over a provisional one (read up to a seek or a window's end, `isProvisional`), else the
  fuller one (rows, then characters), as a decoder started after a seek or for a window read lacks the rows rolled up
  before. Window reads read the video stream itself for them. CEA-708 has no FFmpeg decoder; its services are left out
  (the 608 bytes broadcasters send beside them are read).
- **External files**: `.srt` / `.vtt` / `.ass` / `.ssa` are parsed whole; `.sup` / `.idx` are read whole when the track
  is selected (`extractEmbeddedSubtitles`). Background reads (`loads`, `windowRead`) are cancelled through
  their `FFmpegInterrupt`, blocking I/O included, once their track is no longer selected or the media stops. `stop()`
  and every load reset the subtitle state (`SubtitleController.reset`), so hosts get `[]`.
- **Track flags**: forced and SDH come from the stream's disposition, or from its title; an external file's from its
  name. History saves an external file by path and stream, which tells apart the languages of a VobSub index.
- **Dependencies**: libass, FreeType, HarfBuzz, FriBidi and libunibreak are built by `scripts/build_dependencies.sh`
  with FFmpeg and ship as dylibs; `CLibass` is the system library target.

## Metal tone-mapper (`HDRToneMapping.metal`)

- **Input** — biplanar YCbCr: `r16Unorm` luma + `rg16Unorm` chroma for 10-bit (VideoToolbox
  MSB-aligns P010, so range limits are expressed on the 16-bit scale, e.g. `4096/65535`,
  `56064/65535`), and an 8-bit path. Full/video range comes from the format description.
- **Pipeline** — PQ (ST 2084) inverse EOTF → linear nits → BT.2390 black level lift
  (`liftBlackLevel`) → BT.2390 EETF compressed to `targetNits` → BT.2020 → Display P3 (D65) with gamut
  clamping → sRGB encoding, the layer's transfer: macOS decodes it and maps it to the display, so the
  luminance the curve gives is the one shown. (A pure gamma 2.2 encoding read as sRGB lifted the shadows
  by up to 8× at 0.02 % of white, which hid a white and a black level that were both off.)
- **Reference white** (`targetNits`, `ToneMapController`) — 203 nits (ITU-R BT.2408) for high-peak media, lowered
  for low-peak mastering (`adaptiveTargetNits`). The scene's peak (Dolby Vision L1, else HDR10+) moves it between
  100 nits and that static white: a scene that fits under 100 nits is shown as the XDR presentation shows it (PQ 100 nits on
  SDR white), a brighter one keeps the static white, which leaves room for its highlights an SDR display has no
  headroom above white for. The scene's average doesn't lower it: that overexposed bright scenes.
- **Scene luminance** — the demuxer reads each HEVC and AV1 packet's dynamic metadata into `FrameHDRMetadata`, which
  rides the sample buffer (`FrameHDRMetadataBox`) through the decoders and `FrameQueue` to
  `ToneMapController.applyFrame`: the Dolby Vision RPU (NAL unit 62) and HDR10+ (SMPTE ST 2094-40: a T.35 message, in
  an HEVC prefix SEI or an AV1 metadata OBU, decoded by FFmpeg's `av_dynamic_hdr_plus_from_t35`, `HDR10PlusParser`). Both give the scene's peak, which the curve maps from instead
  of the whole title's MaxCLL, so a scene's highlights aren't compressed for a peak it doesn't have. L1 is smoothed
  between frames but for a scene refresh; HDR10+ holds per scene and changes at cuts, so it is taken as is.
- **Thumbnails** (`ThumbnailToneMapper`) are tone-mapped on the CPU the same way: each keyframe's packet metadata
  (`FrameHDRMetadata`) gives the scene's peak and white (`ToneMapController.sceneTargetNits`), the BT.2390 black lift
  and sRGB encoding follow, a Profile 5 frame is composed with its RPU's curves and matrices
  (`DolbyVisionPixelReshaping`, the shader's formulas), and a shoulder of their own brings the scene's peak to white
  in place of BT.2390's knee.
- **Black level** — the BT.2390 lift towards a display black of 0.06 % of white (`displayBlackToWhite`): a dark
  scene's shadows sit above it as on XDR, which a pure power curve crushes. mpv does the same with
  `--target-contrast` (1000:1 for SDR by default).
- **Sharpening** — AMD FidelityFX CAS: `peak = -1 / mix(8, 5, strength); weight = amplitude * peak`,
  which stays finite at `strength = 1`.
- **Output** — `.bgr10a2Unorm` in Display P3; 8-bit output bands visibly in skies and shadows.
- Source peak (MaxCLL / mastering luminance from side data or SEI) feeds
  `uniforms.sourcePeakNits`.

## Audio

A single `AVSampleBufferRenderSynchronizer` is the master clock; `AVSampleBufferAudioRenderer` is
attached to it. `FFAudioDecoder` resamples via `swr_convert` using `extended_data` (`data` only has
8 plane pointers) and re-creates its `SwrContext` whenever sample format, rate or channel layout
changes mid-stream (e.g. 5.1 → stereo after a track switch).

### Audio from another input

An audio track can come from a file of its own (a dub next to the video, later a host's or yt-dlp's separate audio
URL). `PlaybackInputs` holds the media's demuxer (`main`: picture, subtitles, variants) and a demuxer per added file,
opened `audioOnly`, and lists the tracks of all of them (a file's from `firstExternalTrackId` on). The selected track's
demuxer is the `audioSource` audio feeding reads; while a file's plays, the media's demuxer has none selected
(`selectAudioTrack(trackId: nil)`) and drops its own audio as it reads. Each demuxer keeps its own locks and
read-ahead thread and none is taken while another's is held, so a second input adds no lock order; a file starts
reading ahead on its first selection and reads nothing while none of its tracks is selected.

- **Seeks** position the file's input on `seekQueue` after the seek preview: where the picture landed (a keyframe seek
  lands seconds off the target), minus the audio delay. Interleaved in one file, audio is read from the keyframe on and
  trimmed (`setTargetAudioPts`); a separate input would have skipped what lies before the target.
- **Ends** are each stream's own (`isVideoEOF`, `isAudioEOF`): a file shorter than the picture ends while it plays on.
- **Buffering** triggers on either input running out (see "Stalls and buffering"), since one running dry no longer
  drains the other.
- **Files** come next to the media, named as it (`SidecarAudio`, the matching subtitle files use, `SidecarFiles`:
  `Movie.uk.mka` next to `Movie.mkv`; audio extensions only, as a picture container named as the media is another
  cut of it; only for media with a picture: next to `song.flac`, `song.mp3` is another copy), or by hand
  (`loadExternalAudio`). Those next to it and the one the history saved are opened with the media, side by side and
  off the main actor for a background load, before its tracks are chosen, so a request, the history and
  `TrackAutoSelection` choose among all of them (on a tie the media's own wins: it comes first, and a file's default
  flag is dropped). A file that can't be opened leaves the media playing without it. A track is named after its
  stream's title or else its file ("Movie.uk (External)") and takes the language its name tags when the stream has
  none. The history saves a local file's track by path and stream (`PlaybackRecord.externalAudio`); a URL (a host's,
  maybe signed) is never saved. A file opened while playing has an interrupt of its own that `cancel()` aborts.
