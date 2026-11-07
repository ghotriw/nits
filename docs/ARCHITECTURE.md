# Nits Architecture

Background and rationale behind the rules in [`AGENTS.md`](../AGENTS.md). `AGENTS.md` holds the
short, enforceable invariants; this document explains how the pieces fit together and why.

## Mission

Reference-grade playback of HDR and Dolby Vision (Profile 8.1 / HDR10) video on macOS:

- **SDR displays** (external 4K/5K monitors, EDR == 1.0): a custom Metal tone-mapper (ITU-R
  BT.2390 EETF with its black level lift, a reference white set against the XDR picture, Display P3, FidelityFX CAS) instead of the
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
  commands (`PlayerCommands`), system media integration (`NowPlayingController`), the app's command
  line (`LaunchArguments`).
- **NitsUI** — declarative views (`ContentView`, `ControlsOverlay`, `TimelineSlider`,
  `SettingsView`, `PerformanceHUDView`, `SubtitleOverlayView`). Transient UI state (fullscreen
  transitions, auto-hide, OSD, HUD visibility) lives in `PlayerUIState`.

Settings come in three parts, so that the engine sees only its own:

- **`PlayerConfiguration`** (`NitsCore`) holds only what the engine reads: tone mapping, resume, subtitle style,
  track languages, seeking, history exclusions.
- **`AppSettings`** (`NitsUI`) holds the app's: the OSD, action buttons, recent media, yt-dlp and the player window in
  Picture in Picture. `NitsKit` uses most of them, but the type sits in `NitsUI` for `SettingsView` and `OSDManager`
  to reach; `PlayerWindowController.applySettings(_:)` applies them. Both types save in the same `UserDefaults`,
  under the keys `SettingsView` writes through `@AppStorage`; a change only tells `AppDelegate` to load them again.
- **`LaunchArguments`** (`NitsKit`) lays the command line's flags over both, each until the user changes that setting
  in Settings (`dropOverrides(changedFrom:to:)`). The media to open, its headers, start time and tracks are its own
  properties, not settings.

Files opened from anywhere — a drop on the player or the Welcome window, the Open panel, Finder, a
local Recent Media item — go through one path, `MediaOpenRequest` (`NitsUI`): subtitle files come apart
from the media and attach to the video they came with (or to the one playing), the rest resolve through
`MediaURLResolver` and fill the playlist. `PlayerWindowController` hands it its own `openStream`; a
network URL (Open URL…, a network Recent Media item) opens through `openStream` directly.

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
whether the screen is HDR (`minimumHDRDisplayHeadroom`) and the display-link rate, and replaces a link
made for another screen (`screenIdentity`): a view's link does not leave a screen that is unplugged.
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
- The engine has no notion of an OSD or a HUD: what is shown is the host's (`OSDManager.isEnabled`,
  `PlayerUIState.isDebugHUDVisible` in `NitsUI`). It only refreshes `currentMetrics` twice a second while asked
  (`isCollectingMetrics`, `PlayerMetricsCollecting`); no timer runs otherwise.
- `bufferedTime` is the furthest timestamp the demuxer has read (`MediaDemuxer.readAheadSeconds`, behind its own
  lock because the demuxer lock is held through blocking network reads): for a network source, up to the
  read-ahead limit (see "Network read-ahead"); for a local file, the few seconds the feeders asked for.
- The demuxer accepts HTTP/HTTPS/HLS URLs with custom headers (`X-Emby-Token`, `Authorization`,
  User-Agent, cookies) passed as FFmpeg `AVDictionary` options.
- A DASH manifest (`.mpd`) is resolved by the engine's own `DASHManifestResolver`, asked before the host's
  (`MediaResolverChain`; it ends in `.mpd`, a name like Unified Streaming's `/.mpd` too). It downloads the manifest
  with the request's headers and gives the demuxer a rewritten one inline (`DASHManifest`, on `XMLTree`): FFmpeg's DASH
  demuxer opens every representation at once, fails for one it can't read (TTML), plays the first picture it lists and,
  in a timeline that repeats a segment to the end (`r="-1"`), seeks to the second segment. So it keeps the ladder of
  one codec and range (the preferred one, `VideoCodecPreference`; a ladder plays as one, `MediaDemuxer.variants`; the
  best picture of each other codec is in `ResolvedMedia.videoFormats`, each a manifest of its own with its ladder,
  which the format menu switches to as for a video site), the best audio of each language (not a codec FFmpeg has no
  decoder for: AC-4, MPEG-H;
  `CodecFamily.canDecodeAudio`), and drops text and images, trick play and DRM streams;
  gives timelines their repeats from the length of the period, and the manifest an absolute `BaseURL` of the address
  after redirects. A manifest it can't handle (live, several periods, unreadable) returns `nil`: the address opens as it
  is. Codec families are read by `CodecFamily`, shared with HLS. The segments' requests carry the headers through
  `segmentRequestOptions` as for any inline manifest.
- A page that isn't a stream (a video site's) is resolved by the host's `MediaResolver` (`engine.mediaResolver`)
  into the streams that play it (`ResolvedMedia`: the picture's, its separate audio, their headers, the page's
  subtitle files, chapters and action buttons). A host can give subtitle files of its own with any request
  (`MediaLoadRequest.subtitleFiles`); a resolved page's come before them. As in mpv, it is asked before the URL
  opens only for the sites known to have pages
  (`MediaResolutionOrder.beforeOpening`), and for other URLs once they failed to open as media: a media server's
  or IPTV stream neither waits for it (seconds per load) nor fails on its errors.
  A URL it declines (`nil`) opens as it is. After a failed opening it isn't asked when
  the host couldn't be reached (it couldn't either, and would add its timeout), and an error of its that is only about
  reading the URL (`MediaResolutionError.isAboutPage` false: yt-dlp's generic extractor's HTTP errors, a timeout)
  leaves the demuxer's reason shown. Nits' own, `YTDLPResolver` (`NitsKit`, as `Process` is macOS-only), runs the yt-dlp
  installed on the system rather than a bundled one, which would age with the sites: `YTDLPLocator` searches `PATH`
  and the package managers' directories an app opened from the Finder lacks, and runs it with them on its `PATH`
  (Deno, for YouTube). Its formats exclude DASH manifests; HLS opens from its master
  playlist (`manifest_url`), for its variants and adaptive bitrate. Segments of one URL (YouTube's recording of a live
  stream that just ended, `http_dash_segments`) are the last choice of the selector: `SegmentedDASHManifest` makes a
  manifest of them, given to the demuxer inline (`MediaURL.inlineDASHManifest`, a `data:` URL), where FFmpeg's DASH
  demuxer reads the picture and its audio out of one input and seeks by segment. It copies the HTTP options of its
  segments from the input the manifest came from, which a `data:` one isn't, so `FFmpegIOByteCounter` adds them to
  each request (`segmentRequestOptions`). The manifest has a `SegmentTimeline`: from the duration alone FFmpeg counts
  one segment too many and asks for it. And once a stream was read to its end the DASH demuxer closes its input and
  sets the stream to `AVDISCARD_ALL`, which a seek back doesn't undo: `seek` enables the streams playing again
  (`reenableEndedDASHStreams`). The manifest is the resolver's own format (`package` access, not for hosts to open),
  so the thumbnails, the history and the logs treat it apart (`MediaURL.loggable`). Needs the bundled FFmpeg
  (`--enable-libxml2`). Progressive files are read in HTTP requests of
  the size yt-dlp downloads them in (`http_chunk_size` → `httpRequestSize`, FFmpeg's `request_size`): YouTube throttles
  a request for the whole file to about twice its bitrate, which 2x playback outruns, and serves 10 MB ranges at the
  link's rate. The author's chapters stand in for a container without any. A YouTube video's SponsorBlock segments become skip
  buttons (`seeksToEnd`) and, when the author gave none, chapters: `SponsorBlockClient` asks the API itself by the id's
  hash prefix, while yt-dlp runs, and gives none when it fails (not yt-dlp's `--sponsorblock-mark`, which fails the
  whole page when the API can't be reached). The load
  keeps to the page: `currentPath`, the playlist and the title go by it, the history by the resolver's name for its
  media (`historyKey`: the history keys an HTTP URL without its query, where a `watch?v=` page names its video; none
  for yt-dlp's generic extractor, whose ids are a URL's last component). The streams expire, so every load resolves
  again; `currentSourcePath` is the stream opened, which what reads the media again (thumbnails, embedded subtitles)
  opens.

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

Seeks run on the serial `seekQueue` and carry a generation token (`SeekGeneration`); stale seeks are
dropped, so rapid scrubbing never runs concurrent demuxer seeks. A seek clears `FrameQueue`,
flushes the decoder and the renderer, but keeps the `VTDecompressionSession` alive. Before any
session invalidate/reset, `VTVideoDecoder` waits for in-flight frames
(`VTDecompressionSessionWaitForAsynchronousFrames`) so output callbacks can't race the replacement.

A burst of seeks chases its latest target (`ChaseTarget`): seeks that come while one runs only move the target, and
the running one goes on to it when it finishes. A press (an arrow key's, a skip button's) asking for the very target the
running one has changes nothing, so repeats clamped to the same position (the end or the start, where an exact and a
keyframe seek land on the same frame) don't start its decoding over. Any other seek there supersedes it: a track or
variant switch re-reads from the target of the seek in flight, which has read the media as it was selected before. Seeking stays orchestrated on `PlayerEngine` (it stops the clock, the
feeders and the display link and restarts them), while the parts that need none of that are types of their own:
`SeekPreview` decodes the frame a seek lands on and picks it (`SeekPreview.FrameChoice`), `RelativeSeekBurst` follows a
held arrow key's run of seeks, and `FrameStepState` with `StepFrameCache` and `FrameStepPump` serve paused frame
steps without a keyframe re-seek. A forward step that seeks carries the frame it steps from (`minFramePTS`) so it lands
past it.

Past the last keyframe a forward keyframe seek has no keyframe to land on after its target. Rather than fall back to
the one before it, seconds back near the end, `MediaDemuxer.seek` goes to the target exactly from there and says so
(for MPEG-TS / MPEG-PS when the keyframe search finds none to the end); the engine decodes the preview as an exact
seek's (the packet cache does the same once its input is read to the true end). A target at or past the end lands on
the last frame: a held arrow key never goes back. Landing at the end ends
the media when playing (`handleEndOfMedia`, the same as playing on to it), once the resume debounce is over, so key
repeats still held land there rather than on the next item; paused, it stays on that frame.

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
- **HLS** can start before 0. The segments of a live or EVENT playlist listed before the one reading begins at (three
  from the end) are placed earlier than its first timestamp, which is small when timestamps restart at a break, and the
  engine takes `currentFramePTS >= 0` for "a picture is there". `timelineOrigin(of:)` gives HLS (and only HLS) a negative
  origin too: the stream's start is its zero, and a live window opens at 0. The other formats flagged `AVFMT_TS_DISCONT`
  keep a positive origin or none.
- **AVI** stores decode order only, so I/P packets have no PTS. The sample's PTS falls back to its
  DTS (the engine needs one), but it carries `presentationTimeUnknownAttachmentKey`, and
  `FFmpegVideoDecoder` then leaves the packet PTS unset so FFmpeg reorders B-frames correctly.
  Packet metadata (duration, `DoNotDisplay`) reaches the frame through `AV_CODEC_FLAG_COPY_OPAQUE`
  rather than timestamp matching. Exact-seek preroll on such samples carries the target
  (`exactSeekTargetAttachmentKey`), and the decoder decides on the frame's real PTS.

### The master clock and resuming after a seek

A seek while playing pauses the clock, lands, and starts it again. Done naively that costs hundreds of milliseconds and
blocks the UI, and where the time goes is in the audio renderer, not in decoding. This section is what was measured
and the rules that came out of it. (Measured on a 4K HEVC / Dolby Vision MKV on a local disk, built-in speakers; the
measurement tests are in `SeekSpinnerTimelineTests` and run with `NITS_TIMELINE_MEDIA=<file>`.)

**`AVSampleBufferRenderSynchronizer.setRate` blocks.** It waits for the audio renderer's queue, which holds its lock
while it starts, stops or flushes. A pause that follows a start (a second press of an arrow key) blocked the caller for
up to 700 ms, and the caller was the main thread or the display link's. A stack sample showed the main thread inside
`FigAudioQueuePause`, waiting on a mutex, with a dozen audio-queue threads alive, which suggests that a flush recreates the renderer's queue (not
confirmed beyond the thread names).

**`PlaybackClock` owns the synchronizer and applies its rate changes on a queue of its own.** A change is recorded at
once and applied in order behind the caller's back, so `setRate` never blocks a caller. Nothing else calls
`synchronizer.setRate`. The clock the engine decides on is the one it asked for, not the one the synchronizer shows yet:

- A clock asked to hold reads as held at that position, applied or not.
- A clock asked to run reads as standing at its start until the change is applied *and* the synchronizer has come to
  it (`settlingTolerance`, with `settlingTimeout` as the way out). The synchronizer keeps showing the old position
  for a while after `setRate` returns (until the audio device runs, tens to hundreds of ms), and a reader that took
  that for the clock would drop every frame from the new position as late. It is not projected forward: the
  synchronizer holds the clock back while the device starts, and a clock that ran ahead of it would step back.
- A change of rate on a running clock (`keepsRunning`, said by the caller; deciding it from a reading would be a read
  of the synchronizer on the caller's thread) is read as it runs, without waiting for a start.
- The synchronizer is never read under the clock's lock, for the same reason `setRate` is queued.

The display link, the time observer and the engine all read `PlaybackClock.currentTime()`.

**Resuming after a seek: the picture first, the audio joins.** A resume used to wait for the audio: flush the
renderer, refill it to `audioAheadToStart`, start the clock one output latency ahead. On built-in speakers that is tens of
milliseconds. On AirPods every link is longer (a flush up to ~350 ms with the synchronizer running, output latency 171
ms), and the picture stood still for all of it; a series of seeks stacked the waits (a spinner that stayed up after the
frames were running again). The rules that replaced it:

- **The picture does not wait for the audio.** The seek that resumes starts the clock on host time alone
  (`PlaybackClock.startProvisional`): `currentTime()` reads `target + (host − start) · rate`, the synchronizer stays held at
  rate 0, and the display link picks frames from it as from any clock. The start still waits for the anchor frame (the
  video preroll), not for the audio. A series of seeks costs the picture and nothing else; no wait for repeats
  (`ChaseSettling`, `burstDebounce` and `endSeekBurst()` are gone).
- **A held key scrubs** (`beginScrubbing()` / `endScrubbing()`, from `PlayerWindow`). Resumed at once, the picture
  played a few frames between a held key's repeats (every ~75 ms) and the feeders and the audio join started and were
  cancelled for each. mpv shows only frames there because its restart waits for the audio and skips playback when the
  next seek is already queued (`handle_playback_restart`); here the restart no longer waits, so the window says what
  mpv infers: the press of ← / → begins scrubbing, its seeks (and its repeats') land and hold the clock at their frame,
  and the release of any key (fn turns the arrow's key-up into Home / End; another key stops its repeats) or the window
  losing focus resumes once from the last landing. Not a timer. A tap resumes as the finger lifts, or as its seek lands
  if that comes later. Begun at the press, not at the first repeat: the system waits ~225 ms to 1.8 s before repeating,
  and the burst (exact first press, keyframe repeats, the offset the OSD reports) must not end in that gap, so the burst
  timer does not run while scrubbing. A landing at the end held by scrubbing drops further presses forward, which would
  only decode the last GOP again.
- **`AudioJoin` brings the audio back behind it** (`AudioJoin.swift`; one per engine, cancelled by `cancelPreroll()`):
  1. It waits until the change to rate 0 is applied, then flushes the renderer, **only if what it holds reaches past
     where the new audio starts** (`AudioJoin.needsFlush`: the renderer's `bufferedEnd` against `clock + latency`, both on
     the clock's timeline; a seek on pause applies the same rule from where the picture landed). Audio that ends before the
     start is late once the clock gets there, and the synchronizer drops it without a sound; so a seek forward past what
     was fed, or a series of them, keeps the renderer, and a seek back or a short step forward within it flushes.
     The flush is what costs: with 5.1 to AirPods (the engine's renderer settings) it stops the output device's IO about
     100 ms later, and the device runs again ~0.5 s after that, so the sound came back up to a second after the last
     seek of a series. Holding the clock at rate 0 does not stop it (0.6 s held, IO running), nor does a flush of stereo
     with the renderer's default settings; forbidding spatialization in code (`allowedAudioSpatializationFormats = []`)
     did not avoid it either (probes of 2026-11-01; turning spatial audio off in Control Center did, not investigated).
     `flush(fromSourceTime:)` is no way around it for a seek back: it refused every time, even with the clock still at
     the old position, and the old audio played on. Flushing under a held synchronizer took 60–80 ms on AirPods,
     under a running one ~350 ms.
  2. It feeds audio from where the picture is *now*, not from the seek's target: buffers that end before
     `clock + latency` are dropped and the one that straddles it is shortened to the sample (`AudioSampleTrim`; an AAC
     packet is 21 ms, AC-3 32 ms, and whole-buffer cuts would put the audio off by that much from seek to seek).
  3. When the renderer holds `BufferingPolicy.audioAheadToStart` past the point it will start at (`clock + latency`), or is
     full (a held synchronizer takes only so much: an enqueue that waits on it `fullAfter`, 50 ms; one with room returns
     at once), or the audio has ended, the synchronizer takes the clock over. A renderer kept (step 1) is usually full of
     the old audio, which it drops as late only once the clock runs: the new gets in after the hand-over, so the join
     stays on until it is ahead of the clock (`settleTimeout`, 1 s), and `checkForStarvation` leaves the audio out
     meanwhile (without a picture it would hold the clock on a renderer that, held, never makes room). The hand-over:
     `PlaybackClock.handOver(after:)` gives it `setRate(rate, time: T(H1), atHostTime: H1)` with `H1 = now + latency`,
     `T(H1)` the position the provisional clock holds then. From `H1` on `currentTime()` reads the synchronizer, once it
     reads where the provisional clock is (or `settlingTimeout` has passed); until then it keeps projecting, so the clock
     never steps back. A change of speed while provisional re-anchors the provisional clock (`changeProvisionalRate`);
     the join takes the rate at the handover.
  4. The wait is bounded (`AudioJoin.timeout`, from the moment the picture's clock starts): past it playback goes to
     buffering (`holdForBuffering`), the honest state of waiting for sound, not a clock started over an empty renderer.
  While joining, `checkForStarvation` judges by the picture only (`audioJoin.isActive`); the time observer does not fire
  while the synchronizer is held anyway.
- **`play()` after a seek that did not resume** (a seek on pause, or one the user paused during) is a join as well:
  `audioJoin.isRendererStale` is set by any seek and cleared by a join that ends. Without it the clock started on an empty
  renderer and buffered at once (12 of 12 runs on AirPods).
- **Without a picture** (audio-only media) there is no clock to run ahead: the clock is held and started, one latency
  ahead, when the audio is ready, and nothing is cut.
- **A seek waits for the video feeder of the run it supersedes to unwind** (`waitForUnwind(of:)`, on `seekQueue`, before
  the decoder is flushed and the demuxer moved), then clears the frame queue once more. The feeder is only cancelled, and
  one inside a decode of a packet from the old position delivers its frame after: `SeekPreview` takes the earliest frame
  the decoder emits for a keyframe seek, so that stale frame won over the landing's. The clock then started at the stale
  frame's time (1890.2 s for a seek to 1898.84 s) while the demuxer and the queue were at the landing (1900.4 s): the
  queue held frames 10 s ahead of the clock and `popFrame` held them until the clock got there, a frozen picture with no
  spinner (seen on a LAN MKV in about half of long forward series). With the old debounce no feeder ran when the next
  seek came; now one starts at each landing.
  The wait is `decoderStallTimeout` plus half a second, so it ends only when the feeder has left or the stall guard has
  given the decoder up and it is being replaced: a slow but live decoder is never left behind to emit its frame into the
  preview. (`StaleFrameSeekTests` holds a decode in flight and checks the landing.)
- **A seek that lands at the end** waits `endOfMediaWait` (300 ms) for more presses before the media ends; the repeats of a
  held key would otherwise land in the next item a completion loads.
- **Do not ask the HAL on the main actor** while the output device is stopping or starting (`currentOutputLatency()`): the
  query waited ~230 ms behind the device, which stalled the main thread in the middle of a series of seeks. `AudioJoin`
  asks it off the actor, after the clock is idle.

What it costs: the sound comes in after the picture, a hundred or so milliseconds later on speakers and a few hundred
on AirPods, in sync from the first sample it plays (the start of the sound is skipped, not shifted). While a key is held
there is no sound at all.

**What was measured** (4K HEVC / DV MKV on a local disk, `SeekSpinnerTimelineTests`; AirPods, output latency 171 ms):

| | Before (debounce + wait for audio) | Now |
|---|---|---|
| Held arrow key, system repeat rhythm | spinner from ~600 ms to 100 ms after the release | no spinner |
| 12 taps with a pause of 120 / 200 / 350 ms | spinner 1.0–1.6 s / 0.3–0.9 s | no spinner |
| `play()` after a seek made on pause, clock moving | 346–378 ms | 211–232 ms, no buffering |
| `play()` after a seek the user paused during | 346–369 ms | 259–298 ms, no buffering |

A probe of the take-over (`setRate(time:atHostTime:)` after a flush, margins of 0 to a latency and more, built-in speakers
and AirPods) showed the synchronizer reading the provisional clock's position from `H1` on at every margin, and the call
returning in 1 ms. That reading is the timebase, not the device: that the sound is in sync is judged by ear, on the
`flashClick` preset (a white frame and a click on every second; `flashClickAudio` is its sound alone, to add as a track).
`SyncPatternTests` checks on it what a test can see: that the white frame is picked when the clock is at its second
(within a frame: it is picked for the next vsync), after a load, keyframe seeks forward and back, an exact seek, an audio
delay and with an added file's audio; and that the audio handed to the renderer has each click at its own timestamp, to
a few samples. A 100 ms pick offset or a 1 ms audio timestamp offset fails it. The preset's FLAC comes in 100 ms packets:
Matroska keeps milliseconds, and 1024-sample packets put the audio after a seek ~0.35 ms off its timestamps.

**Why not "as in mpv / IINA"** (`.ref/mpv/audio/out`). mpv does not restart the audio device on a seek: `ao_coreaudio.c`
pulls audio from an AudioUnit and on a seek only calls `AudioUnitReset`, which empties its buffers and leaves the unit
running (it is stopped later, after an idle timeout; restarting it "takes a noticeable amount of time", with a wireless
device most of all). `AVSampleBufferAudioRenderer` has no such operation: the only way to empty it is `flush()`, which
restarts its audio queue and, on some routes (multichannel to AirPods), the output device's IO with it (see
`BufferTrackingAudioSink` and step 1 above). That is the cost of this stack, paid now only when the renderer holds audio
past the new start, and mpv's playloop, which restarts after a seek only when the first frame and the audio are ready, does not carry
over to it. So the audio is kept off the picture's path. (What is verified here is the `ao_coreaudio.c` code and our
measurements; how `ao_avfoundation` feels in IINA is not.)

**Changing the audio track** is an exact seek to the current frame (`rereadPosition`): only the selected streams are
read (`applyStreamSelection`), so the new track's packets around the position were dropped and the media is read
again from the keyframe before it. It used to stop the clock for 140–230 ms, which was the wait for the new track's
audio; since the picture no longer waits for it, the picture only stands while that seek lands (decoding from the
keyframe to the current frame, barely visible in the bundle), and the new track's sound joins behind it with a
flush (`expectFlush`: the old track's audio, in a format of its own maybe, is not left to play out as late).

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
- **Seeks and packet cache.** Read-ahead packets are stored in `DemuxerPacketBuffer`. Consumed packets are
  retained as backward history (`backBytes`, up to 64 MB), pruned strictly by whole GOPs (so the buffer's head is
  always a keyframe) with a hard cap at 2× limit (falling back to linear pruning for streams without keyframes, like
  intra-refresh). Keyframes are indexed (binary searched) for video only. Audio history is pruned linearly with a 0.5 s
  margin before the earliest retained video keyframe (audio decoder priming); without video (an audio-only input, such
  as the external audio of another input's picture), by size alone, so it reaches as far back as that picture's
  history. History is off (`maxBackBytes = 0`) for live streams, whose cache is never used. A ladder keeps it like
  any input: each video packet carries the `variantGeneration` it was read in (`MediaDemuxer.variantGeneration`, bumped at a
  variant's splice), and a cached seek of a ladder is served only when the keyframe it lands on and the cursor's
  position have the same generation, with no splice between them (`keyframesShare`): the engine's variant label,
  `pendingVariantChanges` and the decoder's description stay right without a journal. After a variant chosen by hand
  the packets must also be of the variant read now (the engine seeks at once to show it), and nothing is served while
  it is asked for or being switched to (`variantSwitch`, read under `queueLock`, which every write holds). Audio: the
  variants switch only when their audio streams share a time base (`canSwitch`), as queued audio keeps none.
  Seeks landing within the buffered range (backward into history or forward into pre-read packets) are satisfied
  atomically under `queueLock` without network I/O (`seekWithinCache`, tried first by `MediaDemuxer.seek`;
  `seekReportingCache` also tells the engine whether it served the seek). A seek to the start finds a first picture
  presented up to 0.25 s after 0 (B-frames, edit lists). A keyframe (any packet, for audio) whose timestamp goes back
  starts a new timeline (`searchFloor`): older packets are not searched, stay queued to play if not yet taken, and are
  dropped once taken. Anything else is a slow seek (`performSlowSeek`), which clears
  the buffer and re-anchors the read-ahead thread at the target:
  - a cache miss, a live stream, a ladder's seek across a splice (variant and resolution desync);
  - an HLS subtitle rendition selected after the packets were read (`selectionOutdatesCache`: the rendition is a
    playlist read only while selected, so they lack it; the demuxer holds the flag until a slow seek, which the
    engine's re-read for the rendition is). An audio track needs no flag: its queue is emptied at selection, and a
    target the audio left does not cover misses;
  - a timeline break (above) the cursor has not passed (`isBeforeBreak`: the position is on the older timeline and a
    target found on the newer would land on other content), or one only the video or only the audio has met so far
    (`breakCount` differs: one stream is on a timeline the other has not reached). A slow seek clears both;
  - a selected bitmap (PGS / VobSub) or closed-caption subtitle track (their decoders keep state between packets);
  - a read-ahead that ended before the container's duration (a dropped connection can read as EOF, and playback would
    end where it dropped; a seek in a cache that reaches the duration keeps the end, which is the media's).
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
  12.7 s and 5.7 s. Keep-alive is off: FFmpeg would send the playlists over the master's connection without
  `io_open`. What isn't downloaded FFmpeg
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
- **DASH variants.** A DASH manifest's ladder (`DASHManifest.ladder`: the pictures of the best one's codec and range,
  the manifest written with every rung) is the demuxer's variants: FFmpeg's DASH demuxer has one program and a stream
  for each representation, the picture ones with `variant_bitrate` (`dashVariants`), the sounds the manifest's own.
  Its segments are served by `HTTPSessionTransport` as HLS's, which `AdaptiveBitrateLogic` measures. A switch is the
  same splice, with one difference: FFmpeg's DASH demuxer reads the representation whose last picture presents
  earliest, so with B-frames the new variant, catching up from the start of its segment, runs ahead of the old by the
  depth of the reordering (HLS's reads by decode time), or the old variant reads its own keyframe first, and the order
  is no rule. So (`MediaDemuxer+VariantHold.swift`) the old variant's pictures are delayed while the keyframe is looked
  for (`heldOld`, `heldOldVideoLimit`), and the keyframe is not spliced when found: it, and the pictures after it, are
  held (`candidate`, `heldVideo`) until the old variant hands over its first picture that decodes with or after it,
  and the format description changes then (a packet keeps the one it was read with). The
  held pictures are `AVPacket`s kept by reference and go through what every picture does when released, the captions
  in their SEI (`processVideoPacket`) first, in the order the decoder takes them. The keyframe must decode after every
  picture the old variant has handed over, else the old one's own keyframe would be repeated. A seek, the end of the
  input and `heldVideoLimit` pictures end the wait.
  FFmpeg's DASH demuxer frees libxml2's process-wide state after each manifest it reads (`xmlCleanupParser`), which
  crashes a parse going on in another thread (our `XMLTree`, the playlist parser's XSPF, a system framework's): the
  bundled FFmpeg is built without that call (`scripts/patches/ffmpeg-dashdec-keep-libxml2.patch`, applied by
  `build_dependencies.sh`; upstream has it still). A Homebrew FFmpeg has no DASH demuxer, and so has no such call.
- **Adaptive bitrate** (`AdaptiveBitrateLogic`, `MediaDemuxer+AdaptiveBitrate.swift`) chooses the variant while
  reading ahead, until one is chosen by hand.
  - *Requests* go through `URLSession` (`HTTPSessionTransport`), not FFmpeg's HTTP: `FFmpegIOByteCounter`'s
    `io_open` hands FFmpeg an `AVIOContext` of a task's own (`HTTPSessionInput`) for every HTTP(S) request of an HLS
    demuxer, once the context is one (the master, probed first, FFmpeg opens itself, so a redirect still resolves).
    `io_open` waits for the answer's headers; the body comes into a buffer while FFmpeg reads at its own pace
    (suspended past 32 MB unread). The session keeps the connections open; FFmpeg's `http_persistent` is off, as it
    only keeps those of its own inputs, and sends the requests over them past `io_open`. What isn't served so FFmpeg
    opens as before: a redirected answer, a range answered whole, encrypted segments (`crypto+`), a file read over
    HTTP (it seeks). The requests carry the source's headers, and FFmpeg's user agent (`Lavf/…`) without one.
    Measured inside FFmpeg instead, the throughput was a guess from how long reads took: a read served from what the
    socket buffered counted at memory speed, a request over a kept connection waited for its answer inside the read
    (Apple's CDN answers after 0.6–0.8 s on a cold cache, `x-cache: hit-stale, miss`), and a live stream's edge
    looked like a stalled network. Each guess needed a heuristic, and each heuristic missed a case: Apple's AV1
    example came down to 1080p or lower within seconds of a start at 184 ms of round trip, and stalled for up to
    1.4 s, on a link carrying 4K many times over.
  - *Throughput* is each request's transfer, from its answer to its last byte (`NetworkTransferMeter`), as VLC,
    hls.js and ExoPlayer measure their segments' downloads. A sample weighs the media its bytes are at the variant's
    `BANDWIDTH`: an audio segment a twentieth of a 4K video one's. Taken over every transfer together, or weighed by
    its seconds when slower than real time, half a megabyte of audio on a connection idle since its last (TCP starts
    it slowly again: 5.7 Mbit/s of 90 at 184 ms) weighed more than a 4K segment, and took the variant down to 864 wide
    two seconds in. The first estimate waits for a second of the variant's media: after the first video segment.
    Requests stay one at a time (`http_multiple` off): the next segment asked for while one is read would hide its
    answer's wait, but over HTTP/1.1 the body comes with the answer, so the one read, needed first, came in at half
    the rate (a live stream at 1.5 Mbit/s: the read-ahead empty for 7 s), and a task suspended once answered took
    its body all the same, into the socket's buffer. A sample comes once a request ends: a link collapsing in the
    middle of a 4K segment shows in the estimate only after it (hls.js samples a fragment loading, to abandon it).
    Transfers that run side by side share the link, each at a part of it: at a switch the old variant's segment is
    still read while the new one's comes (both are enabled until the splice). A sample's rate is the link's: all the
    bytes every transfer received while this one ran (`NetworkTransferMeter.received`, `Transfer.linkBytes`) over its
    seconds, however they divided it (a share assumed equal overrated a heavy segment beside a light one). Taken as
    each one's own, 1.5 Mbit/s read as 0.8–0.9 for the two transfers of the first switch and took the estimate under
    the variant switched to (0.95 of 1.05 < 1.08), down to the lowest (`switchOverlapIsNoCollapse`).
  - *Latency*, the time inside `io_open` waiting for answers, counts as seconds per second of media read
    (`latencyShare`), the same for every variant: a variant fits when a second of it reads, transfer and latency,
    within its share of a second (dash.js weighs latency so too). A server slower to answer than its segments last
    brings the variant down however fast the link, to the lowest when the latency alone takes `safety` of the
    media, with no estimate yet too. A request counts once answered, ahead of its media: the share counts from 6 s
    of media read on. Answers for bodies under 16 KB (init sections, keys) are paid once, at the start and a switch,
    and count in no share: counted, two init sections' 0.76 s took the share from 0.29 s a second to 0.42 over the
    first 6 s of media, enough to bring 4K down. Openings while a variant switch catches the new variant up count
    neither: a cost of the switch, read without media.
  - *Live edge*: FFmpeg sleeps inside the read, reloading the playlist, until it lists a segment: a long read with
    next to no bytes (`isLiveEdgeWait`). It counts as a full read-ahead, which a live stream never reaches otherwise,
    and the reloads as no latency.
  - *Decisions*: an estimate (the lower of two exponential averages, as dash.js and GStreamer) keeps a variant that
    reads within 0.95 of a second, as hls.js does (`abrBandWidthFactor`), and brings one that doesn't down while
    the read-ahead is under two thirds of its limit. It steps up to what reads within 0.7 of a second (hls.js's
    `abrBandWidthUpFactor`, ExoPlayer's `bandwidthFraction`) from 10 s of read-ahead (ExoPlayer's
    `minDurationForQualityIncrease`), 2 s after a switch. Without a recent estimate a full read-ahead probes one step
    up (at its limit the thread measures nothing, however fast the network), 10 s after a switch; a step up that
    comes down soon doubles the wait before the next. At 0.8 to be kept, a start on a cold cache came down from 4K
    on its first estimate (76 Mbit/s, before TCP had opened up; then 150–180): 4K's 38.5 Mbit/s read within 0.84 of a
    second, and the read-ahead grew all the same. Waiting for a full read-ahead to step up, the step back up came
    17 s in, and showed 21 s later still: a switch splices at the read position.
  - *Stepping up past the estimate's reach*: a variant held at 0.7 to 0.85 of the link never climbed (the estimate
    steps up at 0.7, a full read-ahead probed only without a recent estimate): on a 25 Mbit/s link Apple's AV1 example
    stood on 1080p at 11.3 Mbit/s for 100 s, the link carrying 4K at 18.9. With a recent estimate, a full read-ahead
    (`highBuffer`) and `upSwitchInterval` (times the failed probes' backoff) after the last switch, the logic now tries
    the next variant of more bandwidth and no fewer pixels (21.5 Mbit/s at 2560 wide after 18.9 at 3840 isn't a step up;
    an unknown size counts as no fewer) when 0.85 of the estimate less the latency share fits it (`probeSafety`). Not
    at a live edge: there the read-ahead is raised to stand for a full one while seconds are buffered
    (`isReadAheadReal`).
  - *Hysteresis*: a variant just stepped up to (within `failedProbeWindow`) is left only when it doesn't fit 1.0 of the
    estimate (`probeHoldSafety`, its peak bandwidth against the estimate), not 0.95, and when that has held for 5 s
    (`holdDebounce`), unless its bandwidth is over the estimate itself or the read-ahead is under `urgentBuffer`. A
    steady 25 Mbit/s link's estimate dipped to 20 for a second (23 to 20.7 with 0.1 of latency) and took 18.9 down 8
    to 13 s after the step. A variant reached by a step down has no such hold: with 0.15 of latency a second of 18.9
    costs 0.99 s of wall time at 22.4 Mbit/s, and leaving it is right.
  - *Start on a slow link*: an HLS opening's prefetch (`HLSPlaylistPrefetcher.Throughput.rate`, bodies only) follows
    the CDN's answer as much as the link (4.8 to 62 Mbit/s on fast links, 17–24 on a true 25, 1.6–1.9 on 2), so it
    proves a link slow and never fast. Under 3 Mbit/s (`slowLinkLimit`, below the lowest read on a fast link), from two
    starts and 256 KB on, the start is the highest variant within `safety` of it (as DASH's `OpeningLimit.throughput`
    does), else the lowest; otherwise the best, as before. On 2 Mbit/s (NLC "DSL") a start on the top variant (39
    Mbit/s) stalled 62–70 s of 120, the first estimate coming after a 10 MB segment; on the variant the rate carries,
    0 s in two runs. A link between 3 Mbit/s and the best variant's bandwidth still starts on the best.
  - Measured on Apple's AV1 example (2026-10-24, Wi-Fi, three runs each, 45 s from the start, time below 3840 wide):
    - 34 ms round trip, warm cache: FFmpeg's HTTP and the transport alike 3840 throughout; the estimate's lowest
      17–20 Mbit/s through FFmpeg, 276–286 through the transport.
    - 184 ms (Network Link Conditioner), warm cache: FFmpeg's HTTP 27–38 s below, down to 608–1920, stalls of 0.1
      and 1.4 s; the transport, its samples weighed by their seconds when slow, 27–41 s, down to 864; weighed by
      their media, 0 s.
    - 184 ms, cold cache (10 minutes apart): kept at 0.8 and stepped up on a full read-ahead, 27.5 s below; stepping
      up from 10 s, 12–15.5 s; latency paid once left out, 11.5–12 s; kept at 0.95, 0 s. No stall in any of these.
      A cold cache's origin sometimes sends the bodies slowly (36–51 Mbit/s): coming down to 1920–2560 there, with
      4K at 38.5, is right.
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

### Discontinuities in HLS (`EXT-X-DISCONTINUITY`)

A stream with ad insertions or splices may restart its timestamps (from zero, or another base) or jump at a
discontinuity. FFmpeg's HLS demuxer does not read the tag; left alone, the pictures of such a segment meet a clock far
from them (dropped, or waited for), and a seek past the first break lands at the start of the file (its seek drops
packets until their timestamps reach the segment's start on the playlist's timeline, which a restarted segment never
does). The bundled HLS demuxer is patched (`scripts/patches/ffmpeg-hls-timeline.patch`, after
`ffmpeg-hls-live-seek.patch`) to move the packets of the segments after a discontinuity onto the playlist's timeline: by
where the playlist's durations put the segment, minus the timestamp of its first packet, one offset per playlist so audio
and video stay together, taken at the first packet after a seek or a variant switch, and at the first packet that jumps
(by 2 s against its own stream's last) after a segment that follows a discontinuity. A server that keeps its timestamps
is not touched (after a seek a difference under half a target duration is not taken; while reading, a jump of 2 s or more is taken from a second of difference), nor is a playlist without the tag. So the
demuxer's timeline is the playlist's: the engine, the read-ahead's measure (`readAheadState` against `consumedSeconds`)
and the packet cache see one, and the cache's `searchFloor` (a timestamp going back) is a safety for what the patch does
not cover (a file of segments cut and joined, an MPEG-TS with a reset). Tests of the patch read the build's version string
(`--extra-version=nits-hls-timeline`) and are skipped on another FFmpeg, which has none of it.

The picture's size can change at a break too (an advertisement in another encoding): the parameter sets in the stream
change, and the demuxer starts a new format description where a keyframe carries others (`videoPacket(from:)`, for
H.264 and HEVC with the sets in band); the packets after it carry it, VideoToolbox follows with a session per
description, and `onVideoSizeChanged` tells the player the size, which it applies when playback gets there like a
variant's change (`videoSizeWillPlay`). The first keyframe after a slow seek tells its size whether or not the sets
changed, as the player may show the size of another stretch (content, an advertisement, content again) that the
reading, ahead, has left.

In fragmented MP4 the parameter sets are not in band but in the init section, and a playlist may renew `EXT-X-MAP` at the
break. FFmpeg's mov sub-demuxer skips every `moov` after the first, so the streams keep the first section's `avcC` /
`hvcC`. A third patch (`scripts/patches/ffmpeg-hls-update-init-extradata.patch`) parses the init section of a playlist
that has more than one with a mov demuxer of its own and passes a stream's extradata, where it differs from what the
packets before were given, on its next key frame as `AV_PKT_DATA_NEW_EXTRADATA`; after a seek it passes the landing's
whatever it is (the player may hold the description of another stretch). `refreshVideoFormat` takes the sets from that
side data like it takes in-band ones, and everything after is the same path. An audio rendition with a playlist of its
own has its breaks and its offset of its own (`dts_offset` is per playlist); picture and sound meet because the
`EXTINF`s of both playlists put the segments at the same places (`HLSDiscontinuityFMP4Tests` checks the first packets of
the second stretch to keep the first's lead of picture over sound within 20 ms on the synthetic stream, and no gap in either).

Not covered: the advertisement of some streams (Mux's Deltatre DAI) is MPEG-TS with a PMT of its own, whose packets
FFmpeg's HLS demuxer drops as corrupt; subtitles, whose playlists are not moved. See `docs/OPEN_ISSUES.md`.

### Live streams

An HLS playlist that slides (no `ENDLIST`, not `EVENT`: a YouTube live stream's DVR window of about 15 minutes) is a
live stream. It has no duration (`MediaInfo.duration` is 0, so everything keyed to a duration stays off: the end of
media, history, resume, thumbnails); what is played is a **window**, `LiveWindow`, from the first segment its playlist
lists to the end of the last. Both ends move with real time.

- **The window comes from FFmpeg.** The bundled HLS demuxer is patched (`scripts/patches/ffmpeg-hls-live-seek.patch`).
  Upstream master's series of 2026-07-08 makes a live playlist seekable and puts `first_timestamp` at the playlist's
  first segment (9.0.2 starts it at the first packet read, a few segments from the edge, and a seek fails). Ours
  publishes, after every load of the playlist *read* (the variant playing's, never a rendition's: an audio rendition has a
  window and an end of its own; with a master playlist it is not the
  first, which the series' `first_timestamp` follows only; ours tells it the media sequence number it is the start of,
  `first_timestamp_seq`, so that any needed playlist advances it, by the segments it dropped, or by the time that has
  passed when the gap is longer than the time allows (a pause makes it as long as itself; variants numbered from other
  bases tell nothing of each other; a small step back, a CDN's older playlist, changes nothing)), the window as the format
  context's `start_time` and
  `duration`, and tags it `hls_live` with the media sequence number of its first segment (`LiveWindow.hasSlid`: the
  start moves from the first load on). When the playlist ends the last window stays and the tag goes
  (`LiveWindow.hasEnded`). `MediaDemuxer.publishLiveWindow` reads them on the reading thread right after
  `av_read_frame` (FFmpeg writes them there) into `liveWindowState`, a lock of its own like `readAheadState`, with the
  time it first saw the window (`LiveReport.loadedAt`: the load's, which the engine, reading it much later after a pause,
  moves the window on from). Drop the
  first part of the patch when the bundled FFmpeg has the series.
- **A stream that ended** (`LiveStream.isEnded`) is a recording: the last window stands, seeks stay in all of it, there
  is no edge (no badge, no "go live"), the timeline shows time into the window and its length, and playback ends where
  the window does (`isAtEndOfMedia`).
- **`LiveStream`** (`engine.live`) owns what the engine makes of it: the window as last told and **extrapolated** (a
  demuxer that has read 30 s ahead loads the playlist no more until playback catches up), how far behind the edge the
  picture is, and where "go live" lands. The edge is the clock plus the greatest `end - clock` the loads of the last minute told, not the
  last load's end plus the time since: a playlist grows in steps of a segment (5 s at YouTube), loaded whenever the
  demuxer reads, and the last load's edge made the distance behind it, constant while playing, jump by a segment. The
  start stays while the playlist grows from the stream's beginning (YouTube lists all of it up to an hour, `34:05` of
  a stream 34 minutes old), and moves with the clock once it slides. A minute of samples, so that a stall of the source
  does not leave the edge ahead of the real one for good (the badge grey). During a stall the distance behind the edge
  grows with the clock, on purpose: a source that stopped looks like a paused picture near the edge whose read-ahead is
  full (both read nothing more, the playlist loads unchanged), and a distance that stood would be wrong for the latter.
  `PlayerEngine` feeds it at every tick (`trackLiveWindow`) and
  resets it with the media. The timeline stays in the stream's own timestamps (an hour into a broadcast, not zero): the
  UI maps them onto the window.
- **Start and seeks.** A live stream starts `edgeMargin` (6 s) behind the edge, whatever the requested or saved start.
  Seeks go through `clampedSeekTarget` into the window: `startMargin` (10 s) after its start, as the oldest segments
  expire from the server while they are fetched, and `edgeMargin` before its end. A picture whose place has expired
  from the playlist (a long pause) is brought back into the window by the tick. The repeats of a key held at an end are
  one seek, though the end moves with the clock while it goes: a `ChaseTarget` remembers the end its target was cut to
  (`bound`), and a press cut to the same end does not start the seek over; a skip that stops short of the edge is not
  one to the edge, however near. (The seek lands where the edge was when it began, up to as far behind as it took.)
- **The read at the edge waits.** FFmpeg's HLS demuxer sleeps inside `av_read_frame` until the playlist lists a new
  segment, holding `lock`; a seek would wait for it (up to a segment, for a stalled stream forever). `seek` of a live
  stream takes the lock as `lockIO(yielding: true)`, which asks the interrupt context to `yieldIO()` while it waits: the
  callback interrupts the read, which the read-ahead thread does not take for an end of the input (it steps aside), and
  the seek repositions what it left. Only a seek yields: the read-ahead goes on from an interrupted read in a state only a
  seek puts right. The HLS
  requests of `HTTPSessionTransport` poll the same (`shouldInterruptFFmpeg`), so that a read waiting for a segment's
  answer gives way too, not only one sleeping between loads of the playlist.
- **Reading that stops.** The read-ahead ends on an error or an end of input, as for any source, and only a seek starts
  it again. A live stream has no end it can hold for (a playlist that fails to load for good, a server error, spends
  FFmpeg's `max_reload`), so `trackLiveWindow` seeks to the picture's place to read again when the demuxer has stopped
  and what it read is played (`LiveStream.shouldRecoverReading`: ever less often, 5 s to 30 s, for as long as it lasts). A picture
  whose place expired from the window is brought back the same way, at most every 15 s (a window of a few segments
  moves past every seek's landing before it prerolls).
- **UI.** The timeline spans the window; the time at its left is the distance behind the edge; `LiveBadge` beside it is
  red at the edge and grey behind it, where a click seeks to the edge (`seekToLiveEdge()`). No thumbnails.

**A live stream's history as segments** (`ResolvedMedia.liveHistory`; the app's setting `AppSettings.liveHistory`, on, `--no-live-history` turns it off). YouTube's
HLS playlist holds an hour at most (30 s where the broadcaster has no DVR), but the adaptive formats of a live stream are
numbered segments of one URL (`…&sq=N`) the server keeps for days. The resolver builds a manifest of them
(`SegmentedDASHManifest`, `YouTubeLiveHistory`) and tells the demuxer, with `LiveHistory`, where the stream's time stands.

- **The window is the resolver's.** The format context has no playlist to read it from, so the demuxer publishes the
  window it was told (`LiveWindow(start: 0, end:, hasSlid: true)`, never read from the context: `publishLiveWindow`
  would find no `hls_live` tag and call the stream ended), and plays the media as live (`isLive`, no duration). The
  manifest stays a static one: FFmpeg's DASH demuxer does not seek a `dynamic` MPD, starts it a minute before its end and
  reloads it from its address.
- **The timeline is rebased to zero** (`timelineOrigin` = the first segment's start, as for MPEG-TS and HLS), and
  `MediaInfo.timelineOrigin` keeps the stream's time at that zero. A position is saved in the stream's time (time plus
  origin): the window's start moves between runs, the stream's time does not.
- **Times of segments are read from the segments** (`FragmentStartTime`, the `tfdt` in the first 2 KB of a ranged
  request): their lengths are not one (mostly 5 s, runs of 4.933 s, the odd 1.667 s). The manifest has the length that
  fits two segments whose times were read, an hour apart (`SegmentedDASHManifest.window(through:…)`), so a seek lands
  within seconds of its target, on the segment's keyframe. Every run says where it starts (`t=`), from the exact lengths:
  the demuxer adds up lengths in whole milliseconds, up to half of one off in each segment, which is a third of a second
  over a run of an hour and would pile up over a day of runs. `SegmentTimeSearch.oldestAvailable` finds the first segment the server still has.
- **The picture is H.264 in MP4, up to 1080p60 and SDR, on purpose, and that is what HLS gives too.** The times of
  segments are read from the `moof` of an MP4 (`FragmentStartTime`), which a WebM (VP9, YouTube's 1440p and 2160p) has
  none of, and AV1 in MP4 is more than a software decoder does at 4K60. Measured on seven live streams called 4K or HDR
  (2026-11-07): the HLS playlist of every one ended at 1080p (or 1014p) in H.264 and SDR; their segments hold 2160p in
  VP9 (SDR), and on one in AV1 with HDR10. So the history loses nothing against HLS, and 4K / HDR of a live stream is a
  gain to be had (`docs/OPEN_ISSUES.md`). The sound is the same (the 144 kbit/s AAC, itag 140, which HLS's "high" is made
  of, by its address).
- **Depth is a day** (`YouTubeLiveHistory.maxHistory`) on purpose: the server's edge answers 404, 500 and 503 for seconds
  per request, finding it cost 41 s of start on NASA's stream, and a day is as deep as the web player's DVR.
- **FFmpeg's DASH demuxer is patched to return an error when it is interrupted**
  (`scripts/patches/ffmpeg-dashdec-interrupt.patch`; its build says `nits-dash-interrupt` in its version, and the tests
  that interrupt a DASH read check it). Unpatched, `dash_read_packet` returns 0, "a packet read", from a read that was
  interrupted before it read one, and libavformat reads again for as long as the interrupt lasts: at 100% of a core,
  holding the input. A seek that interrupted the read only lets go of the interrupt once it has the input (a live-lock:
  three runs in four, within 150 seeks). So the seek of a live history yields as HLS's does (`lockIO(yielding:)`). A
  cancel (a stop, a load that replaces the media) goes through the same callback, but a read cut short inside a segment
  ends with an error, and the loop needs the interrupt between two segments: none of 400 cancels at random moments (150 in the test)
  looped on the unpatched library (`cancelsAReadAtAnyMoment` holds the patched one to it).
- **The head is followed by waiting** (`LiveSegmentGate`, in `FFmpegIOByteCounter`'s `io_open`). The manifest, static, goes
  on a day past the head (`YouTubeLiveHistory.futureSegments`), and names a stream by a key, never by its signed address
  (`https://live.nits.invalid/<format id>?sq=N`, `LiveHistory.streamAddress`): the gate asks the source
  (`LiveSegmentSource`, YouTube's is `YouTubeLiveSource`) for the real address of each, so the signature, which expires in
  about six hours, is renewed in one place: ahead of its `expire` by a margin (yt-dlp is asked for the page again), and
  at once when a segment is refused (403, once). A segment past the newest known to have been read is waited for, not
  failed: YouTube holds the request for the next two or three until they exist and answers the ones beyond with 204 after
  7.5 s (404, 5xx and timeouts happen too), and FFmpeg's DASH demuxer takes any failure for a segment to skip. A skip is a
  hole in the time of that stream, not a shift of it (the next segment carries its own timestamps; the other stream goes
  on, so picture and sound stay together; `skipsASegmentThatFails`), but of a picture that stands, not one to make of a
  segment that is merely late. So a failure of one past the head is retried every 250 ms while the stream is alive:
  - the head is asked for every `headPollInterval` (a request without `sq`, whose answers all carry `X-Head-Seqnum` and
    `X-Head-Time-Millis`); a segment the head says is there and the server does not give is left to the demuxer after
    `reportedSegmentGrace` (seconds, a few lengths of a segment);
  - when the head stood still for `segmentWaitLimit` (a minute), **the source decides whether the stream is over**
    (`LiveSegmentSource.hasEnded`; YouTube's asks yt-dlp for the page, `is_live`, as the player knows it): over, the window
    is published with `hasEnded` and every request past the last segment fails at once, which the demuxer takes for the
    end of its input and `LiveStream` for a recording; still on the air (an encoder restarting, a source gone silent), the
    wait goes on with no limit, asked again after another limit; no answer: with the server answering (any answer, a refusal without a head too: it is there) and its head
    standing, a few asks more and it is the end (yt-dlp fails on a page whose stream is gone, "recording is not
    available"); with the server not answering either, it is the network, and the wait goes on with no limit. So the only
    segment a gate gives the demuxer to skip is the one the head reports and the server does not give.
  A segment the CDN **redirects** is followed (`HTTPSessionTransport.open(followsRedirects:)`, for the gate's requests
  only: the address of a segment is whole, where an HLS playlist's relative addresses are resolved by FFmpeg against where
  it was served from, so those redirects stay FFmpeg's): YouTube's 4K tier (itag 401, AV1) is on another server, and a
  CDN may do it to any segment. A refusal from where a redirect led (403) renews the signature as any other.
  A failure of a segment up to the head (expired, a seek far back) is a failure at once. The wait gives way to a seek or a
  close within 10 ms (`shouldAbort`, the demuxer's yield). Measured on a real stream (Sky News, 1080p60): four minutes
  through the edge in real time, the longest gap 5.1 s (a segment's length), two renewals of the signature meanwhile with
  nothing noticed.
- **The last frame or two of a stream that ended are lost.** The end is a segment that fails to open, found by the stream
  the DASH demuxer reads first (the one whose time is behind, mostly the sound): its failed reopen ends everything, and
  what the other holds of its last segment, a frame in decode order, is not read. A clean end by the timeline does not
  do it. Of no consequence for a recording after the end of a broadcast.
- **The position is kept in the stream's time** (`MediaInfo.timelineOrigin` plus the engine's), not the window's, whose
  start moves between runs, and shared with the recording that follows the stream (the same history key, `youtube:<id>`).
  `saveCurrentPlaybackProgress` saves it for a live history, which has no duration (`PlaybackRecord.duration` is how long
  the stream was then: the window's end in the stream's time, a lower bound), and with it the speed and the other
  preferences. On the air it is not "watched to the end": `PlaybackRecord.wasAtLiveEdge` says whether it was left within
  `LiveStream.edgeTolerance` of the edge. A load starts a live history where it was left (`LiveStream.resumeTarget`) if it
  was not at the edge and the window still holds it (a margin after its start, before the edge), else at the edge as
  every live stream does. Once the stream ended it is judged as any recording: a position at its end starts over.
  Not verified on a real stream: that the recording YouTube makes of a broadcast counts its time from the stream's
  start, as the segments do (a position saved on the air would then resume at the same moment of the recording).

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

The common case doesn't trip that check. When the Mac doesn't own the AirPods at the start (automatic switching;
they last played for an iPhone), the device first runs its IO on a placeholder: the audio queue starts in ~0.1 s
instead of ~0.3–0.7 s, and the clock goes. About 0.1 s later the device switches to its real A2DP stream, stopping
its IO for ~0.6 s. The queue stays behind by 0.3–0.6 s (the amount varies per start) while the clock doesn't leap
and the feeder still waits about a second ahead, so neither dropped frames nor `pendingStart` show it. The device's
own state does: `AudioOutputRoute` reports `kAudioDevicePropertyDeviceIsRunning`, and
`AudioOutputInterruptionDetector` counts an IO stop under the started clock of a run that began after the clock
started and lasted 50 ms or more. Whether the clock is moving yet tells nothing (the synchronizer can hold it after
the queue started); healthy starts that restart the IO stop it within ~10 ms, while the queue start still waits,
and the placeholder switch comes 100–300 ms in. The engine's own stops (pause, seek, track switch, buffering) stop
the clock first; a renderer flush under the running clock (an audio delay change, a new output device) restarts the
queue and the device's IO with it, so `BufferTrackingAudioSink` reports every flush and the current run no longer
counts. The device is shared, so a run that began before the clock started (the previous media's queue, another
player's) doesn't count either; a device already running for another client and restarted by it is left to the
check above, and so is a new output device's run under way when it is switched to; the route drops a previous
device's events still queued after the switch. Once the device runs again,
the main actor re-anchors the clock the same way, at most once every 5 s, and only if the clock hasn't been stopped
or re-anchored since (a clock generation the detector bumps). The notifications arrive on a queue of the route's
own, never the main one: `setRate` on the main thread can wait for the queue to start, and the start for the HAL to
deliver them, which deadlocked for 15 s with a main-queue listener.

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
player window's behaviour around PiP (the settings in `AppSettings`: hiding the window, pausing,
entering PiP on minimize, and the workarounds for restoring from the Dock) is
`PictureInPictureWindowCoordinator`'s, which owns the controller and gets the window's events from
`PlayerWindowController`. The private `PIP.framework` (IINA, VLC) was rejected: it would show any view (Metal
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
  `updateShown(at:)` looks up each time tick (20 Hz) with the track's own subtitle delay applied:
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
  chosen, a load with a start time or a seek has landed (once, not per scrub step), and the track's subtitle delay changes.
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
- **Network files** (`MediaLoadRequest.SubtitleFile`: a host's, a resolved page's such as yt-dlp's, or a URL added
  with `addExternal`) are listed on load with the title, language and flags they come with, and downloaded only when
  their track is selected (`RemoteSubtitle`, off the main actor): with their own headers, else the request's; one added
  by hand gets none, as it may be on another host. A download is tried again once only for a network error or a 5xx,
  stops past 20 MB, and a body with no cue (an error page answered with 200) is no document. SRT, WebVTT and ASS are
  parsed here, MicroDVD, SubViewer and SAMI by FFmpeg (`FFmpegTextSubtitles.read(data:of:)`), also for a URL whose
  extension doesn't tell, when the text isn't SRT; bitmap files over the network aren't listed. The documents
  downloaded are kept by URL past the load's reset (`remoteDocumentCache`), so switching a page's video format shows
  the track again without a download; `stop()` drops them.
- **Second track** (`SecondarySubtitles`, held by `SubtitleController`): a track shown at the top as plain text with
  the selected one at the bottom (`textCues` normalizes the selected cues' alignment while it is on, and libass is off
  for an ASS main track, which places its dialogue itself). Unlike the selected track it is read whole in the
  background when chosen (`documentReader(for:)`; an embedded one over the network is refused, as it means every
  byte of the media), and given up if the read fails. Text only, never pictures or closed captions. Its cue ids are
  negated so the overlay tells the two tracks' cues apart; `onCuesChanged` still reports the selected track only.
- **Per-track state**: the delay, the text encoding and the second track are saved for the file by
  `SubtitleTrack.persistenceKey` (the stream, the file's path and stream, or a network file's language, title and kind;
  `SubtitleController.key(of:)` tells identical ones apart by order), as ids don't hold between loads. An encoding is
  the file's own choice (`setEncoding(_:ofTrack:)`), over the default of Settings (`setDefaultEncoding`); files read
  before the load is applied get it through `MediaSubtitleFiles.Lookup.fileEncodings`. Reads in an encoding since
  replaced are dropped (`readGenerations`).
- **Track flags**: forced and SDH come from the stream's disposition, or from its title; an external file's from its
  name, or what its request says. Auto-generated captions (`isAutoGenerated`: yt-dlp's `automatic_captions`, without
  machine translations) rank after written tracks of the same language, and only their WebVTT has its roll-up
  collapsed (`parseWebVTT(collapsingRollUp:)`: YouTube's speech recognition repeats the previous cue's last line at
  the top of the next, through 10 ms cues that hold it alone). `TrackAutoSelection` picks a local file as a file put
  there to be shown (`isSidecar`), a network one as one of the media's streams. History saves a local file by path and
  stream, which tells apart the languages of a VobSub index, and a network one by language, title and kind
  (`ListedSubtitle`), as its URL may expire (a signed one) and its track id follows the page's order: the track of the
  same title, else the first of the language and kind; one with no language only by its title.
- **Dependencies**: libass, FreeType, HarfBuzz, FriBidi and libunibreak are built by `scripts/build_dependencies.sh`
  with FFmpeg and ship as dylibs; `CLibass` is the system library target.

## Metal tone-mapper (`HDRToneMapping.metal`)

- **Input** — biplanar YCbCr: `r16Unorm` luma + `rg16Unorm` chroma for 10-bit (VideoToolbox
  MSB-aligns P010, so range limits are expressed on the 16-bit scale, e.g. `4096/65535`,
  `56064/65535`), and an 8-bit path. Full/video range comes from the format description.
- **Pipeline** — PQ (ST 2084) inverse EOTF → linear nits → BT.2390 black level lift
  (`liftBlackLevel`) → BT.2390 EETF compressed to `targetNits` → BT.2020 → Display P3 (D65), fit at constant Oklab
  lightness and hue (`fitToDisplayP3`, `DisplayGamutFit.metal`, ToneLab's `oklab_gamut_fit`: clipping each channel
  turned a sunset's orange outside P3 towards yellow, up to ~17° with mpv's curve) → sRGB encoding, the layer's
  transfer: macOS decodes it and maps it to the display, so the
  luminance the curve gives is the one shown. (A pure gamma 2.2 encoding read as sRGB lifted the shadows
  by up to 8× at 0.02 % of white, which hid a white and a black level that were both off.)
- **Tone curve** (`mpvBT2390`, `BT2390ToneMapping.metal`, LGPL) — mpv's BT.2390 EETF on max(RGB), with its
  desaturation of bright colours: a saturated colour keeps its saturation and is darkened for it. A curve on luminance
  (a blend of Y and a smooth max(RGB), with its own gamut compression) and libplacebo's on cone LMS were tried against
  the XDR stills and dropped. Both matched mpv's below the knee; in highlights the luminance curve let saturated colours
  keep their brightness and wash out towards white (a sun's glow, 0.67–0.78 of XDR's Oklab C/L on sunsets against mpv's
  ~0.88, mean ΔE 7.59 against 7.50), and libplacebo's left bright areas darker than XDR (0.77 of its luminance just under
  SDR white, against ~0.81). The hue shift that once argued against mpv's curve on sunsets came from clipping each
  channel to P3, which the Oklab fit after it replaced.
- **Reference white** (`targetNits`, `ToneMapController`) — set by the title's static peak and the frame's average
  brightness (`measuredTargetNits`): max(100 + 17 ln(peak / 451), 80 + 65 (1 − e^(−avg / 12))), ~100 to ~150 nits. The
  average is measured on the frame itself (`FrameLuminanceMeter`: the PQ mean of max(RGB), as Dolby Vision's L1
  average, on a 64×36 grid on the CPU, so the frame drawn gets its own white with no GPU readback delay), smoothed
  between frames but for scene refreshes and cuts (a jump of more than 3 % PQ). Fitted for the least ΔE_ITP against
  the XDR presentation of 45 scenes of four titles (stills of the screen, ⌘S under `.system`, both relative to SDR
  white): the presentation sets a title's white by its MaxCLL (a dark scene's ~100 nits at MaxCLL 451, ~115 at ~1000,
  ~150 at 8154) and raises it for bright scenes; the scene's peak doesn't predict it (L1 max said 300 nits for a scene
  whose frame peaked at 123 and wanted ~110), and L1's own average is static in some Dolby Vision 8.1 encodes, so the
  frame is measured for every HDR source. Mean ΔE 9.6, against 9.3 for each scene's best white. Never below 100 nits,
  the user's scale (`targetNitsScale`) included. Before a frame is measured, and for SDR, the static white (`referenceWhiteNits`,
  `adaptiveTargetNits`) and the scene's peak set it. Known limit: the average takes the whole frame, letterbox bars
  included, so a letterboxed film gets a lower white (a brighter picture) than the same film without bars. The fit can't
  settle it: its one letterboxed title (2.39:1 in 16:9) has a static L1, and XDR keeps its white at ~100 nits in every
  scene. With its bars counted, the average's term stays under its title's (100) and the rule gives that 100 by
  accident; leaving black out (libplacebo's `black_cutoff`, or only the bars) lifts the average term over it, the white
  to 110–137 and its mean ΔE from 3.9 to 7.9. Checked out of sample on a second letterboxed title (23 XDR stills, also
  a static L1 avg): bars left out, mean ΔE 8.7 → 12.3. So the whole frame stays, but both titles have a static L1
  average, where XDR keeps the white near the title's; letterboxed titles with a dynamic L1, and HDR10 ones, are
  untested.
- **Local contrast** (`ContrastRecovery`, `applyContrastRecovery`) — BT.2390's shoulder ends with slope 0, so the
  brightest part of a frame (a hazy sky, a lit shirt) loses its texture: the far ridges of a desert at 250–340 nits
  landed within a few percent of white. The curve maps a low-pass of the PQ intensity, and half of the detail above
  it is added back unmapped (base / detail decomposition, as libplacebo's `contrast_recovery`). The low-pass is a
  guided filter of the intensity by itself, which keeps edges: a Gaussian left bright halos around mountains against
  the sky. Its coefficients are computed on the GPU at a quarter of the frame's size before the frame is drawn
  (statistics, MPS box filters, radius 1/60 of the width) and applied per pixel at full resolution. The low-pass is
  mapped in the pixel's own colour, not as a grey: the curve, on max(RGB), compresses a saturated colour more than a
  grey of its luminance, so a grey base came out brighter than the pixel and lifted whole hazy areas (the far ridges
  washed out) instead of adding their detail. Brightening stops where the brightest channel reaches white, so the colour keeps its hue and
  saturation: clipped per channel, a sun's red stopped while green and blue rose, and it went yellow-white. Changing the
  curve's shape instead (a lower knee, a slope at the peak, headroom above it) only moved the contrast from one part
  of the highlights to another and moved the picture away from XDR. Against the XDR stills: mean ΔE_ITP 7.73 → 7.50,
  fine detail in highlights 65 % → 73 % of the XDR picture's. Stills (⌘S) compute it for their own frame. The
  strength is the user's (`ToneMapController.localContrast`, Settings / Quick Settings / `--local-contrast`, default
  the fitted 0.5); 0 skips the GPU passes.
- **Scene luminance** — the demuxer reads each HEVC and AV1 packet's dynamic metadata into `FrameHDRMetadata`, which
  rides the sample buffer (`FrameHDRMetadataBox`) through the decoders and `FrameQueue` to
  `ToneMapController.applyFrame`: the Dolby Vision RPU (NAL unit 62) and HDR10+ (SMPTE ST 2094-40: a T.35 message, in
  an HEVC prefix SEI or an AV1 metadata OBU, decoded by FFmpeg's `av_dynamic_hdr_plus_from_t35`, `HDR10PlusParser`). Both give the scene's peak, which the curve maps from instead
  of the whole title's MaxCLL, so a scene's highlights aren't compressed for a peak it doesn't have. L1 is smoothed
  between frames but for a scene refresh; HDR10+ holds per scene and changes at cuts, so it is taken as is. The curve's
  peak is never below the frame's own, as `FrameLuminanceMeter` measures it with the average (its brightest sample,
  smoothed with the average): L1 max is under-reported in some Dolby Vision encodes (Apple's Profile 5 demo changes it
  every six frames inside a shot, 316 nits for a frame whose sky reaches 630), and everything above the curve's peak
  is white. libplacebo does the same (`scene_max` raises `input_max`). Neutral against the XDR stills (mean ΔE 7.50
  either way): where L1 is honest the grid's brightest sample rarely exceeds it.
- **Thumbnails** (`ThumbnailToneMapper`) are tone-mapped on the CPU the same way: each keyframe's packet metadata
  (`FrameHDRMetadata`) gives the scene's peak and white (`ToneMapController.sceneTargetNits`), the BT.2390 black lift
  and sRGB encoding follow, a Profile 5 frame is composed with its RPU's curves and matrices
  (`DolbyVisionPixelReshaping`, the shader's formulas), and a shoulder of their own brings the scene's peak to white
  in place of BT.2390's knee.
- **Black level** — the BT.2390 lift towards a display black of 0.06 % of white (`displayBlackToWhite`): a dark
  scene's shadows sit above it as on XDR, which a pure power curve crushes. mpv does the same with
  `--target-contrast` (1000:1 for SDR by default). The lift goes on each channel, which takes chroma from dark colours
  as the XDR presentation does; a lift on luminance that kept the chromaticity left the shadows 1.2 to 1.7× more
  saturated than XDR stills of the same frames. Thumbnails lift the same way.
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

### Video formats of a page

A resolved page (yt-dlp) may offer its pictures as files of their own (`ResolvedMedia.videoFormats`, the progressive
HTTP(S) formats of the kind `-f` chose, the best bitrate per size, frame rate and codec). Unlike an HLS variant, a
format is another input, not other streams of the one open, so switching (`PlayerEngine.selectVideoFormat`) loads the
media again: `resolvedSource` keeps the page as resolved and the request that asked, and the load reruns from them
(`loadAsyncKeepingHostState(preResolved:)`, the resolver not asked again: its answer is slow, the URLs live hours),
at `rereadPosition`, paused if it was, with the audio and subtitle tracks the viewer chose (the subtitles' documents
downloaded already are reused, `remoteDocumentCache`). The audio files open again with it,
so playback stops for the time they and the picture take to open. There is no automatic choice: the network is not
the bottleneck of progressive files read in chunks, and "default" is what yt-dlp chose.

### Audio from another input

An audio track can come from a file of its own (a dub next to the video; a host's or a resolved page's separate audio,
`MediaLoadRequest.audioFiles`, opened with the media, read with its own headers or else the request's, and listed with
the title and language the request gives). A network one that doesn't open is tried twice more; one that still
doesn't is left out, unless it is the media's own sound (`isRequired`, a page's audio apart from a picture without
any), which fails the load rather than play it silent. `PlaybackInputs` holds the media's demuxer (`main`: picture,
subtitles, variants) and a demuxer per added file, opened `audioOnly`, and lists the tracks of all of them (a file's
from `firstExternalTrackId` on). The selected track's demuxer is the `audioSource` audio feeding reads; while a file's
plays, the media's demuxer has none selected (`selectAudioTrack(trackId: nil)`) and drops its own audio as it reads. Each demuxer keeps its own locks and
read-ahead thread and none is taken while another's is held, so a second input adds no lock order; a file starts
reading ahead on its first selection and reads nothing while none of its tracks is selected.

- **Declared files**: a file that holds one stream the host knows (`AudioFile.declaredStream`, which yt-dlp's
  formats give for each language of a dubbed video) isn't opened with the media: `declareExternalAudio` lists its track
  from the declaration and the demuxer is `nil` until the track is selected. The engine opens it then
  (`PlaybackInputs.openExternalAudio`, with the headers and request size declared) and switches when it is open,
  meanwhile the track playing stays heard (`awaitedAudioTrackId` drops the switch if another track is chosen). The track
  to start with is decided before the media is applied (`unopenedFileToStartWith`, the same choice as
  `selectAudioTrackOnLoad`), and its file opened first. A file that is `isRequired` is opened with the media regardless.
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
