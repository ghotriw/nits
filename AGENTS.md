# Platform & Environment Compatibility Rules

## 1. Operating System & SDK Baseline
- **Host / Build SDK:** macOS 27 (Apple Silicon).
- **Minimum Deployment Target:** macOS 15.0+ (Sequoia).
- **Environment Reality:** macOS 27 is the active, real host OS and build environment. Never question its existence or treat it as a hypothetical/future release or typo.

## 2. Deprecations & Compiler Warnings Policy
- **Treat Warnings Seriously:** Do NOT ignore, suppress, or dismiss compiler warnings regarding macOS 27 deprecations under the assumption that the OS "does not exist yet".
- **Modern Replacements:** In macOS 27, various older APIs have become deprecated. The modern replacements for these APIs already exist and are fully backward-compatible with macOS 15.0+.
- **Resolution Strategy:** Always address deprecation warnings by adopting modern, supported APIs that function cleanly on macOS 15.0+ through macOS 27 without deprecation warnings.
- **No Hallucinated Objections:** Never emit comments, disclaimers, or chat warnings arguing that macOS 27 is invalid. Focus directly on resolving diagnostics with modern Apple APIs.

# Modern Apple Development Standards (macOS 15+ / Swift 6)

## 1. Requirement to Verify APIs via Apple Docs
- The `apple-docs` MCP server is available as a lazy-loaded MCP server (`ServerName: "apple-docs"`).
  - Use `call_mcp_tool` with `ServerName: "apple-docs"` to call its tools:
    - `search_framework_symbols`: Best for finding modern symbols and APIs in a framework (e.g. `framework: "AVFoundation"`, `query: "AVPlayer"`).
    - `get_apple_doc_content`: Retrieve full documentation for a specific symbol URL or path.
    - `search_apple_docs`: Full-text search across Apple developer guides and articles.
    - `get_platform_compatibility`: Verify minimum macOS deployment targets and deprecation status.
- **MANDATORY**: When writing, updating, or reviewing code for AppKit, SwiftUI, AVFoundation, Metal, and CoreMedia, always check modern APIs via `apple-docs` and avoid obsolete/deprecated patterns.
- Do NOT guess or rely on pre-2023 training memory for Apple APIs.

## 2. Local Reference Code (.ref/)
- **Purpose:** The root `.ref/` directory contains local reference implementations, sample projects, and third-party source code kept for architectural comparison and guidance.
- **Agent Usage Guidelines:**
  - Agents are encouraged to read and inspect code in `.ref/` when researching algorithms, format parsing, shader math, or pipeline behaviors.
  - **Do NOT copy-paste blindly:** Always adapt solutions to modern Swift 6 / macOS 15+ standards and ensure strict adherence to `Nits` architecture invariants (no `CVDisplayLink`, no `NSLock`, strict display-layer isolation).

## 3. Deprecated & Prohibited Patterns
- ❌ **Do NOT use `NSApp.activate(ignoringOtherApps:)`** (Deprecated in macOS 14.0).
  ✓ **Use `NSApp.activate()`**.
- ❌ **Do NOT use `ObservableObject` and `@Published`** from Combine for application state in macOS 14+.
  ✓ **Use the `@Observable` macro** from the `Observation` framework.
- ❌ **Do NOT use imperative `isFocused = true` inside `.onAppear`**.
  ✓ **Use `.defaultFocus(_:_:)`** and configure `window.initialFirstResponder = hostingView` in AppKit `NSWindowController`.
- ❌ **Do NOT allocate new objects/adapters inside SwiftUI computed properties** (e.g. `var actionsAdapter: any PlayerActions { ... }`).
  ✓ Pass dependencies or manage state in `@State` / dedicated controllers.

## 4. Keyboard Shortcuts & Menu Architecture
- **Global Menus (`CommandMenu`)**:
  - Must ONLY use standard system shortcuts with modifier keys (e.g., `⌥→`, `⌥←`, `⌃⌘F`, `⌘I`, `⌘O`).
  - Must NEVER assign unmodified navigation keys (`Space`, `←`, `→`, `↑`, `↓`, `m`) to `CommandMenu` items with `modifiers: []`.
  - Unmodified menu shortcuts intercept key events before the view's responder chain, causing dead/swallowed keys when items are disabled.
- **View-Level Shortcuts**:
  - Single-key/unmodified navigation shortcuts for media players (`Space`, arrows, `m`, `d`, `esc`) belong strictly inside the player view via `.onKeyPress`.

# Shell & Command Execution Guidelines

## Restrictions on Inline Scripts
- **NEVER** run inline scripts via `-c` or `-e` flags in shell commands:
  - Do NOT execute `python3 -c "..."` or `python -c "..."`.
  - Do NOT execute `node -e "..."`.
  - Do NOT execute inline `ruby -e` or `perl -e` commands.
- **Do NOT wrap CLI tools in `subprocess`:** Run compiler, build, and inspection tools directly in shell commands (e.g. `swiftc ...`, `git ...`, `xcodebuild ...`, `clang ...`). Wrapping them inside Python `subprocess.check_output` or similar scripts is prohibited.

## How to Run Helper Scripts
If a multi-step inspection or test script is strictly necessary:
1. Write the code to a temporary script file first using file editing/creation tools (e.g. `scripts/temp_check.py` or `.agents/scratch/check.py`).
2. Run the script via `python3 path/to/script.py`.
3. Clean up the temporary file if it is no longer needed.

# Nits Core Architecture & Regression Prevention Rules

This document defines the core architecture principles, colorimetry standards, threading invariants, and architectural decoupling rules for `Nits`. Any future additions (audio pipeline, subtitle renderers, UI, additional container/codec formats) **must strictly adhere** to these rules to prevent regressions.

---

## 0. Target Platform Baseline & Modern API Mandate
- **Deployment Target:** macOS 15.0+ (Sequoia) / Apple Silicon (ARM64).
- **Language Mode:** Swift 6 with Strict Concurrency checking enabled (`-strict-concurrency=complete`, `ExistentialAny`).
- **Zero Legacy API Policy:**
  - Strictly prohibit APIs deprecated in macOS 14/15 or originating from OS X Carbon/Tiger era (e.g., `CVDisplayLink`, raw C callbacks, manual `Unmanaged.toOpaque()` pointer casting).
  - Modern QuartzCore, Metal, and AVFoundation system APIs (`CADisplayLink`, `AVSampleBufferRenderSynchronizer`, Swift Concurrency `@Observable`, `@MainActor`, `OSAllocatedUnfairLock`) must be utilized exclusively.
  - *Exception:* Decoupled `sampleBufferRenderer` selector dispatch is deliberately retained to prevent the Apple Silicon IOMFB Direct Scanout pause freeze (see Section 3.1).

---

## 1. Project Mission & Target Visual Standards
Deliver reference-grade playback of HDR and Dolby Vision (Profile 8.1 / HDR10) video on macOS:
1. **On Standard SDR Displays (External 4K/5K monitors without HDR, EDR == 1.0):**
   - Provide vibrant color fidelity, deep and detailed shadow retrieval, and crisp highlight roll-off without the washed-out, dark, or crushed look produced by default operating system tone mapping.
   - Powered by a custom **Metal SDR Tone-Mapper** implementing the ITU-R BT.2390 EETF specification (203 nits target white point, Display P3 destination gamut, pure Gamma 2.2 output, and FidelityFX Contrast-Adaptive Sharpening).
2. **On Native Liquid Retina XDR / Extended Dynamic Range Displays (EDR > 1.01):**
   - Route uncompressed video straight to the native Apple DisplayLayer hardware overlay, unlocking full 1000–1600 nits Mini-LED peak brightness.

---

## 2. Decoupled Architecture & Layer Boundaries

The codebase is split into strictly separated modular layers to prevent UI changes from polluting or breaking low-level media pipelines:

```
[Presentation UI Layer (NitsUI / AppKit)]
               ↓ (observes state via @Observable & dispatches actions)
[Windowing & App Integration Layer (NitsKit)]
               ↓ (coordinates window, menus, NowPlaying & delegates)
[Engine Core & Contract Protocol (NitsCore)]
  ├─ protocol PlayerEngineProtocol (@MainActor, Sendable)
  └─ final class PlayerEngine (@Observable, @MainActor, zero SwiftUI dependency)
               ↓ (internal subsystems)
[Low-Level Pipelines (Metal Tone-Mapper / VideoToolbox / Demuxer / Synchronizer)]
```

### 2.1. Layer 1: Headless Engine Core (`PlayerEngine: PlayerEngineProtocol`)
- **Zero SwiftUI Dependency:** Located in `NitsCore`. Must never import SwiftUI or depend on UI views, buttons, layouts, or control state.
- **Responsibilities:** Demuxing, decoding, hardware master clock synchronization, Metal rendering, frame queues, EDR/screen handover, playback history persistence.
- **Direct SwiftUI Observability:** Employs the Swift `Observation` framework (`@Observable`) directly on `PlayerEngine`. Per Apple's modern architecture standards, field-level observation eliminates redundant intermediate ViewModel wrappers while ensuring UI views re-evaluate only when the specific properties they read change.
- **Public Surface:** Implements `protocol PlayerEngineProtocol` and exports a lightweight `NSView` video canvas (`NativeVideoHostView`).

### 2.2. Layer 2: Windowing & Application Integration (`NitsKit`)
- Lives on `@MainActor`.
- Manages window lifecycle (`PlayerWindowController`, `PlayerWindow`), menu commands (`PlayerCommands`), and system media integration (`NowPlayingController`).
- Connects the engine core with the presentation UI without coupling low-level media logic to window state.

### 2.3. Layer 3: Presentation UI (`NitsUI`)
- Purely declarative UI components (`ContentView`, `ControlsOverlay`, `TimelineSlider`, `SettingsView`, `PerformanceHUDView`, `SubtitleOverlayView`).
- Consumes `PlayerEngine` via Swift Observation and isolates transient UI state (fullscreen transitions, auto-hide triggers) inside lightweight `@Observable class PlayerUIState`.
- Changing, rewriting, or animating UI components must never impact or require changes to decoding loops, Metal shaders, or A/V sync.

### 2.4. Host Application & Web-Bridge Embeddability (WKWebView / Headless Integration)
To support embedding into host applications with web-driven frontends (e.g., `WKWebView` / Emby client), the core must strictly satisfy:
1. **Headless Video Canvas (`NativeVideoHostView` / `NSView` / `CALayer`):**
   - The engine provides a standalone video canvas view (`NativeVideoHostView`) without imposing any native controls or overlays.
   - Host applications can place a transparent `WKWebView` above or alongside the video surface, rendering all UI controls in HTML/CSS/JS.
2. **Bidirectional Bridge Contract (Commands IN, Events OUT):**
   - **Commands IN:** The engine accepts commands via `PlayerEngineProtocol`: `load(path:headers:)`, `loadAsync(path:headers:)`, `play()`, `pause()`, `seek(to:)`, `stepVolume(by:)`, `selectAudioTrack(id:)`, `selectSubtitleTrack(id:)`.
   - **Events OUT:** The engine provides explicit callbacks suitable for JSON bridging to JavaScript (`window.webkit.messageHandlers`):
     - `onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)?`
     - `onPlaybackStateChanged: ((PlaybackState) -> Void)?`
3. **Network Streams & HTTP Authorization:**
   - The demuxing subsystem must not assume local `file://` URLs.
   - Remote streaming via HTTP/HTTPS, HLS, or direct MKV over HTTP must support custom request headers (e.g. `X-Emby-Token`, `Authorization`, custom User-Agent, cookies) via FFmpeg `AVDictionary` options.

---

## 3. Video Pipeline Invariants (DO NOT BREAK)

### 3.1. Display-Adaptive Rendering & Native HDR Presentation
- The default player mode is `.auto` (`Auto (Display Adaptive)`).
- EDR capabilities are queried dynamically across display changes:
  ```swift
  let isHDR = (screen.maximumExtendedDynamicRangeColorComponentValue) > 1.01
  ```
- **Unified Video Decoding Pipeline:**
  - All video packets are routed through `VTVideoDecoder` to output uncompressed `CVPixelBuffer` frames into `FrameQueue`.
  - The render mode determines how the decoded `CVPixelBuffer` is presented:
    - **`.metalToneMap` (SDR Displays):** Frame is rendered via `MetalVideoRenderer` into `CAMetalLayer` with BT.2390 tone curve.
    - **`.system` (Native Liquid Retina XDR / HDR Displays):** Frame is wrapped in a `CMSampleBuffer` with `kCMSampleAttachmentKey_DisplayImmediately = true` and enqueued directly to `AVSampleBufferDisplayLayer`.
- **No Compressed NALU Direct Passthrough:**
  - Under no circumstances should `demuxer.nextVideoSample()` return raw compressed NALU packets (e.g. HEVC/H.264) to be enqueued directly into `displayLayer` / `videoReceiver` with movie PTS.
  - **Failure Mode:** On Apple Silicon Liquid Retina XDR displays in fullscreen mode, enqueuing compressed packets synchronized with movie PTS triggers hardware Direct Scanout (`IOMFBDisplay`). Seeking backward sends older PTS packets that break internal hardware fences (`IOFenceTransaction`), completely deadlocking `WindowServer`.
  - **Architectural Uniformity:** All frames must pass through `VTVideoDecoder` and `FrameQueue` so that both Metal and System renderers receive decoded `CVPixelBuffer` frames paced identically by `CADisplayLink`.
- **DisplayLayer & Timebase Isolation (XDR Fullscreen Deadlock Prevention):**
  - **CRITICAL INVARIANT:** `AVSampleBufferDisplayLayer` must remain completely decoupled from `AVSampleBufferRenderSynchronizer`.
  - **Hardware Root Cause:** On Apple Silicon Liquid Retina XDR displays in fullscreen mode, `AVSampleBufferDisplayLayer` operates via hardware Direct Scanout (`IOMFBDisplay` / `IOFenceTransaction`). If the display layer is attached to `AVSampleBufferRenderSynchronizer`, calling `synchronizer.setRate(0.0)` on playback pause triggers a 30-second hardware fence deadlock in `WindowServer`, freezing event dispatch across all macOS windows until the display watchdog resets or `setRate(1.0)` is called.
  - **Architecture Requirements:**
    1. `AVSampleBufferDisplayLayer` is completely decoupled from `AVSampleBufferRenderSynchronizer` (`synchronizer` manages only audio via `audioReceiver`).
    2. The display layer's `controlTimebase` is assigned to an independent host clock: `CMTimebaseCreateWithSourceClock(..., CMClockGetHostTimeClock(), ...)`, initialized with `rate = 1.0` and never paused.
    3. Frames are enqueued as uncompressed `CVPixelBuffer` buffers wrapped with `kCMSampleAttachmentKey_DisplayImmediately = true`.
    4. Frame delivery is paced by the `CADisplayLink` loop aligned to the synchronizer's audio/master clock time (`synchronizer.currentTime()`).
    5. **Swift Deprecation Warning Handling:** Apple marked `displayLayer.enqueue` and `sampleBufferRenderer.enqueue` as deprecated in Swift to encourage migrating to `synchronizer.sampleBufferReceiver`. Because registering the display layer in `synchronizer` causes the aforementioned fullscreen Direct Scanout pause freeze, the engine deliberately uses statically cached selectors (`sel_registerName("enqueueSampleBuffer:")` and `sel_registerName("flush")`) via `sampleBufferRenderer.perform(...)`. Future agents must **never** attempt to "modernize" this by attaching `displayLayer` to `synchronizer`.
- **Seamless Render Mode Switching:**
  - Switching between `.metalToneMap` and `.system` toggles layer visibility (`isMetalLayerVisible`) and clears the display layer (`sampleBufferRenderer.flush()`).
  - Because all frames are decoded continuously into `FrameQueue`, handover between Metal and Native HDR occurs with zero latency and zero frame stalling.
- **Pipeline Queue Hygiene:** On seek or render mode handover, `frameQueue.clear()`, `decoder.flush()`, and renderer flush must be executed to flush stale frames and prevent stutter or packet queue desynchronization.
- **Seek Serialization:** All seeks must be executed on the engine's serial `seekQueue` and carry a generation token (`currentSeekId`); a seek whose token is outdated must be discarded. Rapid scrubbing must never run concurrent demuxer seeks.
- **No Session Teardown on Seek:** Seeking must call `decoder.flush()` and must NOT destroy/recreate the `VTDecompressionSession`. Before any invalidate/reset, `VTVideoDecoder` must call `VTDecompressionSessionWaitForAsynchronousFrames` so that in-flight output callbacks cannot race with session replacement. Session, format description and output handler are guarded by a lock.

### 3.2. Metal Tone-Mapping Color Engine (`HDRToneMapping.metal`)
- **Input Format:** 10-bit P010 biplanar YCbCr (`r16Unorm` Y plane, `rg16Unorm` CbCr plane). Normalization must account for VideoToolbox MSB-alignment: `val * 65535.0 / 1023.0`.
- **Output Pixel Format:** `CAMetalLayer` and the render pipeline state must strictly use `.bgr10a2Unorm` (10-bit color depth) configured for the `Display P3` color space. Never regress to 8-bit `.bgra8Unorm`, as it introduces gradient banding across dark regions and skies.
- **Shader Colorimetry Pipeline:**
  - PQ (SMPTE ST 2084) inverse transfer function $\rightarrow$ absolute linear optical light $L \in [0, 10000]$ nits.
  - ITU-R BT.2390 (EETF) tone curve compressed against `targetNits = 203.0` (standard ITU reference white for SDR mastering).
  - Chromaticity conversion: `BT.2020` matrix transform to `Display P3` (D65 white point) with gamut boundary safety clamping.
  - Output electro-optical transfer function: **pure power Gamma 2.2** (`pow(max(c, 0.0), 1.0 / 2.2)`).
  - Contrast-Adaptive Sharpening: AMD FidelityFX CAS formulation (`peak = -1.0 / mix(8.0, 5.0, strength); weight = amplitude * peak;`). Guarantees no division by zero or NaN artifacts when `strength = 1.0`.

### 3.3. VSYNC Synchronization & Display Pacing (CADisplayLink macOS 14+)
- **Strict Prohibition of Legacy `CVDisplayLink`:** Under no circumstances should deprecated C-API `CVDisplayLink` (`CVDisplayLinkCreateWithActiveCGDisplays`, `CVDisplayLinkSetOutputCallback`) be used. It originates from 2005 (Mac OS X Tiger), causes desynchronization on ProMotion 120Hz dynamic refresh rates, fails to migrate automatically across screens with different refresh rates, and requires unsafe raw C pointers (`Unmanaged.toOpaque()`).
- **Native `CADisplayLink` Architecture:**
  - VSYNC synchronization is driven by modern `CADisplayLink` (macOS 14+ / QuartzCore).
  - The link must be attached directly to the host view via `view.displayLink(target:selector:)` or `screen.displayLink(...)`, ensuring QuartzCore compositor awareness and automatic multi-monitor display tracking.
  - Must explicitly configure `preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 120)` to natively adapt to ProMotion and variable refresh rates without frame drops or jitter.
  - Pacing lifecycle is managed via `.isPaused` and cleanly destroyed via `.invalidate()`.

### 3.4. Thread Safety, Locks & Backpressure Model
- **Strict Prohibition of `NSLock` and `Thread.sleep`:**
  - Traditional Objective-C `NSLock` is strictly prohibited. All synchronous mutual exclusions must use native Apple Silicon `OSAllocatedUnfairLock` from the `os` module (`OSAllocatedUnfairLock()`).
  - Blocking dispatch worker threads via `Thread.sleep` is strictly prohibited to prevent GCD thread pool starvation.
  - Video backpressure inside `requestMediaDataWhenReady` must be cooperative and non-blocking: when queue limits are reached, the block immediately breaks/exits.
  - Audio backpressure is managed natively by CoreAudio's `AVSampleBufferAudioRenderer.isReadyForMoreMediaData`. Early manual breaking while `isReadyForMoreMediaData` is true is prohibited because AVFoundation immediately re-triggers the block in a 100% CPU busy-spin loop. Work resumes naturally when buffers are consumed and hardware signals readiness.
- **Locking & Concurrency Standards:**
  - `MetalVideoRenderer` uses `renderLock: OSAllocatedUnfairLock` (synchronizing draw calls across display link and UI frame invalidation) and `OSAllocatedUnfairLock(initialState: ToneMapUniforms())`.
  - `FrameQueue` protects the internal decoded frame array and last rendered buffer via `OSAllocatedUnfairLock()`.
  - Both `ToneMapUniforms` and `RenderMode` must conform to `Sendable`.
  - `activeRenderMode` must be held behind an `OSAllocatedUnfairLock` and exposed as `nonisolated` to allow the display link to query the mode without actor hops or priority inversions.
  - Any UI state changes originating from the display link loop (such as `isMetalLayerVisible`) must be isolated cleanly on `@MainActor`.

### 3.5. Sorted Priority Ring Buffer Architecture (`FrameQueue`)
- **Zero Heap Reallocation & Fixed Capacity:** `FrameQueue` is implemented as a fixed-capacity pre-allocated circular ring buffer (`[DecodedFrame?]`), avoiding memory fragmentation and allocations during playback.
- **O(1) Pop & Instant `IOSurface` Deallocation:**
  - Fast head pointer advancement (`head = (head + 1) % capacity`) in $O(1)$.
  - The vacated slot must be immediately set to `nil` (`buffer[head] = nil`). Because `CVPixelBuffer` encapsulates hardware `IOSurface` backing memory in VRAM, failing to nil the reference would keep the buffer alive until a full ring rotation, starving the hardware decoding pool in `VTDecompressionSession`.
- **Strict PTS Ordering & B-Frame Handling:**
  - Out-of-order B-frames emitted by `VTDecompressionSession` must never be appended blindly.
  - Fast path ($O(1)$): Frames with monotonically increasing PTS (`frame.pts >= lastFrame.pts`) append directly to `tail`.
  - B-frame path ($O(\log N)$): Out-of-order frames are inserted via binary search, shifting only the local slice of 1–3 affected slots.
- **Pause Frame Parity:**
  - Preserves the most recently displayed buffer in `lastRenderedBuffer: CVPixelBuffer?`. Mode switching or scrubbing while paused invokes `renderCurrentFrame()`, re-rendering the frozen buffer for zero-drift parity.

---

## 4. Invariants for Future Subsystems

### 4.1. Audio Pipeline
- Playback timing must remain driven by a single unified **`AVSampleBufferRenderSynchronizer`**.
- Audio output must utilize `AVSampleBufferAudioRenderer` attached directly to this shared synchronizer.
- This maintains hardware-locked audio/video synchronization without software clock drift.
- **Resampler Robustness (`FFAudioDecoder`):**
  - Planar multi-channel audio must be passed to `swr_convert` via `avFrame.pointee.extended_data` (NOT `data`, which holds only 8 pointers); otherwise >8 channels or some layouts crash with SIGSEGV.
  - Frame format, sample rate and channel layout can change mid-stream or after a seek/track switch (e.g. 5.1 → stereo). The decoder must track them and free/re-create `SwrContext` whenever any of them changes.

### 4.2. Universal Demuxing & Color Metadata
- Do not hardcode container metadata:
  - Color space flags (`color_primaries`, `color_trc`, `color_space`) must be read dynamically from `codecpar` and container extradata (`hvcC`).
  - MaxCLL/MaxFALL and Mastering Display Luminance must be parsed from packet side data or SEI payloads and forwarded to `metalRenderer.uniforms.sourcePeakNits`.
  - All timestamps must compute `pts * Int64(timebase.num) / Int64(timebase.den)`.

### 4.3. Pre-Commit Verification
- The package must compile cleanly using `swift build` without errors.
- Any modifications to `HDRToneMapping.metal` must be verified against NaN edge cases at maximum sharpness (`outputSharpness = 1.0`).
- Changes to seek, decoding, audio or track-switching code must pass `swift test --filter PlaybackStressTests` (rapid scrubbing, frame-freeze detection, play/pause races, audio track switching).

### 4.4. Test Media Policy
- Tests must never reference personal/local media files or absolute user paths.
- All media is synthesized on demand by `SyntheticTestMediaFactory` (FFmpeg `lavfi`, cached in `$TMPDIR/NitsSyntheticMedia/`). Add a new `Preset` there when a new codec/channel/container/HDR configuration needs coverage.
- Frame-freeze detection uses `PixelBufferAnalyzer` (Y-plane hash / MAD).
- If `ffmpeg` is missing, media-dependent tests skip silently; CI must install `ffmpeg`.
