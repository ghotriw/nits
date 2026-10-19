# Nits Architecture

Background and rationale behind the rules in [`AGENTS.md`](../AGENTS.md). `AGENTS.md` holds the
short, enforceable invariants; this document explains how the pieces fit together and why.

## Mission

Reference-grade playback of HDR and Dolby Vision (Profile 8.1 / HDR10) video on macOS:

- **SDR displays** (external 4K/5K monitors, EDR == 1.0): a custom Metal tone-mapper (ITU-R
  BT.2390 EETF, 203-nit reference white, Display P3, Gamma 2.2, FidelityFX CAS) instead of the
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
  `NativeVideoHostView` canvas.
- **NitsKit** — `@MainActor` window lifecycle (`PlayerWindowController`, `PlayerWindow`), menu
  commands (`PlayerCommands`), system media integration (`NowPlayingController`).
- **NitsUI** — declarative views (`ContentView`, `ControlsOverlay`, `TimelineSlider`,
  `SettingsView`, `PerformanceHUDView`, `SubtitleOverlayView`). Transient UI state (fullscreen
  transitions, auto-hide) lives in `PlayerUIState`.

### Embedding (WKWebView / headless hosts)

The engine is designed to be embedded in hosts with web-driven UIs (e.g. an Emby client):

- `NativeVideoHostView` is a bare video canvas; a transparent `WKWebView` can sit on top.
- Commands in / events out go through `PlayerEngineProtocol`
  (`Sources/NitsCore/Protocols/PlayerEngineProtocol.swift`); the event callbacks
  (`onTimeUpdate`, `onPlaybackStateChanged`, `onTracksChanged`, `onBufferingChanged`) are shaped for JSON
  bridging to `window.webkit.messageHandlers`. The bridge itself belongs to the host: its message schema is the
  web client's, not Nits'. Nits keeps the protocol complete enough that a bridge needs no engine internals.
- `bufferedTime` is the furthest timestamp the demuxer has read (`MediaDemuxer.readAheadSeconds`, behind its own
  lock because the demuxer lock is held through blocking network reads), so it shows the few seconds of read-ahead,
  not download progress.
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
own PiP. The private `PIP.framework` (IINA, VLC) was rejected: it would show any view (Metal
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

## Metal tone-mapper (`HDRToneMapping.metal`)

- **Input** — biplanar YCbCr: `r16Unorm` luma + `rg16Unorm` chroma for 10-bit (VideoToolbox
  MSB-aligns P010, so range limits are expressed on the 16-bit scale, e.g. `4096/65535`,
  `56064/65535`), and an 8-bit path. Full/video range comes from the format description.
- **Pipeline** — PQ (ST 2084) inverse EOTF → linear nits → BT.2390 EETF compressed to
  `targetNits = 203` → BT.2020 → Display P3 (D65) with gamut clamping → pure Gamma 2.2
  (`pow(max(c, 0), 1/2.2)`).
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
