@preconcurrency import AVFoundation
import AppKit
import CFFmpeg
@preconcurrency import CoreMedia
import Foundation
import Observation
import QuartzCore
import os

@Observable
@MainActor
public final class PlayerEngine: PlayerEngineProtocol {
    public var currentTime: Double = 0 {
        didSet {
            updateCurrentChapterIndex()
            updateActiveActionButton()
        }
    }
    /// Host-provided buttons for spans of the timeline; replaced by each load's `MediaLoadRequest.actionButtons`.
    public var actionButtons: [PlaybackActionButton] = [] {
        didSet {
            updateActiveActionButton()
        }
    }
    /// The button whose span contains `currentTime`; `nil` outside every span and while no media is loaded.
    public internal(set) var activeActionButton: PlaybackActionButton?
    /// Bumped by every load. Per-media UI state (a dismissed action button) resets on it: a load from a position inside
    /// a span to the same position in the next media never shows `activeActionButton` change.
    public internal(set) var loadGeneration: Int = 0
    /// Called with the button's `id` when an action button is pressed, by the user or by auto-press.
    public var onActionButton: ((_ id: String) -> Void)?
    /// Set by a host that keeps its own queue: Next and Previous go to it instead of `playlist`, and the end of the
    /// media leaves what plays next to the host. The host answers by loading the item it moves to.
    public var onTrackNavigation: ((_ direction: TrackNavigationDirection) -> Void)?
    /// The host's queue around the media playing now (see `onTrackNavigation`); replaced by each load's
    /// `MediaLoadRequest.trackNavigation`.
    public var trackNavigation = TrackNavigation() {
        didSet {
            if oldValue != trackNavigation {
                onTrackNavigationChanged?()
            }
        }
    }
    /// Called when `trackNavigation` changes (a load, the host, a press), so Next / Previous outside the views, such
    /// as the system's media controls, follow it without waiting for a time update; none come while paused.
    public var onTrackNavigationChanged: (() -> Void)?
    /// Container chapters of the loaded media, sorted by start; empty when it has none.
    public internal(set) var chapters: [MediaChapter] = [] {
        didSet {
            currentChapterIndex = nil
            updateCurrentChapterIndex()
        }
    }
    /// Index into `chapters` of the chapter at `currentTime`; `nil` before the first one or without chapters.
    public internal(set) var currentChapterIndex: Int?
    public var pendingSeekTime: Double? { chaseTargetTime }
    public var duration: Double = 0
    public var isPlaying: Bool = false {
        didSet {
            displaySleepManager.update(isPlaying: isPlaying, hasVideo: hasVideo)
        }
    }
    public var isLoaded: Bool = false {
        didSet {
            updateActiveActionButton()
        }
    }
    public var isLoading: Bool = false
    public var loadError: String? = nil
    public var playbackState: PlaybackState = .idle {
        didSet {
            if oldValue != playbackState {
                onPlaybackStateChanged?(playbackState)
            }
        }
    }

    /// Periodic time observer callback for external clients (e.g. Coordinator / Bridge)
    public var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)?
    /// State change callback for external clients
    public var onPlaybackStateChanged: ((_ state: PlaybackState) -> Void)?
    /// Callback fired when an in-flight relative seek settles onto its final keyframe or exact PTS
    public var onRelativeSeekResolved: ((_ offset: Double, _ currentTime: Double) -> Void)?

    var loadingTask: Task<Void, Never>?
    var currentInterruptContext: MediaDemuxer.InterruptContext?
    var currentLoadID = UUID()
    public var mediaTitle: String = ""
    public var artworkData: Data? = nil
    public var artworkURL: URL? = nil
    public var hasVideo: Bool = false {
        didSet {
            displaySleepManager.update(isPlaying: isPlaying, hasVideo: hasVideo)
        }
    }
    public let displaySleepManager = DisplaySleepManager()
    public var isDisplaySleepDisabled: Bool {
        displaySleepManager.isSleepDisabled
    }
    public var videoWidth: Int = 0
    public var videoHeight: Int = 0
    public var nominalFrameDuration: Double = 1.0 / 24.0
    @ObservationIgnored
    let nominalFrameDurationLock = OSAllocatedUnfairLock(initialState: 1.0 / 24.0)
    public var sampleAspectRatio: RationalAspectRatio = .square
    public var displayAspectRatio: Double {
        RationalAspectRatio.computeDisplayAspectRatio(width: videoWidth, height: videoHeight, sar: sampleAspectRatio)
    }
    public var videoCodecName: String = ""
    public var videoBitDepth: Int = 8
    public var videoColorPrimaries: String = ""
    public var videoTransferFunction: String = ""
    public var videoDolbyVisionProfile: String? = nil
    public var videoSourcePeakNits: Float = 0
    public var isHDRContent: Bool = false {
        didSet {
            if oldValue != isHDRContent {
                updateEffectiveRenderMode()
            }
        }
    }
    public var renderMode: RenderMode = .auto {
        didSet {
            updateEffectiveRenderMode()
        }
    }
    public internal(set) var isInterlacedContent: Bool = false
    /// Kept across files for the session, like `renderMode`.
    public var deinterlaceMode: DeinterlaceMode = .auto {
        didSet {
            guard oldValue != deinterlaceMode else { return }
            applyDeinterlaceMode(refresh: true)
        }
    }
    /// Set by the host while Picture in Picture mirrors `displayLayer`. PiP only sees the display layer, so Metal
    /// tone mapping falls back to `.system`, and the display link follows the screen instead of a possibly hidden
    /// host view.
    public var isPictureInPictureActive: Bool = false {
        didSet {
            guard oldValue != isPictureInPictureActive else { return }
            updateEffectiveRenderMode()
            retargetDisplayLinkForPictureInPicture()
        }
    }
    /// How the host view lays out `displayLayer` around Picture in Picture; `nil` fills the host view.
    public var pictureInPictureLayerGeometry: PictureInPictureLayerGeometry? {
        didSet {
            guard oldValue != pictureInPictureLayerGeometry, let host = displayLinkHostView else { return }
            // The host window is usually ordered out during PiP and would not lay out on its own.
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
    }
    public var isHDRDisplay: Bool = false {
        didSet {
            if oldValue != isHDRDisplay {
                updateEffectiveRenderMode()
            }
        }
    }
    public var isToneMappingPermitted: Bool = true {
        didSet {
            if oldValue != isToneMappingPermitted {
                updateEffectiveRenderMode()
            }
        }
    }
    let activeRenderModeLock = OSAllocatedUnfairLock(initialState: RenderMode.system)
    nonisolated public var activeRenderMode: RenderMode {
        activeRenderModeLock.withLock { $0 }
    }
    public var isMetalLayerVisible: Bool = false {
        didSet {
            let visible = isMetalLayerVisible
            isMetalLayerVisibleLock.withLock { $0 = visible }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalRenderer?.metalLayer.isHidden = !visible
            displayLayer.isHidden = visible
            CATransaction.commit()
        }
    }
    public var metalExposure: Float = 1.0 {
        didSet {
            metalRenderer?.uniforms.outputExposure = metalExposure
        }
    }
    public var metalShadowLift: Float = 0.0 {
        didSet {
            metalRenderer?.uniforms.outputShadowLift = metalShadowLift
        }
    }
    public var metalTargetNits: Float = 203.0 {
        didSet {
            metalRenderer?.uniforms.targetNits = metalTargetNits
            performanceMonitor.updateTargetNits(metalTargetNits)
        }
    }
    /// Content-adapted base reference white in nits (e.g. 203 for 1000-nit, ~116 for The Agency).
    public package(set) var baseAdaptiveTargetNits: Float = 203.0

    /// User scale multiplier adjusting the content-adaptive target white (default 1.0, range 0.5 ... 2.0 in UI, 0.1 ... 4.0 engine bound).
    public var targetNitsScale: Float = 1.0 {
        didSet {
            let clamped = max(0.1, min(4.0, targetNitsScale))
            if targetNitsScale != clamped {
                targetNitsScale = clamped
                return
            }
            targetNitsScaleLock.withLock { $0 = clamped }
            recomputeEffectiveTargetNits()
        }
    }
    @ObservationIgnored
    let targetNitsScaleLock = OSAllocatedUnfairLock(initialState: Float(1.0))

    /// Whether Dolby Vision L2 trims are applied on top of BT.2390 (see `PlayerConfiguration.applyDolbyVisionTrims`).
    /// A paused frame is re-rendered right away, so the change can be compared on the same frame.
    public var applyDolbyVisionTrims: Bool = false {
        didSet {
            guard applyDolbyVisionTrims != oldValue else { return }
            let enabled = applyDolbyVisionTrims
            let lastMetadata = dynamicToneMapLock.withLock {
                $0.appliesTrims = enabled
                return $0.lastDoviMetadata
            }
            guard !isPlaying, activeRenderMode == .metalToneMap, let lastMetadata else { return }
            _ = applyDynamicToneMap(doviMetadata: lastMetadata)
            metalRenderer?.redrawLastFrame()
        }
    }

    struct BaseDynamicToneMapState {
        var basePeakNits: Float = 1000.0
        var baseTargetNits: Float = 203.0
        var smoothedPeakNits: Float = 1000.0
        var smoothedTargetNits: Float = 203.0
        var lastRenderModeName: String = "Metal SDR"
        var appliesTrims = false
        /// RPU of the last tone-mapped frame, to re-render it when `appliesTrims` changes while paused.
        var lastDoviMetadata: DolbyVisionFrameMetadata?
    }
    @ObservationIgnored
    let dynamicToneMapLock = OSAllocatedUnfairLock(initialState: BaseDynamicToneMapState())

    func recomputeEffectiveTargetNits() {
        let base = baseAdaptiveTargetNits
        let effective = max(min(base * targetNitsScale, 500.0), 80.0)
        self.metalTargetNits = effective
        dynamicToneMapLock.withLock {
            // The base stays unscaled, as on load: tone mapping applies `targetNitsScale` to it.
            $0.baseTargetNits = base
            $0.smoothedTargetNits = effective
        }
    }

    public var metalSharpness: Float = 0.5 {
        didSet {
            metalRenderer?.uniforms.outputSharpness = metalSharpness
        }
    }

    public func applyConfiguration(_ config: PlayerConfiguration) {
        self.configuration = config
        self.isToneMappingPermitted = config.enableToneMapping
        self.targetNitsScale = config.targetNitsScale
        self.metalSharpness = config.sharpness
        self.applyDolbyVisionTrims = config.applyDolbyVisionTrims
        self.subtitleFontSize = config.subtitleFontSize
        self.subtitleFontName = config.subtitleFontName
        self.subtitleFontWeight = config.subtitleFontWeight
        self.subtitleTextColorHex = config.subtitleTextColorHex
        self.subtitleBgColorHex = config.subtitleBgColorHex
        self.subtitleBgOpacity = config.subtitleBgOpacity
        self.enableOSD = config.enableOSD
        self.seekStepSeconds = config.seekStepSeconds
        self.exactSeekOnSinglePress = config.exactSeekOnSinglePress
        self.playlist.setRepeatMode(config.playlistRepeatMode)
        self.playlist.setShuffle(config.playlistIsShuffled)
    }

    public var enableOSD: Bool = true
    public var seekStepSeconds: Double = 5.0
    public var exactSeekOnSinglePress: Bool = true

    // Audio properties
    public var volume: Float = 1.0 {
        didSet {
            audioRenderer.volume = isMuted ? 0.0 : volume
        }
    }
    public var isMuted: Bool = false {
        didSet {
            audioRenderer.volume = isMuted ? 0.0 : volume
        }
    }
    public var playbackRate: Double = 1.0 {
        didSet {
            let rounded = (playbackRate * 100).rounded() / 100.0
            let clamped = max(0.5, min(rounded, 4.0))
            if clamped != playbackRate {
                playbackRate = clamped
                return
            }
            playbackRateLock.withLock { $0 = clamped }
            // While prerolling the clock is intentionally held; the pending start picks up the new rate.
            let isPrerollPending = pendingClockStartLock.withLock { pending -> Bool in
                guard pending != nil else { return false }
                pending?.rate = clamped
                return true
            }
            // Buffering also holds the clock; its resume starts it at `playbackRate`.
            if isPlaying && !isPrerollPending && !isBuffering {
                let currentRate = playbackRate
                clockSettlingGuardLock.withLock { guardState in
                    guard var state = guardState else { return }
                    state.rate = currentRate
                    guardState = state
                }
                startSynchronizerClock(at: synchronizer.currentTime(), rate: currentRate, armGuard: false)
            }
        }
    }
    @ObservationIgnored
    let playbackRateLock = OSAllocatedUnfairLock(initialState: Double(1.0))
    public var audioTracks: [MediaDemuxer.AudioTrack] = [] {
        didSet {
            if oldValue != audioTracks { tracksDidChange() }
        }
    }
    public var selectedAudioTrackId: Int = -1 {
        didSet {
            if oldValue != selectedAudioTrackId { tracksDidChange() }
        }
    }

    public var subtitleTracks: [SubtitleTrack] = [] {
        didSet {
            if oldValue != subtitleTracks { tracksDidChange() }
        }
    }
    public var selectedSubtitleTrackId: Int? = nil {
        didSet {
            if oldValue != selectedSubtitleTrackId { tracksDidChange() }
        }
    }
    /// Called when the audio or subtitle tracks, or the selected ones, change: once by each load (when it is applied)
    /// and by a `stop()` that clears tracks, then by a track switch or an added subtitle file. Read the current tracks
    /// from the engine.
    public var onTracksChanged: (() -> Void)?
    /// Nesting depth of `beginDeferringTracksChanged()`; while above zero, track changes only mark
    /// `hasDeferredTracksChange`, reported once when the outermost deferral ends.
    @ObservationIgnored
    var tracksChangedDeferralDepth = 0
    @ObservationIgnored
    var hasDeferredTracksChange = false
    public var currentSubtitleCue: SubtitleCue? {
        currentSubtitleCues.first
    }
    public var currentSubtitleCues: [SubtitleCue] = []
    public var currentSubtitleText: String? {
        currentSubtitleCue?.text
    }
    public var subtitleFontSize: Double = 24.0
    public var subtitleFontName: String = "System Rounded"
    public var subtitleFontWeight: String = "Semibold"
    public var subtitleTextColorHex: String = "#FFFFFF"
    public var subtitleBgColorHex: String = "#000000"
    public var subtitleBgOpacity: Double = 0.65
    /// Seconds subtitles are shifted by: positive shows them later, negative earlier. Set with `setSubtitleDelay`.
    public internal(set) var subtitleDelay: Double = 0
    public static let subtitleDelayRange: ClosedRange<Double> = -30.0...30.0
    /// Seconds audio is shifted against the picture: positive plays it later, negative earlier. Set with
    /// `setAudioDelay`.
    public internal(set) var audioDelay: Double = 0
    /// Audio played early is read that far ahead of the picture, within the demuxer's video packet queue.
    public static let audioDelayRange: ClosedRange<Double> = -1.0...1.0
    var activeSubtitleDocument: SubtitleDocument? = nil
    var lastObservedLiveSubtitleVersion: Int = -1

    var loadedSubtitleDocuments: [Int: SubtitleDocument] = [:]
    var currentHeaders: [String: String] = [:]

    // MARK: - Decoupled video enqueue/flush via Objective-C selectors
    //
    // The display layer is deliberately NOT attached to `AVSampleBufferRenderSynchronizer`
    // (the synchronizer drives audio only, via `audioSink`). Frames are paced by
    // `CADisplayLink` and pushed as `CVPixelBuffer`s with `kCMSampleAttachmentKey_DisplayImmediately`.
    //
    // Why decoupled: on Apple Silicon a fullscreen `AVSampleBufferDisplayLayer` is promoted to
    // IOMFB Direct Scanout. When such a layer is attached to the synchronizer, `setRate(0.0)` on
    // pause can leave the display pipeline blocked on a hardware fence (`IOFenceTransaction`),
    // freezing WindowServer. Keeping the layer off the synchronizer means its rate is never set
    // to 0 — pause is just "stop ticking / stop enqueuing" — so that fence state cannot occur.
    //
    // Why `perform(selector:)` instead of `enqueue(_:)` / `flush()`: this is ONLY to suppress the
    // SDK deprecation warning. Apple deprecated the direct enqueue/flush APIs to push callers onto
    // `synchronizer.sampleBufferReceiver`, which requires the synchronizer attachment we avoid above.
    // The selector dispatch invokes the exact same underlying Objective-C IMP as `enqueue(_:)` — it
    // is NOT a workaround for any hardware deadlock, and calling `enqueue(_:)` directly would behave
    // identically at runtime. Do not "modernize" by migrating to the receiver API.
    nonisolated static let enqueueSampleBufferSelector = sel_registerName("enqueueSampleBuffer:")
    nonisolated static let flushSelector = sel_registerName("flush")
    nonisolated static let flushRemovingImageSelector = sel_registerName(
        "flushWithRemovalOfDisplayedImage:completionHandler:")

    /// C-function signature of `-[AVSampleBufferVideoRenderer enqueueSampleBuffer:]`.
    typealias EnqueueSampleBufferFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void

    /// IMP of `enqueueSampleBuffer:` resolved once at init, so the per-frame enqueue on the
    /// `CADisplayLink` hot path skips the `perform(_:with:)` autorelease/bridging overhead
    /// (mirrors `flushRemovingDisplayedImage`). `nil` only if the renderer somehow does not
    /// respond, in which case `enqueueToDisplayLayer` falls back to `perform`.
    let enqueueSampleBufferImp: EnqueueSampleBufferFn?

    /// Enqueues a ready sample buffer to the (synchronizer-decoupled) display layer. See the
    /// note above on why selector dispatch is used instead of `enqueue(_:)`.
    nonisolated func enqueueToDisplayLayer(_ sample: CMSampleBuffer) {
        displayLayerLock.lock()
        defer { displayLayerLock.unlock() }
        if let fn = enqueueSampleBufferImp {
            fn(sampleBufferRenderer, Self.enqueueSampleBufferSelector, sample)
        } else {
            _ = sampleBufferRenderer.perform(Self.enqueueSampleBufferSelector, with: sample)
        }
    }

    /// Flushes the display layer, keeping its current image unless `removingDisplayedImage`.
    nonisolated func flushDisplayLayer(removingDisplayedImage: Bool) {
        displayLayerLock.lock()
        defer { displayLayerLock.unlock() }
        if removingDisplayedImage {
            Self.flushRemovingDisplayedImage(sampleBufferRenderer)
        } else {
            _ = sampleBufferRenderer.perform(Self.flushSelector)
        }
    }

    /// Calls `flush(removingDisplayedImage: true)` via the Objective-C runtime.
    /// The display layer is not attached to the synchronizer (see note above), so the
    /// receiver-based replacement API is unavailable; selector dispatch avoids the deprecation warning.
    nonisolated static func flushRemovingDisplayedImage(_ renderer: NSObject) {
        typealias Fn = @convention(c) (AnyObject, Selector, Bool, @escaping @convention(block) () -> Void) -> Void
        guard renderer.responds(to: flushRemovingImageSelector),
            let imp = renderer.method(for: flushRemovingImageSelector)
        else {
            _ = renderer.perform(flushSelector)
            return
        }
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(renderer, flushRemovingImageSelector, true, {})
    }

    nonisolated(unsafe) public let displayLayer = AVSampleBufferDisplayLayer()
    nonisolated(unsafe) let sampleBufferRenderer: AVSampleBufferVideoRenderer
    /// Serializes enqueues and flushes: the display-link tick enqueues on its own thread
    /// (`DisplayLinkThread`) while seeks, previews and loads enqueue or flush on the main thread.
    @ObservationIgnored
    let displayLayerLock = OSAllocatedUnfairLock()
    @ObservationIgnored
    let cachedVideoFormatDescription = OSAllocatedUnfairLock<CMVideoFormatDescription?>(initialState: nil)
    public let metalRenderer = MetalVideoRenderer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    let audioSink: DelayedAudioSink
    var videoFeedingTask: Task<Void, Never>?
    var audioFeedingTask: Task<Void, Never>?
    var seekTask: Task<Void, Never>?

    var decoder: any VideoDecoderProtocol = VTVideoDecoder()
    /// Stalled decoders replaced for the current media; after the first, replacements decode in software.
    @ObservationIgnored
    var decoderStallRecoveries = 0
    /// Playback is on hold until media data arrives again: the clock stands while `isPlaying` stays set. See
    /// `PlayerEngine+Buffering`.
    public internal(set) var isBuffering = false {
        didSet {
            if oldValue != isBuffering {
                onBufferingChanged?(isBuffering)
            }
        }
    }
    /// Called when `isBuffering` changes. `playbackState` stays `.playing` while buffering.
    public var onBufferingChanged: ((_ isBuffering: Bool) -> Void)?
    @ObservationIgnored
    var bufferingResumeTask: Task<Void, Never>?
    var audioDecoder: FFAudioDecoder?
    let synchronizer = AVSampleBufferRenderSynchronizer()
    var demuxer: MediaDemuxer?
    let feedQueue = DispatchQueue(label: "com.nativeplayer.feed", qos: .userInteractive)
    let audioFeedQueue = DispatchQueue(label: "com.nativeplayer.audiofeed", qos: .userInteractive)
    let seekQueue = DispatchQueue(label: "com.nativeplayer.seek", qos: .userInteractive)
    var currentSeekId: Int = 0
    @ObservationIgnored
    let activeSeekId = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored
    let lastSyncDriftSpikeInstant = OSAllocatedUnfairLock<ContinuousClock.Instant>(initialState: .now - .seconds(10))
    @ObservationIgnored
    public package(set) var isSeeking: Bool = false
    @ObservationIgnored
    var chaseTargetTime: Double? = nil
    @ObservationIgnored
    var chaseExactSeek: Bool = true
    /// Minimum allowed PTS for step-frame seeking to guarantee advancing forward
    @ObservationIgnored
    var minStepFramePTS: Double? = nil
    /// True when the decoder and demuxer are positioned contiguously just past the current frame, so a
    /// forward frame step can decode incrementally (or serve an over-read frame) instead of re-seeking to
    /// the keyframe and re-decoding the whole GOP. Set after an exact seek settles paused; cleared whenever
    /// playback feeding resumes or a new demuxer seek repositions the pipeline.
    @ObservationIgnored
    var stepDecodeContiguous: Bool = false
    /// Keyframe-seek direction: forward seeks land on the next keyframe at/after the target.
    @ObservationIgnored
    var chaseForwardSeek: Bool = false
    @ObservationIgnored
    var resumePlaybackAfterChase: Bool = false
    @ObservationIgnored
    var chaseSettleTask: Task<Void, Never>? = nil
    static let relativeSeekBurstTimeout: Duration = .milliseconds(300)
    static let relativeSeekBurstWatchdogTimeout: Duration = .seconds(3)
    static let chaseSettleDebounceDuration: Duration = .milliseconds(300)

    // MARK: - Clock Settling & Sync Guards

    /// Transient guard protecting against `AVSampleBufferRenderSynchronizer` clock reporting staleness.
    ///
    /// Root cause: When `synchronizer.setRate(rate, time: targetTime)` is invoked (e.g. after loading a new
    /// media track or completing an asynchronous demuxer seek), CoreAudio hardware timebase re-anchoring
    /// happens asynchronously. For the first few milliseconds, `synchronizer.currentTime()` may still
    /// report the prior playback position (e.g. from the previous track or before the seek).
    ///
    /// Without this guard, `CADisplayLinkTick` observes an apparent multi-second drift between the stale clock
    /// and newly decoded frames starting at `targetTime`, causing `FrameQueue` to rapidly discard/drop all
    /// pre-buffered frames in a burst.
    struct ClockSettlingGuard: Sendable {
        let targetSeconds: Double
        let setHostTime: Double
        var rate: Double
    }
    @ObservationIgnored
    let clockSettlingGuardLock = OSAllocatedUnfairLock<ClockSettlingGuard?>(initialState: nil)

    /// Safety timeout (0.35s): unconditionally unblocks frame popping if hardware clock fails to settle promptly.
    nonisolated static let clockSettlingTimeoutSeconds: Double = 0.35

    /// Base tolerance (0.15s): dynamic allowable clock window `(rate * elapsedHost) + 0.15s` around targetTime.
    nonisolated static let clockSettlingBaseToleranceSeconds: Double = 0.15

    /// Threshold in milliseconds to log anomalous A/V sync drift spikes (throttled to 1/sec).
    nonisolated static let syncDriftSpikeThresholdMs: Double = 500.0

    /// Upper bound for projecting the clock forward to the display link's target vsync. Generous enough for a
    /// 24 Hz link; guards against a bogus `targetTimestamp` (e.g. right after a link is attached or resumed).
    nonisolated static let maxVsyncLookaheadSeconds: Double = 0.05

    /// Display-link timing kept between ticks to explain pipeline drops in the log (throttled to 1/sec).
    struct TickDiagnostics {
        var lastTargetTimestamp: CFTimeInterval = 0
        var unloggedDrops = 0
        var lastLogInstant: ContinuousClock.Instant = .now - .seconds(10)
        /// Clock read at the previous tick: unchanged while the synchronizer waits for audio after a start.
        var lastClockSeconds: Double = .nan
        var lastCallbackHost: CFTimeInterval = 0
        /// Target vsync of the last frame put up; 0 after a pause of the link.
        var lastPopTarget: CFTimeInterval = 0
        var sincePop = TicksSincePop()
    }

    /// What the display link did between two frames, logged when a frame stays up two ticks or more past its cadence:
    /// tells a link that stopped calling, a tick blocked on our side, and an empty queue (decoder or network) apart.
    struct TicksSincePop {
        var ticks = 0
        var emptyQueueTicks = 0
        var settlingHoldTicks = 0
        /// Ticks at which the clock had not moved since the previous one (paused, or waiting for audio to start).
        var stoppedClockTicks = 0
        var maxCallbackGap: CFTimeInterval = 0
        var maxTickDuration: CFTimeInterval = 0
        var maxClockRead: CFTimeInterval = 0
    }
    @ObservationIgnored
    let tickDiagnosticsLock = OSAllocatedUnfairLock(initialState: TickDiagnostics())
    /// Clock projected to the target vsync, with the per-tick jitter filtered out (see `DisplayClockSmoother`).
    @ObservationIgnored
    let displayClockSmootherLock = OSAllocatedUnfairLock(initialState: DisplayClockSmoother())
    /// Frame cadence on screen, logged every few seconds of playback (see `FrameCadenceStats`).
    @ObservationIgnored
    let frameCadenceLock = OSAllocatedUnfairLock(initialState: FrameCadenceStats())

    /// Tracks whether a rapid relative seek burst sequence is currently active.
    @ObservationIgnored
    var isRelativeSeekBurstActive: Bool = false
    @ObservationIgnored
    var isRelativeSeekInFlight: Bool = false
    @ObservationIgnored
    var relativeSeekBurstResetTask: Task<Void, Never>? = nil
    @ObservationIgnored
    var relativeSeekSessionStartTime: Double? = nil
    let audioRouteMonitor = AudioDeviceRouteMonitor()
    var timeObserver: Any?
    var lastSavedProgressSeconds: Double = 0.0
    var configuration: PlayerConfiguration
    /// Path or URL of the media loaded or loading, as normalized by `normalizeMediaPath`.
    public internal(set) var currentPath: String?
    public let historyStore: PlaybackHistoryStore
    public let playlist: PlaylistManager
    public let thumbnailManager = ThumbnailManager()
    @ObservationIgnored
    let isFeeding = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    let isMetalLayerVisibleLock = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    let isVideoDrainPaused = OSAllocatedUnfairLock(initialState: false)
    /// Presentation time of the first buffer the current audio feeding run handed to the renderer; `nil` until it
    /// has. Compared with the clock, it shows where audio resumed after a seek, track switch or pause.
    @ObservationIgnored
    let firstFedAudioPTS = OSAllocatedUnfairLock<CMTime?>(initialState: nil)
    /// Clock start deferred until the display-link tick has presented the anchor frame
    /// (see `startSynchronizerClockAfterPreroll`). Claimed exactly once by the tick or by the timeout.
    struct PendingClockStart: Sendable {
        var targetTime: CMTime
        var rate: Double
        let requestHostTime: Double
        /// Display-link callbacks since the request; explains a preroll timeout (0 → the link is not ticking).
        var displayLinkTicks = 0
    }
    @ObservationIgnored
    let pendingClockStartLock = OSAllocatedUnfairLock<PendingClockStart?>(initialState: nil)
    @ObservationIgnored
    var prerollTimeoutTask: Task<Void, Never>? = nil
    public var showDebugHUD: Bool = false {
        didSet {
            if showDebugHUD {
                currentMetrics = performanceMonitor.currentMetrics
            }
        }
    }
    public var currentMetrics: PlayerPerformanceMonitor.Metrics = PlayerPerformanceMonitor.Metrics()
    public let performanceMonitor = PlayerPerformanceMonitor.shared
    var metricsTimer: (any DispatchSourceTimer)?

    let frameQueue = FrameQueue()
    /// Lazily-populated window of decoded frames around the current position for cheap paused frame-stepping
    /// in both directions. Empty during normal playback; populated while paused-stepping and held until
    /// playback resumes or a seek repositions the pipeline (cleared on resume, reseek, reload, or stop).
    let stepFrameCache = StepFrameCache(capacity: 32)
    /// True while a forward step pump is decoding on `seekQueue`. Guards against key-repeat presses falling
    /// through to a heavy keyframe re-seek mid-pump; extra presses are ignored until the pump completes.
    @ObservationIgnored
    var isStepPumping: Bool = false
    /// True once the playback cursor has drifted from the last seek baseline via frame-stepping. On resume
    /// the demuxer/decoder sit ahead of the cursor and audio before the baseline was purged, so `play()`
    /// reseeks to `currentTime` to restore clean A/V alignment. Cleared by any seek, load, or resume.
    @ObservationIgnored
    var didStepSincePause: Bool = false
    public var currentFramePTS: Double {
        frameQueue.getLastRenderedPTS()
    }
    public var droppedFramesCount: Int {
        frameQueue.droppedFramesCount
    }
    public var pipelineDroppedFramesCount: Int {
        frameQueue.pipelineDroppedFramesCount
    }
    public var speedSkippedFramesCount: Int {
        frameQueue.speedSkippedFramesCount
    }
    /// Returns the most recently presented pixel buffer.
    /// Internal for test verification and debugging inspection.
    func getLastRenderedBuffer() -> CVPixelBuffer? {
        frameQueue.getLastRenderedBuffer()
    }
    var displayLink: CADisplayLink?
    var displayLinkTarget: DisplayLinkTarget?
    /// View the display link follows, used to resolve its current screen.
    @ObservationIgnored weak var displayLinkHostView: NSView?

    final class DisplayLinkTarget: NSObject, @unchecked Sendable {
        private weak var engine: PlayerEngine?

        init(engine: PlayerEngine) {
            self.engine = engine
            super.init()
        }

        @objc func onTick(_ link: CADisplayLink) {
            engine?.displayLinkTick(targetTimestamp: link.targetTimestamp, tickInterval: link.duration)
        }
    }

    public convenience init() {
        self.init(configuration: PlayerConfiguration())
    }

    /// - Parameters:
    ///   - userDefaults: Where the engine persists playback history and the playlist's repeat / shuffle state.
    ///   - durationCache: Where playlist durations are cached (`.shared` persists them under Caches).
    ///
    /// A host embedding the engine, or a test, passes its own stores to keep these out of the app's.
    public init(
        configuration: PlayerConfiguration, userDefaults: UserDefaults = .standard,
        durationCache: MediaDurationCache = .shared
    ) {
        self.configuration = configuration
        self.historyStore =
            userDefaults === UserDefaults.standard ? .shared : PlaybackHistoryStore(userDefaults: userDefaults)
        self.renderMode = configuration.defaultRenderMode
        self.isToneMappingPermitted = configuration.enableToneMapping
        self.targetNitsScale = configuration.targetNitsScale
        self.targetNitsScaleLock.withLock { $0 = configuration.targetNitsScale }
        self.baseAdaptiveTargetNits = 203.0
        let effectiveNits = max(min(203.0 * configuration.targetNitsScale, 500.0), 80.0)
        self.metalTargetNits = effectiveNits
        self.metalSharpness = configuration.sharpness
        self.applyDolbyVisionTrims = configuration.applyDolbyVisionTrims
        self.dynamicToneMapLock.withLock { $0.appliesTrims = configuration.applyDolbyVisionTrims }
        self.volume = configuration.initialVolume
        self.subtitleFontSize = configuration.subtitleFontSize
        self.subtitleFontName = configuration.subtitleFontName
        self.subtitleFontWeight = configuration.subtitleFontWeight
        self.subtitleTextColorHex = configuration.subtitleTextColorHex
        self.subtitleBgColorHex = configuration.subtitleBgColorHex
        self.subtitleBgOpacity = configuration.subtitleBgOpacity
        self.enableOSD = configuration.enableOSD
        self.seekStepSeconds = configuration.seekStepSeconds
        self.exactSeekOnSinglePress = configuration.exactSeekOnSinglePress
        self.playlist = PlaylistManager(
            repeatMode: configuration.playlistRepeatMode,
            isShuffled: configuration.playlistIsShuffled,
            userDefaults: userDefaults,
            durationCache: durationCache
        )

        metalRenderer?.uniforms.targetNits = effectiveNits
        metalRenderer?.uniforms.outputSharpness = configuration.sharpness
        let renderer = displayLayer.sampleBufferRenderer
        self.sampleBufferRenderer = renderer
        if renderer.responds(to: Self.enqueueSampleBufferSelector),
            let imp = renderer.method(for: Self.enqueueSampleBufferSelector)
        {
            self.enqueueSampleBufferImp = unsafeBitCast(imp, to: EnqueueSampleBufferFn.self)
        } else {
            self.enqueueSampleBufferImp = nil
        }
        // Synchronizer drives the audio renderer and the master clock timeline
        self.audioSink = DelayedAudioSink(
            wrapping: BufferTrackingAudioSink(
                wrapping: makeAudioRendererSink(renderer: audioRenderer, synchronizer: synchronizer)))
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        displayLayer.videoGravity = .resizeAspect

        let queue = self.frameQueue
        decoder.setOutputHandler { frame in
            if !frame.doNotDisplay {
                queue.push(frame)
            }
        }

        setupDisplayLink()
        setupAudioObservers()
        updateEffectiveRenderMode()
        setupMetricsMonitoring()

        // Update playback position at 10 Hz (every 100ms, matching IINA AppData.syncTimeInterval = 0.1s)
        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main)
        { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Do not overwrite currentTime while a seek is in flight, chasing a target, or before playback starts
                guard
                    self.chaseTargetTime == nil && !self.isSeeking && self.isLoaded && !self.isLoading
                        && self.isPlaying
                else { return }
                // Re-read the clock NOW: the callback's `time` argument may be stale (captured before a
                // seek settled), which would roll the UI position back to a pre-seek value.
                let seconds = CMTimeGetSeconds(self.synchronizer.currentTime())
                if !seconds.isNaN && !seconds.isInfinite && seconds >= 0 {
                    self.currentTime = seconds
                    self.onTimeUpdate?(seconds, self.duration)

                    // Update active subtitle cues
                    self.updateActiveSubtitles(at: seconds)
                    self.checkForStarvation()

                    // Check if playback reached the end
                    if self.isPlaying && self.duration > 0 && seconds >= (self.duration - 0.25) {
                        self.handleEndOfMedia()
                    }
                    // Throttled periodic progress auto-save every 15 seconds
                    if abs(seconds - self.lastSavedProgressSeconds) >= 15.0 {
                        self.lastSavedProgressSeconds = seconds
                        self.saveCurrentPlaybackProgress()
                    }
                }
            }
        }
    }

    func handleEndOfMedia() {
        stopPlaybackPipeline()
        saveCurrentPlaybackProgress()
        // Repeating is not an end: going through `.completed` would report `onPlaybackEnded` to the host while
        // the same media starts again. With the host's queue the playlist's repeat mode doesn't apply.
        if onTrackNavigation == nil, playlist.repeatMode == .one {
            AppLog.info(.engine, "Repeating current item (repeatMode: .one)")
            seek(to: 0)
            play()
            return
        }
        playbackState = .completed
        handlePlaybackCompleted()
    }

    func handlePlaybackCompleted() {
        if onTrackNavigation != nil {
            AppLog.info(.engine, "Playback completed; the host's queue decides what plays next")
        } else if playlist.autoPlayNext, let nextItem = playlist.playNext() {
            AppLog.info(.engine, "Auto-advancing to next playlist item: '\(nextItem.title)'")
            load(item: nextItem)
        } else {
            AppLog.info(.engine, "Playback completed naturally (end of playlist)")
        }
    }

    func setupAudioObservers() {
        // Monitor system-wide default audio device changes (e.g. connecting AirPods, Bluetooth, or HDMI)
        audioRouteMonitor.startMonitoring { [weak self] newUID in
            self?.handleAudioDeviceRouteChange(newUID: newUID)
        }
    }

    func handleAudioDeviceRouteChange(newUID: String?) {
        AppLog.info(
            .audio,
            "Default audio output device route changed (UID: \(newUID ?? "nil [system default]"))"
        )
        // Explicitly update target output device UID to trigger CoreAudio re-binding
        audioRenderer.audioOutputDeviceUniqueID = newUID
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        audioRenderer.audioTimePitchAlgorithm = .timeDomain

        if isPlaying {
            audioSink.flush()
            audioDecoder?.flush()
        }
    }

    func setupMetricsMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.showDebugHUD else { return }
            let statusDesc = self.isPlaying ? "Rendering" : "Paused"
            self.performanceMonitor.updateNativeLayerStatus(statusDesc)

            // Gather Mach kernel metrics on a low-priority utility queue to keep Main Thread 100% free
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                self.performanceMonitor.updateProcessMetrics()
                let metrics = self.performanceMonitor.currentMetrics
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.showDebugHUD else { return }
                    self.currentMetrics = metrics
                }
            }
        }
        timer.resume()
        self.metricsTimer = timer
    }

    isolated deinit {
        stop()
        displaySleepManager.enableDisplaySleep()
        seekTask?.cancel()
        seekTask = nil
        prerollTimeoutTask?.cancel()
        prerollTimeoutTask = nil
        if let observer = timeObserver {
            synchronizer.removeTimeObserver(observer)
        }
        audioRouteMonitor.stopMonitoring()
        displayLink?.invalidate()
        displayLink = nil
        metricsTimer?.cancel()
        metricsTimer = nil
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
    }
}
