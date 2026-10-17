# Nits — Agent Guide

Nits is an HDR / Dolby Vision video player for macOS: custom Metal tone-mapping on SDR displays,
native `AVSampleBufferDisplayLayer` presentation on XDR displays. Design background and the
reasoning behind the invariants below: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Environment

- Build host / SDK: macOS 27, Apple Silicon. Deployment target: macOS 15.0.
- macOS 27 is the real, current OS — treat its SDK deprecation warnings as actionable. Fix them
  with replacement APIs that work on 15.0+ rather than suppressing them.
- Swift 6, strict concurrency (`-strict-concurrency=complete`), `ExistentialAny`.

## Tools & references

- **apple-docs MCP** (if available): before using or replacing an AppKit, SwiftUI, AVFoundation,
  Metal or CoreMedia API, check its availability and deprecation status
  (`get_platform_compatibility`) — Apple APIs change faster than training data.
- **`.ref/`** — reference implementations and third-party sources for algorithms, format parsing,
  shader math and pipeline behaviour. Adapt, don't copy: results must follow the rules below.
  Nits is MIT, so licenses limit what may enter `Sources/` (ideas and behaviour are always fine):
  - GPL: never port code, not even translated.
  - LGPL (`mpv`, `ffmpeg`, `gstreamer`): only into a separate file with an LGPL-2.1-or-later
    header and attribution, listed in `THIRD_PARTY_NOTICES.md` (see `BT2390ToneMapping.metal`).
  - MIT/BSD (`SwiftPlayer`): keep the copyright notice in `THIRD_PARTY_NOTICES.md`.
  Prefer implementing from the spec (ITU-R, SMPTE, Apple docs) over porting.

## Commands

- Build: `swift build`
- Strict type-check incl. tests: `./scripts/format.sh typecheck`
- Format / lint: `./scripts/format.sh` / `./scripts/format.sh lint` (pre-push runs `check`)
- Tests: `swift test`; after touching seek, decoding, audio or track switching also run
  `swift test --filter PlaybackStressTests`.
- App bundle: `./scripts/bundle_app.sh` — embeds the LGPL FFmpeg / dav1d from
  `scripts/setup_dependencies.sh` (versions, flags and the release checksum live in
  `scripts/deps_config.sh`; bump `DEPS_VERSION` when changing them). `format.sh` and CI build and
  test against `.build/dependencies` when present, otherwise SwiftPM falls back to Homebrew FFmpeg.
  SwiftPM links with the deployment target (15.0) as the SDK version, so `swift run` binaries show
  the legacy (pre-Liquid Glass) look on macOS 26+; `bundle_app.sh` stamps the real SDK via `vtool`.
  Judge UI only from the bundle.
- Releases: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`. The app version comes
  only from tags (`bundle_app.sh`: `git describe` or `--version=`), so never hardcode it in
  Info.plist or sources.
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

The one intentional exception: display-layer `enqueueSampleBuffer:` / `flush` go through cached
selectors (see Video pipeline).

## Layer boundaries

- `NitsCore` (engine) never imports SwiftUI or knows about views. `PlayerEngine` is `@Observable`
  and `@MainActor`; UI observes it directly, no wrapper view-models.
- `NitsKit` owns windows, menus and NowPlaying. `NitsUI` is declarative views plus
  `PlayerUIState` for transient UI state.
- UI changes must not require changes to decoding, shaders or A/V sync.
- Keep the engine embeddable: `NativeVideoHostView` stays a bare canvas with no built-in controls;
  commands and events go through `PlayerEngineProtocol`; the demuxer must handle remote URLs with
  custom HTTP headers, not just `file://`.

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
- **Seeks** run on the serial `seekQueue` with a `currentSeekId` generation token; stale seeks are
  dropped. Seek and render-mode switches clear `FrameQueue` and flush decoder and renderer.
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
  thread, past the few packets seek previews and frame steps decode. Frames that aren't planar 4:2:0
  go through `FrameFormatNormalizer` (libswscale); RGB sources are tagged with the matrix used.
- `CV*GetStringForIntegerCodePoint` returns placeholders (e.g. "YCbCrMatrix#5") for code points
  without a CoreVideo constant; `StreamColorimetry` accepts only real constants.
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
- **Code that stops or re-anchors the synchronizer clock goes through `cancelPreroll()`** (directly or via
  `haltPlaybackPipeline()` / `startSynchronizerClockAfterPreroll`): it also ends a pending preroll and
  buffering, whose tasks would otherwise restart the clock at a stale position.
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
- MPEG-TS / MPEG-PS timestamps are rebased to a zero-based timeline: read packets through
  `readPacket` (or `MediaDemuxer.rebase` on another `AVFormatContext`) and add
  `timelineOffset` back to `av_seek_frame` targets. A bare `av_read_frame` breaks timing for these
  files. Background in "Seeking" in `docs/ARCHITECTURE.md`.

## Keyboard shortcuts

- `CommandMenu` items use modified shortcuts only (`⌥→`, `⌃⌘F`, `⌘O`, …). Never give a menu item
  an unmodified key (`Space`, arrows, `m`): menu shortcuts intercept keys before the view, and a
  disabled item swallows them.
- Unmodified player keys (`Space`, arrows, `m`, `d`, `z` / `x`, `j` / `k`, `esc`) are handled in
  `PlayerWindow.sendEvent` by physical key code, so they work on any keyboard layout and while focus is
  in a panel (text fields excepted).

## Tests

- Never reference personal media or absolute user paths. Media is generated by
  `SyntheticTestMediaFactory` (FFmpeg `lavfi`, cached in `$TMPDIR/NitsSyntheticMedia/`); add a
  `Preset` for new codec/container/channel/HDR coverage.
- Frame-freeze detection uses `PixelBufferAnalyzer`.
- Media tests skip when `ffmpeg` is missing; CI installs it.
