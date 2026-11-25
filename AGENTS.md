# Nits — Agent Guide

Nits is an HDR / Dolby Vision video player for macOS (and, in v1, a bare-controls player for iPhone and iPad): custom Metal tone-mapping on SDR displays,
native `AVSampleBufferDisplayLayer` presentation on XDR displays (on iOS always the latter). Design background and the
reasoning behind the invariants below: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); the HLS client and adaptive
bitrate (design, decisions turned down, measurements, open work): [`docs/HLS.md`](docs/HLS.md).

## Environment

- Build host / SDK: macOS 27, Apple Silicon. Deployment targets: macOS 15.4, iOS 18.4 (iPhone and iPad; the iOS frameworks are arm64).
- macOS 27 is the real, current OS — treat its SDK deprecation warnings as actionable. Fix them
  with replacement APIs that work on 15.4+ rather than suppressing them.
- Swift 6, strict concurrency (`-strict-concurrency=complete`), `ExistentialAny`.

## Tools & references

- **apple-docs MCP** (if available): before using or replacing an AppKit, SwiftUI, AVFoundation,
  Metal or CoreMedia API, check its availability and deprecation status
  (`get_platform_compatibility`) — Apple APIs change faster than training data.
- **`.ref/`** — reference implementations and third-party sources for algorithms, format parsing,
  shader math and pipeline behaviour. Adapt, don't copy: results must follow the rules below.
  Nits is Apache-2.0, so licenses limit what may enter `Sources/` (ideas and behaviour are always fine):
  - GPL: never port code, not even translated.
  - LGPL (`mpv`, `ffmpeg`, `gstreamer`): only into a separate file with an LGPL-2.1-or-later
    header and attribution, listed in `THIRD_PARTY_NOTICES.md` (see `BT2390ToneMapping.metal`).
  - MIT/BSD (`SwiftPlayer`): keep the copyright notice in `THIRD_PARTY_NOTICES.md`.
  Prefer implementing from the spec (ITU-R, SMPTE, Apple docs) over porting.

## Commands

- Build: `swift build`
- Strict type-check incl. tests: `./scripts/format.sh typecheck`
- iOS type-check: `./scripts/format.sh typecheck-ios` (NitsCore, NitsTouchKit and NitsTouchUI for the simulator, `ARCHS=arm64`; `check` runs it). The iOS
  app (`Apps/iOS`, an XcodeGen project: `brew install xcodegen`; the project itself is generated and ignored):
  `./scripts/build_ios.sh [generate|simulator|run|device|ipa|test]` (`run` builds, installs and launches on a simulator, `--destination=` with `id=` or `name=`, else a booted iPhone, else the first available; `device` is signed with `DEVELOPMENT_TEAM`, else unsigned; `ipa` makes an unsigned `build/ios/Nits.ipa` (and its dSYM) for SideStore; `test`
  runs `Apps/iOS/NitsTouch.xctestplan`: `NitsStreamingTests` + `NitsTouchKitTests` + `NitsTouchUITests` only, never the `Nits-Package` scheme). The scheme
  is `NitsiOS` (the name `Nits` is the package's macOS executable). The iOS FFmpeg / dav1d are xcframeworks that SwiftPM
  downloads (`binaryTarget(url:checksum:)`, the pre-release `deps-ios-v*`): they are built and published only by the
  "Build and Release iOS Dependencies" workflow, whose report gives the checksums for `Package.swift` (`DEPS_IOS_VERSION` in
  `scripts/deps_config.sh`); `make_xcframeworks.sh --zip` locally is for checks only.
- Format / lint: `./scripts/format.sh` / `./scripts/format.sh lint` (pre-push runs `check`)
- Tests: `swift test`; after touching seek, decoding, audio or track switching also run
  `swift test --filter PlaybackStressTests`.
- App bundle: `./scripts/bundle_app.sh` — embeds the LGPL FFmpeg / dav1d and libass (with FreeType, HarfBuzz, FriBidi, libunibreak) from
  `scripts/setup_dependencies.sh` (versions, flags and the release checksum live in
  `scripts/deps_config.sh`; bump `DEPS_VERSION` when changing them). `format.sh` and CI build and
  test against `.build/dependencies` when present, otherwise SwiftPM falls back to Homebrew FFmpeg.
  SwiftPM links with the deployment target (15.4) as the SDK version, so `swift run` binaries show
  the legacy (pre-Liquid Glass) look on macOS 26+; `bundle_app.sh` stamps the real SDK via `vtool`.
  Judge UI only from the bundle. SwiftUI previews: open `Package.swift` in Xcode with the `NitsUIPreviews` scheme.
- Releases: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`. The app version comes
  only from tags (`bundle_app.sh` / `build_ios.sh`: `git describe` or `--version=`), so never hardcode it in
  Info.plist or sources. `scripts/release.sh` works the next version out from the commits since the last tag and
  writes the release notes into the tag's message, which `release.yml` publishes. One version for the package and both
  apps, but a release builds only the apps its commits change: `release.sh` tells them from the files
  (`platform_of`; a new platform-only path goes there) and ends the tag's message with `Platforms: macos ios`, which
  `release.yml` reads (Nits.app zip, unsigned `.ipa` and its dSYM). An app left out skips that version.
- Commit subjects are Conventional Commits (`type(scope): description`; `.githooks/commit-msg` checks them), as the
  version is counted from them: mark a change that breaks the public API (`NitsCore`, `NitsKit`, `NitsUI`,
  `NitsTouchKit`, `NitsTouchUI`, `NitsYTDLP` as hosts use them) with `!` before the colon and a `BREAKING CHANGE: …` paragraph saying what a host has to change.
- Run compilers and CLI tools directly. Don't use inline interpreter scripts (`python3 -c`,
  `node -e`, `ruby -e`, `perl -e`) or wrap tools in `subprocess`; if a helper script is needed,
  write it to a file (e.g. `.agents/scratch/`), run it, then delete it.

## API choices

| Don't use | Use instead |
|---|---|
| `CVDisplayLink` | `CADisplayLink` via `view.displayLink(target:selector:)` / `screen.displayLink(...)` |
| `NSLock` | `OSAllocatedUnfairLock` |
| `Thread.sleep` on GCD/worker threads | `Task.sleep` / cooperative exit |
| `ObservableObject` / `@Published` | `@Observable` |
| `NSApp.activate(ignoringOtherApps:)` | `NSApp.activate()` |
| `isFocused = true` in `.onAppear` | `.defaultFocus(_:_:)` + `window.initialFirstResponder = hostingView` |
| `Unmanaged.toOpaque()` C callbacks | Swift closures / concurrency |
| Allocating objects in SwiftUI computed properties | `@State` or an owning controller |
| A closure as a lock's bare state (`OSAllocatedUnfairLock<(@Sendable (T) -> Void)?>`, a closure typealias too) | The closure in a struct (`StreamingLane.ProgressObserverSlot`): every `withLock` read wraps a bare one in two more thunks, until a long run overflows the stack |

The intentional exceptions: display-layer `enqueueSampleBuffer:` / `flush` go through cached
selectors (see Video pipeline); FFmpeg's C callbacks on an `AVFormatContext` (`interrupt_callback`, `io_open` /
`io_close2`) take an unretained `Unmanaged` pointer, as FFmpeg has no other way to pass context
(`FFmpegInterrupt`, `FFmpegIOByteCounter`). The object must outlive the context: `FFmpegInput` holds it and closes the context first. The
`AVIOContext`s `SegmentReader` makes for each run of segments are Nits' own and read through a Swift closure.

So does blocking a thread, which FFmpeg's reads do by nature: `YouTubeLiveSource` waits for yt-dlp and the network on a
`DispatchSemaphore` (`blocking`, up to 90 s). `StreamingLane` waits for a live playlist's next segment the same way, on a
`DispatchSemaphore` in steps of 50 ms (`StreamingInput`, Nits' own HLS and DASH client). Both run on the thread of the demuxer's read (or of its opening, a pool
thread, as every FFmpeg call is), and give way to a seek or a close at once (`shouldAbort`). The opening of an HLS stream waits
the same way for the probes it starts (`ProbeRace`: a `DispatchSemaphore` in steps of 50 ms, then the probes' threads) and for the link's rate (`HTTPSessionTransport.waitForOpeningRate`, steps of 20 ms; `skipSlowStart` for a round trip's metrics, 100 ms at most), as
it already blocks its thread on the playlists and the probes side by side; its requests give way to an abort too. A DASH
manifest's playlists (`DASHPlaylists`) and the index of each of its single files are read once for every caller: those that
ask while one is read wait for it (`DASHPlaylists.Store`, a `DispatchSemaphore` in steps of 50 ms, each giving way to its own loader's abort), on the
opening's and the lanes' threads, which block on a playlist's load anyway. `YouTubeFormatSource.renewAddresses` (the
addresses of a YouTube video's manifest) waits the same way on a request's thread: for a fresh signature to settle (the CDN refuses
it for its first seconds; up to 5 s, after a renewal too), a `DispatchSemaphore` in steps of 50 ms giving way to `shouldAbort`, and for a renewal it reuses
`YouTubeLiveSource.blocking` (yt-dlp, up to 90 s). A lane waits out a failure of the network the same way before it asks for
the segment again (`StreamingLane.waitForNetwork`, up to 5 s a wait, on the read's thread, giving way to `shouldAbort` and to the
lane being given up). Not a pattern for other code.

## Layer boundaries

- `NitsCore` (engine) never imports SwiftUI or knows about views. `PlayerEngine` is `@Observable`
  and `@MainActor`; UI observes it directly, no wrapper view-models.
- `NitsStreaming` is the HTTP adaptive streaming client for HLS and DASH (`Sources/NitsStreaming/`: `Client/` the format-free
  engine, `HLS/` and `DASH/` the reading of each format) and knows nothing of `NitsCore`. Its whole API is `package`,
  and only `NitsCore` imports it, as `internal import NitsStreaming` (never `public`, never re-exported): a host, `NitsUI` and
  `NitsKit` reach the client through `NitsCore`'s public API. SwiftPM would let any target that depends on `NitsCore`
  import it too, so `./scripts/format.sh lint` allows the import only in `NitsCore`, `NitsStreaming` and tests. What
  `NitsCore` tells the client it tells in the client's own types, converted in `NitsCore` (`StreamingLiveWindow` → `LiveWindow`,
  `LiveHistory` / `LiveSegmentSource` → `StreamHistory` / `StreamHistorySource`); what the demuxer needs of an input is
  `StreamingInput+DemuxerInput.swift`. The client logs through `StreamingLog`, which is silent until `NitsCore` installs
  `AppLog` as its sink: every place of `NitsCore` that makes a client object (not only the engine: thumbnails, the duration
  probe, the subtitle reader) calls `StreamingLogBridge.install()` first. It does not hold what a resolver builds for it (`DASHManifest`,
  `SegmentedDASHManifest`, `LiveHistory`'s address helpers forward to `StreamHistory`): `NitsKit` uses those.
- `NitsYTDLP` plays the pages of video sites (YouTube, …) from what yt-dlp says of them: `YTDLPResolver`, the manifests of a
  video's files and of a live stream's history, SponsorBlock. It never runs yt-dlp: a `YTDLPRunner` does (the arguments of
  a command line in, `YTDLPOutput` out; the resolver owns the timeout, the runner only ends when cancelled). It imports
  `NitsCore` only and builds for macOS and iOS: no `Process`, no AppKit, no `NitsStreaming` (`NitsCore`'s alone). The
  macOS runner (`ProcessYTDLPRunner`, `YTDLPProcess`, `YTDLPLocator`) is `NitsKit`'s; an iOS host brings its own over
  an embedded interpreter. `./scripts/format.sh typecheck-ios` builds it.
- `NitsKit` owns windows, menus and NowPlaying. `NitsUI` is declarative views plus
  `PlayerUIState` for transient UI state.
- `NitsTouchKit` is the iOS session (the Kit's role): `TouchPlayerSession`, which owns the engine and follows the scene's
  phase (`HostScenePhase`, not SwiftUI's: the Kit has no views; `.background` and back only, `.inactive` changes nothing). Every file is in `#if os(iOS)`; it imports `NitsCore`
  only of the project's modules (never `NitsStreaming`, which `format.sh lint` enforces) and observes `PlayerEngine` directly. The test seams of the
  session are internal, not API. The engine's hooks for it are `hostDidEnterBackground()` / `hostWillEnterForeground()`;
  an iOS-only event gets an engine handler whose policy is the engine's, never `#if os` in it. `NitsUI` and `NitsKit` stay macOS-only. Now Playing and the remote commands (`TouchNowPlaying`) are a
  `PlayerSessionSink` of it, as PiP will be. `NitsTouchUI` (the UI's role) is the screen (`PlayerScreen`, the control bar, SwiftUI) over
  the session: it imports `NitsTouchKit` and `NitsCore`, and what its views need of the session that is no host API is `package`.
  The host API of `TouchPlayerSession` (`openStream`, `load(_:)`, the callbacks, action buttons, the host's queue, `close()` /
  `end()`) repeats `PlayerSession`'s names over the same `PlayerSessionCore`; going to the background writes the history
  after the engine hears of it.
- UI changes must not require changes to decoding, shaders or A/V sync.
- What does not depend on the window (the engine's callbacks, Now Playing, PiP, actions, opening media) is
  `PlayerSession`'s; `PlayerWindowController` only adds the window and is one `PlayerPresentation`. What does not depend
  on the platform (the engine's callbacks, `openStream`, `close()` / `end()`) is `PlayerSessionCore`'s (`NitsCore`,
  `package`), which `PlayerSession` and `TouchPlayerSession` hold (`ActionButtonPresenter`, in `NitsCore` for both players, is
  the one piece of when-is-it-shown policy there: no SwiftUI, no views, shared on purpose, not a precedent); a platform's parts (Now Playing, recent media, the OSD) are
  its `PlayerSessionSink`s. The engine's
  callbacks are single closures that the core owns: hosts subscribe through the session, never on `engine`. The
  unmodified keys live in `PlayerKeyRouter` (`PlayerWindow` and `PlayerKeyMonitor` both call it); NitsUI never zooms or
  moves the key window itself (`titleBarDoubleClicked` is the window's). See "Session and presentation" in `docs/ARCHITECTURE.md`.
- Keep the engine embeddable: `NativeVideoHostView` stays a bare canvas with no built-in controls;
  commands and events go through `PlayerEngineProtocol`; the demuxer must handle remote URLs with
  custom HTTP headers, not just `file://`.
- A new engine feature with state of its own (a loop, filters, a second subtitle track, recording, …) is a type
  of its own that owns that state and resets it, which `PlayerEngine` holds and calls; not new `PlayerEngine`
  properties and a new `PlayerEngine+X.swift`. What the demuxer tells about the loaded media, for the UI and
  hosts, goes in `MediaInfo` (`engine.media`), which loads and resets replace whole. Not in it: timing the display
  link reads off the main actor, behind a lock (`nominalFrameDuration`, which deinterlacing and variants also
  change, and `videoStartTimeLock`), and what the request brings (`mediaTitle`, artwork; the container's artwork
  only stands in for the request's). Per-media state that stays on `PlayerEngine` is cleared in
  `resetMediaState`, the one reset `stop()` and every load share.
- `NitsCore` builds for macOS and iOS and stays portable to tvOS: AppKit / UIKit, IOKit, the CoreAudio HAL and anything else one
  platform only has go in `Sources/NitsCore/Platform/<os>/`, implementing a protocol in `Platform/` (`VideoHost`,
  `AudioOutputRoute`, `DisplaySleepAssertion`) or repeating an interface every platform has (`PlatformScreen`); the
  engine keeps the policy (e.g. the HDR-screen threshold, from the host's EDR headroom; what an interruption, a lost route, a flush by the system or the app's going to the background owes the user). `./scripts/format.sh lint`
  enforces it, and the same for `NitsStreaming` (it builds for the same platforms). See "Platform layer" in `docs/ARCHITECTURE.md`.
- Hot loops that must run optimized in Debug too (SIMD pixel conversion, DSP) go in `NitsKernels`, the only
  target built with `-O` in Debug; keep its functions non-`@inlinable`.

## Video pipeline invariants

- **Only decoded frames reach the display layer.** Every packet goes through a
  `VideoDecoderProtocol` decoder into `FrameQueue`; never enqueue compressed NALUs to
  `AVSampleBufferDisplayLayer`. Compressed passthrough + backward seek deadlocks `WindowServer`
  under XDR fullscreen Direct Scanout.
- **The display layer is never attached to `AVSampleBufferRenderSynchronizer`.** The synchronizer
  drives audio only; the layer uses its own host-clock `controlTimebase` (rate 1.0, never paused)
  and frames carry `kCMSampleAttachmentKey_DisplayImmediately`. Attaching it makes `setRate(0)` on
  pause freeze `WindowServer` for ~30 s. For the same reason, don't "modernize" the selector-based
  `enqueueSampleBuffer:` / `flush` calls to `synchronizer.sampleBufferReceiver`.
- **Pacing** comes from `CADisplayLink`. Its rate is matched to the content
  (`preferredDisplayLinkRate`): the lowest divisor of the screen's max refresh that is ≥ 48 Hz and a whole
  multiple of the content fps, else the screen max; re-evaluated on load and screen change. Frames are picked
  for the synchronizer clock projected to `link.targetTimestamp`, never the clock at callback time, and passed
  through `DisplayClockSmoother` (jitter filter + phase lock that keeps frame boundaries off vsyncs); don't pick
  from the raw projection. Links fire on
  `DisplayLinkThread`, never the main run loop (UI stalls there dropped frames); the tick may only touch
  lock-guarded state, and display-layer enqueues / flushes go through `displayLayerLock`.
- **Seeks** run on the serial `seekQueue` with a `SeekGeneration` token; stale seeks are
  dropped. Seek and render-mode switches clear `FrameQueue` and flush decoder and renderer. A seek waits for the
  cancelled video feeder to unwind (`waitForUnwind(of:)`) before it flushes the decoder or moves the demuxer: a decode
  still in flight would emit a frame from the old position into the preview.
- **Don't tear down `VTDecompressionSession` on seek** — flush it. Before any invalidate/reset,
  call `VTDecompressionSessionWaitForAsynchronousFrames`; session, format description and output
  handler stay behind a lock.
- **Decoder calls from the video feeder and `seekQueue` go through `StallGuardedVideoDecoder`**
  (`stallGuardedDecoder(for:)`), never the bare decoder: a VideoToolbox call can block forever, and on the
  serial `seekQueue` it would hold every later seek and load. See "Stalls and buffering" in `docs/ARCHITECTURE.md`.
- **`FrameQueue`** stays a fixed-capacity ring buffer, keeps PTS order (B-frames inserted, not
  appended), and nils a slot as soon as it's popped — held `CVPixelBuffer`s starve the decoder's
  `IOSurface` pool.
- **`FFmpegVideoDecoder`** uses slice threading only: frame threading delays output by a frame per
  thread, past the few packets seek previews and frame steps decode. libdav1d and libvpx thread on their own
  (`thread_count`); dav1d keeps one frame in flight (`max_frame_delay = 1`). Frames that aren't planar 4:2:0
  go through `FrameFormatNormalizer` (libswscale); RGB sources are tagged with the matrix used, which
  `StreamColorimetry` gives RGB streams too (`isRGB(format:)`, one rule for both).
- `CV*GetStringForIntegerCodePoint` returns placeholders (e.g. "YCbCrMatrix#5") for code points
  without a CoreVideo constant; `StreamColorimetry` accepts only real constants.
- **Metal decodes colour by the stream's matrix and primaries** (`ShaderColorimetry` → `ToneMapUniforms`), in both the
  HDR and the SDR branch; never hardcode BT.2020 or BT.709 in the shader. HDR or SDR there is the transfer alone (PQ /
  HLG), not the primaries, and `MetalVideoRenderer` uses the same test.
- **Interlaced video** is deinterlaced inside the decoder (`FFmpegVideoDecoder` → `MetalDeinterlacer`), so
  every consumer of decoded frames gets progressive ones: a frame per field for streams declared interlaced,
  which the engine then paces at the field rate (`outputsFieldRate` halves `nominalFrameDuration`). The
  deinterlacer may only look back (the previous frame), never ahead: seek previews and frame steps decode just
  a few packets, so a frame of latency would lose their target. Interlaced H.264 must not go to VideoToolbox
  (Apple Silicon rejects field-coded H.264); `VideoDecoderFactory` routes it to FFmpeg.
- **Metal output** stays `.bgr10a2Unorm` / Display P3 (8-bit bands). Shader changes must stay
  NaN-free at `outputSharpness = 1.0`.
- **Concurrency**: `RenderMode` and `ToneMapUniforms` are `Sendable`; `activeRenderMode` sits behind
  an `OSAllocatedUnfairLock` and is `nonisolated` so the display link reads it without actor hops.
  UI state changed from the display link (e.g. `isMetalLayerVisible`) is set on `@MainActor`.
- **Backpressure** is cooperative: video feeding pauses at a queue high-water mark using
  `Task.sleep`; audio relies on `await audioSink.enqueue(...)` (`Receiver` on macOS 27+, readiness
  polling with `Task.sleep` on 15–26). Never block threads.
- **The frame queue's high water is `FrameQueueBudget.highWater`** (40 / 25 without `PlayerConfiguration.frameQueueByteBudget`;
  under one, the budget over the decoded frames' size, at least half a second but at most twice the budget, at most 40), read by the feeder each
  check. `BufferingPolicy`'s video thresholds are shares of the same numbers (`videoLowFrames` / `resumeFrames`), never
  constants: a queue that cannot grow to 40 would never be "ready". While buffering holds the clock the feeder fills to
  its high water instead of waiting to drain to the resume point (nothing drains a held clock).
- **The audio session is taken when playback starts and given back by `stop()` and at the end of the media** (`AudioOutputRoute`'s
  `activate(_:)` / `deactivate()`), never when the engine is made or the route's monitoring starts. `setActive` never runs
  on the main thread (the iOS route's own queue), and the clock never starts before `activate`'s completion
  (`isAudioOutputReady`); the completion starts only a clock held for the output alone (`isClockWaitingForOutput`), so a
  platform whose output is ready at once (macOS) keeps its clock starts where they were.
- **A route that does not report its device restarting the IO** (`AudioOutputRoute.reportsOutputRestarts`: iOS) has the
  engine re-anchor the clock itself after a change of output (`routeChangeSettleTime`); on macOS the report does it, and
  the engine must not add a second re-anchor there.
- **Coming back from the background checks the display layer before the seek**: a layer the system failed while the
  app was suspended (`.failed`, `requiresFlushToResumeDecoding`) drops frames silently until it is flushed.
- **Code that stops or re-anchors the synchronizer clock goes through `cancelPreroll()`** (directly or via
  `haltPlaybackPipeline()` / `startSynchronizerClockAfterPreroll`): it also ends a pending preroll and
  buffering and an audio join, whose tasks would otherwise restart the clock at a stale position.
- **The master clock is `PlaybackClock`.** Change its rate through `playbackClock.setRate`, never `synchronizer.setRate`
  (a rate change waits for the audio renderer's queue and blocked the main thread and the display link for up to 700
  ms), and read the position the engine decides on through `playbackClock.currentTime()`, which reads as the latest
  change makes it. Never read the synchronizer under a lock. A seek that resumes starts the clock on host time at once
  (`startProvisional`) and `AudioJoin` flushes the renderer (with the synchronizer held) only when it holds audio past
  the new start (`AudioJoin.needsFlush`: a flush stops the output's IO for ~0.5 s with multichannel on AirPods), feeds from the picture's
  position and hands the clock to the synchronizer (`handOver`): never put a wait for the audio on the picture's path,
  and never ask the HAL (`currentOutputLatency()`) on the main actor while the device starts or stops. See "The master
  clock and resuming after a seek" in `docs/ARCHITECTURE.md`.
- **Picture in Picture** mirrors the display layer 1:1 (macOS AVKit bug), so while it is active the
  layer's geometry comes from `pictureInPictureLayerGeometry`, not the host view's bounds. Keep the
  AVKit workarounds guarded (act only on a broken layout) and don't give PiP a controlTimebase of its
  own; see "Picture in Picture" in `docs/ARCHITECTURE.md`.

## Audio & demuxing invariants

- One `AVSampleBufferRenderSynchronizer` is the master clock; `AVSampleBufferAudioRenderer` is
  attached to it.
- `FFAudioDecoder`: pass planar audio to `swr_convert` via `extended_data` (`data` holds only 8
  pointers → crash on >8 channels); re-create `SwrContext` when format, sample rate or channel
  layout changes mid-stream.
- Read color metadata (`color_primaries`, `color_trc`, `color_space`, `hvcC`) and HDR luminance
  (MaxCLL/MaxFALL, mastering display) from the stream; never hardcode. Peak luminance feeds
  `sourcePeakNits`.
- Convert timestamps as `pts * Int64(timebase.num) / Int64(timebase.den)`.
- An audio track may come from an added file, a demuxer of its own (`PlaybackInputs`): read audio through
  `inputs.audioSource`, never `demuxer` directly, and position the file's input after the seek preview (where the
  picture landed). Never take one demuxer's lock while holding another's. Background: "Audio from another input"
  in `docs/ARCHITECTURE.md`.
- **Network sources are read ahead** by a demuxer thread (`MediaDemuxer+ReadAhead.swift`). The demuxer's packet
  queues, their state and the track selection are behind `queueLock`, the input behind `lock` taken through
  `lockIO()` (order: `lock` → `queueLock`). Blocking FFmpeg calls (`av_read_frame`, `av_seek_frame`) run with
  `queueLock` released (`readPacket(releasingQueueLock:)`, `withoutQueueLock`), so consumers and main-thread track
  selection never wait for the network: never call them holding `queueLock`, never take `lock` from the main thread.
  An HLS variant switch rewrites the stream description (`timebase`, `formatDescription`, `audioTimebase`, …) on the
  reading thread: once reading ahead, read it through `readingDescription`.
  The streaming client's HTTP(S) requests go through `URLSession` (`HTTPSessionTransport`), which measures each
  request's transfer apart from its answer for adaptive bitrate; keep them one at a time (`SegmentLoader` asks for
  the next segment only when the one read is through): over HTTP/1.1 the next segment's body comes with its answer and
  halves the rate of the one read.
  After touching the demuxer, also run the suites with `NITS_READ_AHEAD_LOCAL=1`. Background: "Network read-ahead"
  in `docs/ARCHITECTURE.md`; the HLS requests and adaptive bitrate: "Adaptive bitrate" in `docs/HLS.md`.
- **In the background the sound plays on and the picture is dropped** (iOS, `UIBackgroundModes = audio`): the demuxer's
  `isVideoDropped` (`setVideoDropped`, behind `queueLock`) keeps video packets out of the queue on both paths (read-ahead
  and on demand), makes the audio drive `consumedSeconds` and the read-ahead limit, takes the history limits to 0, seeks by the
  audio alone and refuses the packet cache until a slow seek. A stopped video feeder alone would freeze `consumedSeconds`
  and starve the audio; and the state is that flag, never `videoStreamIndex`, which a variant switch rewrites. The engine
  decides how to play, seek, join the audio, feed and buffer by `hasPicture` (`media.hasVideo` and not dropped), never
  by `media.hasVideo`; `media.hasVideo` is for the UI. Any start while in the background is audio only. Buffering there
  keeps the route's output running (`BackgroundOutputHold`, `AudioOutputRoute.keepOutputRunning`: silence on iOS), as iOS
  suspends an app ~5 s after its sound stops and a suspended app never reads on. Background:
  "Background playback" in `docs/ARCHITECTURE.md`.
- **A read-ahead demuxer keeps the packets it handed out** (`DemuxerPacketBuffer`, `backBytes`) so a seek inside them
  needs no input (`seekWithinCache`, tried by `seek` first; the engine learns whether it served a seek from
  `seekReportingCache`, not from state). It refuses live streams, a ladder's seek across a variant splice (the packets'
  `format.variantGeneration`; `keyframesShare`) and, after a variant chosen by hand, packets of another variant than the one read now or while it is asked for or being switched to, an HLS subtitle rendition selected after the
  packets were read (`selectionOutdatesCache`, which only a slow seek clears: the engine's re-read for it needs no flag),
  bitmap / closed-caption subtitles, and a read-ahead that ended short of the container's duration. History is pruned
  in whole GOPs under `queueLock` (keep the buffer's head a keyframe); audio history stays 0.5 s before the earliest
  video keyframe, or by size alone without video, so an external audio input keeps as much as the picture does. A
  timestamp going back (a discontinuity) moves `searchFloor`: nothing before it is searched, but it still plays; the
  cache refuses while the cursor is before it or the video and audio have met different numbers of breaks.
- **A live HLS stream has a window, not a duration** (`MediaInfo.duration` stays 0). The demuxer reads the window from
  the input after `read` (`publishLiveWindow`, `StreamingInput.liveWindow()`, told from its playlist model): never from
  another thread, never by parsing playlists in the demuxer. Seeks of a live stream go through `LiveStream.clamp` (`clampedSeekTarget`) and `seek` yields the input to
  itself (`lockIO(yielding:)`), as the read-ahead waits at the edge holding `lock`. A live stream's duration is never
  set from the format context (`configureVideoStream` runs again at a variant switch). Background: "Live streams" in
  `docs/ARCHITECTURE.md` and "Live playlists" in `docs/HLS.md`.
- **A live stream's history as numbered segments** (`ResolvedMedia.liveHistory`, YouTube's `&sq=N`; `AppSettings.liveHistory`) is
  the client's alone (`DASHHistory`, in `DASHPlaylists`): it lists the static manifest the resolver made, of every incomplete format the page lists grouped as an ordinary video's (`YouTubeFormatGrouping`; a ladder per codec, the codec chosen by `offeringChoices`; a day past the
  head) up to the segment before the head the source tells (`LiveSegmentSource.head`, asked by a reload no more often than
  `headPollInterval`), and the window is the input's like any live playlist's. The timeline is rebased to zero, and
  `MediaInfo.timelineOrigin` is the stream's time at that zero (`LiveHistory.origin`), so a position is saved as its time
  plus the origin. The manifest names the streams by keys (`LiveHistory.streamAddress`); the loader asks the source for each
  segment's signed address at the request (`PlaylistSource.address(of:)`) and renews it once on a 403 (`renewAddresses`):
  never put a signed address in the manifest or a playlist. Once the head stood still for `segmentWaitLimit` the source decides
  if the stream is over: if it is, the playlist ends after the head's segment (`hasEnded`); if not, the wait has no limit
  (`MediaPlaylist.updatePeriod` keeps the lane from calling it stuck). A segment listed that the server does not serve is
  skipped by the lane like any other (a hole in time), which is why the head's own segment is not listed until the end.
  Background: "Live streams" in `docs/ARCHITECTURE.md`.
- **HLS and DASH are Nits' own client** (`Sources/NitsStreaming/`: `StreamingPlaylist`, `StreamingTimeline`, `SegmentLoader`, `SegmentReader`,
  `StreamingLane`, `StreamingInput`); FFmpeg only demuxes each segment (its HLS demuxer is not built, so nothing falls back on it).
  Timestamps that restart or jump at an `EXT-X-DISCONTINUITY` (ads, splices) are moved onto the playlist's timeline by
  the reader of each run of segments: the demuxer sees one timeline, so don't add offsets of your own in Nits for HLS.
  A playlist served over HTTP(S) never reads a local file (`SegmentLoader.allowsFiles`). A failure of the network
  (`FFmpegErrorCode.isNetworkFailure`, told by `HTTPSessionInput.failureCode`) is no failure of a segment or a
  playlist: the lane asks the same again after a wait (`StreamingLane.recover`) while no request of the input is answered,
  up to 5 minutes, instead of skipping or counting it. The client plays playlists,
  not their text: they come from a `PlaylistSource` (`HLSServedPlaylists` for HLS), the way another manifest (DASH)
  comes into it. A segment with `isGap` (`EXT-X-GAP`; a DASH period with no sound beside others that have some, which
  `DASHPresentation.merge` keeps in its place so the sound after it is) is never requested: `StreamingLane` steps over it as a
  run of its own, and anything that picks a segment by time or number goes through `readable`. Background: "Timeline and
  discontinuities" in `docs/HLS.md`.
- **`MediaDemuxer` reads through a `DemuxerInput`** (`Demuxing/Input/`): the queues, read-ahead, packet cache, track
  selection, variant splice and subtitles are the demuxer's, whatever the input; opening, reading, seeking, stream
  selection, the timeline's origin, variants as the container groups them and a live window are the input's. What only
  FFmpeg's formats do (a format's name, `AVFMT_*` flags) goes in `FFmpegInput` or a trait
  of `DemuxerInputTraits`, never a check of `iformat` in the demuxer. Background: "Inputs" in `docs/ARCHITECTURE.md`.
- MPEG-TS / MPEG-PS timestamps are rebased to a zero-based timeline: read packets through
  `readPacket` (or `FFmpegInput.rebase` on another `AVFormatContext`); `DemuxerInput`'s seeks take targets on the
  timeline and add `timelineOffset` back themselves. A bare `av_read_frame` breaks timing for these
  files. Background in "Seeking" in `docs/ARCHITECTURE.md`.

## Keyboard shortcuts

- `CommandMenu` items use modified shortcuts only (`⌥→`, `⌃⌘F`, `⌘O`, …). Never give a menu item
  an unmodified key (`Space`, arrows, `m`): menu shortcuts intercept keys before the view, and a
  disabled item swallows them.
- Unmodified player keys (`Space`, arrows, `m`, `d`, `z` / `x`, `j` / `k`, `a` / `w`, `esc`) are handled in
  `PlayerKeyRouter` (called by `PlayerWindow.sendEvent`, and by `PlayerKeyMonitor` in a host's window) by physical key code, so they work on any keyboard layout and while focus is
  in a panel (text fields excepted). The press of ←/→ begins scrubbing (`beginScrubbing()`), any key-up or the window
  resigning key ends it (`endScrubbing()`): seeks while scrubbing only show frames; never end it on a timer.

## Tests

- Never reference personal media or absolute user paths. Media is generated by
  `SyntheticTestMediaFactory` (FFmpeg `lavfi`, cached in `$TMPDIR/NitsSyntheticMedia/`); add a
  `Preset` for new codec/container/channel/HDR coverage.
- The client's own tests (parsers, the timeline, adaptive bitrate; no server, no media) are `NitsStreamingTests`, which depends on
  `NitsStreaming` alone. Tests that serve media or play it, and the ones that join the client to `NitsCore`, stay in `NitsCoreTests`.
- `NitsTouchKitTests` and `NitsTouchUITests` (and the client's own `NitsStreamingTests`) run on the iOS simulator through the test plan of `Apps/iOS`:
  `./scripts/build_ios.sh test`. Engine tests that play media stay on macOS (`SyntheticTestMediaFactory` runs the `ffmpeg` CLI).
  What the platform alone does (the audio session, the scene's phase, a ProMotion link, memory) is checked on a device.
- Mark suites that play media in real time `.realtimePlayback`, and ones that depend on the host otherwise
  (hardware decoders, the audio renderer, Metal, timing of async work) `.hostDependent`. CI's gating step
  skips both (`NITS_SKIP_HOST_DEPENDENT_TESTS`); they run only on a manual dispatch of the CI workflow with
  `run_host_dependent_tests` checked (off by default; 30 min at most), only to report, so run them locally before pushing.
- Keep `.realtimePlayback` tests short (a few seconds each): they run one at a time through a queue shared across
  suites, and every second adds to a full run. Their 60 s limit is the trait's (`playTimeLimit`), counted from their
  turn; their suites take `.backstopTimeLimit`, never `.timeLimit(.minutes(1))`, which counts the wait in the queue too
  (once the queue reached a minute, each test added pushed the last ones over it). A real-time test in a suite with a
  short `.timeLimit` goes to a suite of its own. Tests that only measure (they need a media file of one's own) take
  `.enabled(if:)` on the environment variable, so a run reports them as skipped.
- Frame-freeze detection uses `PixelBufferAnalyzer`. A/V sync uses the `flashClick` preset (`SyncPatternTests`); after
  touching seeks, the clock, audio feeding or frame picking, run it too.
- Media tests skip when `ffmpeg` is missing; CI installs it.
- `TestHTTPServer` serves connections on its own queue (a `TaskExecutor`), never the cooperative pool: tests that
  open or read a network demuxer synchronously block pool threads, and a CI runner's three left it none to answer
  on (FFmpeg's requests timed out). Check HTTP tests with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a one-thread pool).
  Even on a machine with a full pool the HTTP, HLS and DASH suites run together at the edge of it: a suite of more such
  tests than a few, or an `async` one waiting in it, can stand the whole run still (every pool thread blocked on a
  server that has no thread to answer on; `sample` shows 12 cooperative threads and no other). Give the suite
  `.serialized` and `.networkServer` (`NetworkServerTrait`: a third of the pool's threads for such tests across all
  suites, waited for with an `await`; without it the HTTP, HLS and DASH suites together held all 12 and the run's async
  tests failed by their timeouts), keep its tests synchronous (an `async` one that has to be there goes into the same serialized suite: with
  a pool of one thread it waits for the thread behind the tests that sleep, its timeouts and the clock going on), and run
  it together with the other HTTP suites
  (`--filter "HLSOverHTTPTests|AdaptiveBitrateTests|DASH|MediaDemuxer|<yours>"`) before pushing.
