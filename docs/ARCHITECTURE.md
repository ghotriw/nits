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
- The engine has no notion of an OSD or a HUD: what is shown is the host's (`OSDManager.isEnabled`,
  `PlayerUIState.isDebugHUDVisible` in `NitsUI`). It only refreshes `currentMetrics` twice a second while asked
  (`isCollectingMetrics`, `PlayerMetricsCollecting`); no timer runs otherwise.
- `bufferedTime` is the furthest timestamp the demuxer has read (`MediaDemuxer.readAheadSeconds`, behind its own
  lock because the demuxer lock is held through blocking network reads): for a network source, up to the
  read-ahead limit (see "Network read-ahead"); for a local file, the few seconds the feeders asked for.
- The demuxer accepts HTTP/HTTPS/HLS URLs with custom headers (`X-Emby-Token`, `Authorization`,
  User-Agent, cookies) passed as FFmpeg `AVDictionary` options.
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
  (Deno, for YouTube). Its formats exclude DASH, which the bundled FFmpeg can't demux; HLS opens from its master
  playlist (`manifest_url`), for its variants and adaptive bitrate. Progressive files are read in HTTP requests of
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
seek's. A target at or past the end lands on the last frame: a held arrow key never goes back. Landing at the end ends
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
- **Network files** (`MediaLoadRequest.SubtitleFile`: a host's, a resolved page's such as yt-dlp's, or a URL added
  with `addExternal`) are listed on load with the title, language and flags they come with, and downloaded only when
  their track is selected (`RemoteSubtitle`, off the main actor): with their own headers, else the request's; one added
  by hand gets none, as it may be on another host. A download is tried again once only for a network error or a 5xx,
  stops past 20 MB, and a body with no cue (an error page answered with 200) is no document. SRT, WebVTT and ASS are
  parsed here, MicroDVD, SubViewer and SAMI by FFmpeg (`FFmpegTextSubtitles.read(data:of:)`), also for a URL whose
  extension doesn't tell, when the text isn't SRT; bitmap files over the network aren't listed. The documents
  downloaded are kept by URL past the load's reset (`remoteDocumentCache`), so switching a page's video format shows
  the track again without a download; `stop()` drops them.
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
