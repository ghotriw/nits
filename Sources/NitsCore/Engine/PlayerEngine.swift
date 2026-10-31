@preconcurrency import AVFoundation
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
            actionButtons.updateActive()
        }
    }
    /// The action buttons of the media ("Skip Intro", "Next Episode", SponsorBlock segments) and the one playback is
    /// in.
    public let actionButtons = ActionButtonController()
    /// Resolves the pages a load is given (a video site's) into the streams that play them; `nil` opens every URL as
    /// is. Asked for network URLs only, before the demuxer opens (`MediaResolver`).
    @ObservationIgnored
    public var mediaResolver: (any MediaResolver)?
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
    /// What describes the media loaded (duration, chapters, the video stream); empty while none is.
    public internal(set) var media = MediaInfo() {
        didSet {
            if oldValue.hasVideo != media.hasVideo {
                displaySleepManager.update(isPlaying: isPlaying, hasVideo: media.hasVideo)
            }
            if oldValue.video.isHDR != media.video.isHDR { updateEffectiveRenderMode() }
            if oldValue.chapters != media.chapters {
                currentChapterIndex = nil
                updateCurrentChapterIndex()
            }
        }
    }
    /// Index into `media.chapters` of the chapter at `currentTime`; `nil` before the first one or without chapters.
    public internal(set) var currentChapterIndex: Int?
    public var pendingSeekTime: Double? { chase?.seconds }
    public var isPlaying: Bool = false {
        didSet {
            displaySleepManager.update(isPlaying: isPlaying, hasVideo: media.hasVideo)
        }
    }
    public var isLoaded: Bool = false {
        didSet {
            actionButtons.updateActive()
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
    /// Called when a media finishes loading, a playlist item included: `(request, historyKey, title, duration)`; for
    /// the first item of a playlist file, then again for the file, with its path as `historyKey` and no duration.
    public var onMediaLoaded:
        ((_ request: MediaLoadRequest, _ historyKey: String, _ title: String, _ duration: Double) -> Void)?
    /// Callback fired when an in-flight relative seek settles onto its final keyframe or exact PTS
    public var onRelativeSeekResolved: ((_ offset: Double, _ currentTime: Double) -> Void)?

    var loadingTask: Task<Void, Never>?
    var currentInterruptContext: MediaDemuxer.InterruptContext?
    var currentLoadID = UUID()
    public var mediaTitle: String = ""
    public var artworkData: Data? = nil
    public var artworkURL: URL? = nil
    public let displaySleepManager = DisplaySleepManager()
    public var isDisplaySleepDisabled: Bool {
        displaySleepManager.isSleepDisabled
    }
    public var nominalFrameDuration: Double = 1.0 / 24.0
    @ObservationIgnored
    let nominalFrameDurationLock = OSAllocatedUnfairLock(initialState: 1.0 / 24.0)
    /// `MediaDemuxer.videoStartTime`, for the display-link preroll.
    @ObservationIgnored
    let videoStartTimeLock = OSAllocatedUnfairLock(initialState: 0.0)
    /// Aspect ratio override, crop, scaling, zoom and pan of the picture. Presentation only: the host view lays the
    /// video layers out from it, nothing else in the pipeline changes.
    public var videoGeometry = VideoGeometrySettings() {
        didSet {
            guard oldValue != videoGeometry else { return }
            videoHost?.setNeedsVideoLayout(immediately: false)
            // libass draws for the picture's pixel aspect, which a forced aspect ratio changes even when the
            // area drawn on keeps its size (Stretch).
            if oldValue.aspectRatio != videoGeometry.aspectRatio { subtitles.videoDidChange() }
        }
    }
    /// Display aspect ratio of the picture as shown: `displayAspectRatio` with the aspect override and crop of
    /// `videoGeometry` applied.
    public var contentAspectRatio: Double {
        VideoGeometry.contentAspectRatio(
            videoWidth: media.video.width, videoHeight: media.video.height,
            sampleAspectRatio: media.video.sampleAspectRatio,
            settings: videoGeometry)
    }
    public var renderMode: RenderMode = .auto {
        didSet {
            updateEffectiveRenderMode()
        }
    }
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
            recreateDisplayLink()
        }
    }
    /// How the host view lays out `displayLayer` around Picture in Picture; `nil` fills the host view.
    public var pictureInPictureLayerGeometry: PictureInPictureLayerGeometry? {
        didSet {
            guard oldValue != pictureInPictureLayerGeometry else { return }
            // The host window is usually ordered out during PiP and would not lay out on its own.
            videoHost?.setNeedsVideoLayout(immediately: true)
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

    public func applyConfiguration(_ config: PlayerConfiguration) {
        let previous = configuration
        let previousVideoScaling = previous.videoScaling
        self.configuration = config
        self.historyStore.exclusionPolicy = config.historyExclusionPolicy
        self.isToneMappingPermitted = config.enableToneMapping
        toneMapping.apply(config, previous: previous)
        subtitles.apply(config)
        self.seekStepSeconds = config.seekStepSeconds
        self.exactSeekOnSinglePress = config.exactSeekOnSinglePress
        // Only a new default replaces the scaling chosen for the session.
        if config.videoScaling != previousVideoScaling {
            self.videoGeometry.scaling = config.videoScaling
        }
    }

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
    /// Set through `setPlaybackRate`, which saves it with the media (`playbackRateMemory`).
    public internal(set) var playbackRate: Double = 1.0 {
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
            // Buffering also holds the clock; its resume starts it at `playbackRate`, as a load's start still running
            // (`isLoadStartPending`) does.
            if isPlaying && !isPrerollPending && !isBuffering && !isLoadStartPending {
                let currentRate = playbackRate
                clockSettlingGuardLock.withLock { guardState in
                    guard var state = guardState else { return }
                    state.rate = currentRate
                    guardState = state
                }
                startSynchronizerClock(
                    at: playbackClock.currentTime(), rate: currentRate, armGuard: false, keepsRunning: true)
            }
        }
    }
    @ObservationIgnored
    let playbackRateLock = OSAllocatedUnfairLock(initialState: Double(1.0))
    /// Whether `playbackRate` is the current media's, to save with it; reset with the media.
    @ObservationIgnored
    var playbackRateMemory = PlaybackRateMemory()
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

    /// Reads local files ahead as well, as network sources are (`MediaDemuxer.startReadAhead`): for tests, which play
    /// local files only. Set by `NITS_READ_AHEAD_LOCAL=1`.
    nonisolated static let readsAheadLocalFiles = ProcessInfo.processInfo.environment["NITS_READ_AHEAD_LOCAL"] == "1"

    /// What the resolver found for the page playing, with the request that asked (`selectVideoFormat`); `nil` for media
    /// that wasn't resolved. Cleared by `resetMediaState`.
    public internal(set) var resolvedSource: ResolvedSource?

    /// The pictures the page offers as files of their own, best first; empty for anything else.
    public var videoFormats: [VideoFormat] { resolvedSource?.media.videoFormats ?? [] }
    /// The one playing, when it is one of `videoFormats`.
    public var selectedVideoFormatId: String? { resolvedSource?.media.selectedVideoFormatID }

    /// The variants of an HLS master playlist, highest bandwidth first; empty for anything else.
    public var variants: [MediaDemuxer.StreamVariant] = [] {
        didSet {
            if oldValue != variants { tracksDidChange() }
        }
    }
    /// The variant chosen: set by `selectVariant(id:)` at once, by the demuxer when its pictures start playing.
    public var selectedVariantId: Int? {
        didSet {
            if oldValue != selectedVariantId { tracksDidChange() }
        }
    }
    /// Adaptive bitrate can choose the variant: a network source (read ahead) with variants.
    public internal(set) var canSelectAutomaticVariant = false
    /// Adaptive bitrate chooses the variant (network sources with variants, until `selectVariant(id:)`).
    public internal(set) var isVariantAutomatic = false {
        didSet {
            if oldValue != isVariantAutomatic { tracksDidChange() }
        }
    }
    /// Variants the demuxer reads ahead, by the timeline second their pictures play from (`variantWillPlay`).
    @ObservationIgnored
    var pendingVariantChanges: [MediaDemuxer.VariantChange] = []

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
    /// A load cleared the previous media's tracks without reporting it (`resetMediaState`): the next report is owed,
    /// by the new media's tracks or by whatever ends the load instead (a failure, a cancel, `stop()`).
    @ObservationIgnored
    var tracksClearedUnreported = false
    /// The media's subtitle tracks, what of them is on screen and how it is drawn.
    public let subtitles: SubtitleController
    /// Tone mapping of the Metal path: the user's adjustments and the curve adapted to the media and its frames.
    public let toneMapping: ToneMapController
    /// Seconds audio is shifted against the picture: positive plays it later, negative earlier. Set with
    /// `setAudioDelay`.
    public internal(set) var audioDelay: Double = 0
    /// Audio played early is read that far ahead of the picture, within the demuxer's video packet queue.
    public static let audioDelayRange: ClosedRange<Double> = -1.0...1.0
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

    @available(*, deprecated, renamed: "MediaURL.normalizeMediaPath")
    nonisolated public static func normalizeMediaPath(_ path: String) -> String {
        MediaURL.normalizeMediaPath(path)
    }

    nonisolated(unsafe) public let displayLayer = AVSampleBufferDisplayLayer()
    nonisolated(unsafe) let sampleBufferRenderer: AVSampleBufferVideoRenderer
    /// Serializes enqueues and flushes: the display-link tick enqueues on its own thread
    /// (`DisplayLinkThread`) while seeks, previews and loads enqueue or flush on the main thread.
    @ObservationIgnored
    let displayLayerLock = OSAllocatedUnfairLock()
    @ObservationIgnored
    let cachedVideoFormatDescription = OSAllocatedUnfairLock<CMVideoFormatDescription?>(initialState: nil)
    public let metalRenderer: MetalVideoRenderer?
    public let audioRenderer = AVSampleBufferAudioRenderer()
    let audioSink: DelayedAudioSink
    var videoFeedingTask: Task<Void, Never>?
    var audioFeedingTask: Task<Void, Never>?

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
    /// Watches for the audio renderer holding back audio that is already due; see `PlayerEngine+AudioLag`.
    @ObservationIgnored
    var audioLagDetector = AudioLagDetector()
    /// Watches for the audio output device stopping its IO under a running clock; see `PlayerEngine+AudioLag`. Locked:
    /// clock starts (`startSynchronizerClock`) and the device's notifications come off the main actor.
    @ObservationIgnored
    let audioOutputInterruptionLock = OSAllocatedUnfairLock(initialState: AudioOutputInterruptionDetector())
    var audioDecoder: FFAudioDecoder?
    nonisolated let playbackClock = PlaybackClock()
    nonisolated var synchronizer: AVSampleBufferRenderSynchronizer { playbackClock.synchronizer }
    /// The inputs the media plays from: its own and audio files added to it; audio is read through it.
    var inputs: PlaybackInputs?
    /// The media's own input (`inputs.main`): the picture, subtitles, variants.
    var demuxer: MediaDemuxer? { inputs?.main }
    let feedQueue = DispatchQueue(label: "com.nativeplayer.feed", qos: .userInteractive)
    let audioFeedQueue = DispatchQueue(label: "com.nativeplayer.audiofeed", qos: .userInteractive)
    let seekQueue = DispatchQueue(label: "com.nativeplayer.seek", qos: .userInteractive)
    @ObservationIgnored
    let seekGeneration = SeekGeneration()
    @ObservationIgnored
    let lastSyncDriftSpikeInstant = OSAllocatedUnfairLock<ContinuousClock.Instant>(initialState: .now - .seconds(10))
    public package(set) var isSeeking: Bool = false {
        didSet { reportSeekingChange() }
    }
    /// True while playback is waiting for the chase-settle debounce or preroll before starting the clock.
    package internal(set) var isAwaitingClockStart: Bool = false
    /// The position seeks are chasing, until the last of them settles. See `PlayerEngine+Seeking`.
    @ObservationIgnored
    var chase: ChaseTarget? = nil {
        didSet {
            reportSeekingChange()
            updateAwaitingClockStart()
        }
    }
    /// Called when a seek starts and when it settles: `isSeeking || pendingSeekTime != nil` changes. A burst of seeks
    /// (and the chase to its latest target) reports once each way; a playing seek settles just before the clock
    /// restarts. Frame steps that decode or seek report it too; steps served from the step cache present at once,
    /// without it.
    public var onSeekingChanged: ((_ isSeeking: Bool) -> Void)?
    /// The seek state last reported through `onSeekingChanged`.
    @ObservationIgnored
    var reportedSeeking = false
    @ObservationIgnored
    var resumePlaybackAfterChase: Bool = false
    /// A load is applied, and its start (the demuxer's start position, the decoder's flush) still runs on `seekQueue`:
    /// `play()` leaves starting to it, as the feeders would read from before the start position.
    @ObservationIgnored
    var isLoadStartPending = false
    @ObservationIgnored
    var chaseSettleTask: Task<Void, Never>? = nil
    static let relativeSeekBurstTimeout: Duration = .milliseconds(300)
    static let relativeSeekBurstWatchdogTimeout: Duration = .seconds(3)
    @ObservationIgnored
    var chaseSettling = ChaseSettling()

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

    @ObservationIgnored
    var relativeSeekBurst = RelativeSeekBurst()
    /// Ends `relativeSeekBurst` once its seeks have stopped coming.
    @ObservationIgnored
    var relativeSeekBurstResetTask: Task<Void, Never>? = nil
    let audioOutputRoute = PlatformAudioOutputRoute()
    var timeObserver: Any?
    var lastSavedProgressSeconds: Double = 0.0
    var configuration: PlayerConfiguration
    /// Path or URL of the media loaded or loading, as normalized by `MediaURL.normalizeMediaPath`.
    public internal(set) var currentPath: String?
    /// Path or URL of the stream the demuxer opened, which `currentHeaders` go with: `currentPath`, or the stream a
    /// `mediaResolver` found for it. What reads the media again (thumbnails, embedded subtitles) opens this one.
    public internal(set) var currentSourcePath: String?
    /// What the media loaded is saved as in the history: `currentPath`, or a resolver's name for the page's media
    /// (`ResolvedMedia.historyKey`).
    var currentHistoryKey: String?
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
        /// Output latency to pin the start ahead by, when the renderer already holds audio (see
        /// `startSynchronizerClockAfterPreroll`).
        var startDelay: TimeInterval = 0
        /// The audio renderer has not been refilled after a flush: the tick leaves the start to `isAudioReadyToStart`'s
        /// wait (`awaitAudioBeforeClockStart`), which clears this.
        var awaitsAudio = false
    }
    @ObservationIgnored
    let pendingClockStartLock = OSAllocatedUnfairLock<PendingClockStart?>(initialState: nil)
    @ObservationIgnored
    var prerollTimeoutTask: Task<Void, Never>? = nil
    @ObservationIgnored
    var prerollAudioTask: Task<Void, Never>? = nil
    /// Refreshes `currentMetrics` twice a second, with the process's CPU and memory, for a view showing them (the
    /// performance HUD); off, they change only when media loads, and no timer runs.
    public var isCollectingMetrics: Bool = false {
        didSet {
            guard isCollectingMetrics != oldValue else { return }
            if isCollectingMetrics {
                startMetricsTimer()
            } else {
                metricsTimer?.cancel()
                metricsTimer = nil
            }
        }
    }
    public var currentMetrics: PlayerPerformanceMonitor.Metrics = PlayerPerformanceMonitor.Metrics()
    public let performanceMonitor = PlayerPerformanceMonitor.shared
    @ObservationIgnored
    var metricsTimer: (any DispatchSourceTimer)?

    let frameQueue = FrameQueue()
    @ObservationIgnored
    let frameStep = FrameStepState()
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
    /// `VideoHost.screenIdentity` when `displayLink` was made: a link for a screen the host has left is replaced.
    var displayLinkScreen: AnyHashable?
    var displayLinkTarget: DisplayLinkTarget?
    /// View showing the video: the display link follows it, geometry changes lay it out.
    @ObservationIgnored weak var videoHost: (any VideoHost)?

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
    /// With `.standard`, `historyStore` is `PlaybackHistoryStore.shared`, whose exclusion policy only
    /// `applyConfiguration` changes; other `userDefaults` get a store of their own with `configuration`'s
    /// policy.
    public init(
        configuration: PlayerConfiguration, userDefaults: UserDefaults = .standard,
        durationCache: MediaDurationCache = .shared
    ) {
        self.configuration = configuration
        if userDefaults === UserDefaults.standard {
            self.historyStore = .shared
        } else {
            self.historyStore = PlaybackHistoryStore(
                userDefaults: userDefaults,
                exclusionPolicy: configuration.historyExclusionPolicy
            )
        }
        self.renderMode = configuration.defaultRenderMode
        self.isToneMappingPermitted = configuration.enableToneMapping
        let metalRenderer = MetalVideoRenderer()
        self.metalRenderer = metalRenderer
        let toneMapping = ToneMapController(renderer: metalRenderer, monitor: PlayerPerformanceMonitor.shared)
        toneMapping.apply(configuration)
        self.toneMapping = toneMapping
        self.volume = configuration.initialVolume
        let subtitles = SubtitleController()
        subtitles.apply(configuration)
        self.subtitles = subtitles
        self.seekStepSeconds = configuration.seekStepSeconds
        self.exactSeekOnSinglePress = configuration.exactSeekOnSinglePress
        self.playlist = PlaylistManager(
            userDefaults: userDefaults,
            durationCache: durationCache
        )

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
        let audioOutputInterruption = audioOutputInterruptionLock
        self.audioSink = DelayedAudioSink(
            wrapping: BufferTrackingAudioSink(
                wrapping: makeAudioRendererSink(renderer: audioRenderer, synchronizer: playbackClock.synchronizer),
                onFlush: { audioOutputInterruption.withLock { $0.rendererFlushed() } }))
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        displayLayer.videoGravity = .resizeAspect
        videoGeometry.scaling = configuration.videoScaling

        decoder.outputDisplayableFrames(to: frameQueue)

        subtitles.host = self
        toneMapping.host = self
        actionButtons.host = self
        setupDisplayLink()
        setupAudioObservers()
        updateEffectiveRenderMode()

        // Update playback position at 10 Hz (every 100ms, matching IINA AppData.syncTimeInterval = 0.1s)
        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main)
        { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Do not overwrite currentTime while a seek is in flight, chasing a target, or before playback starts
                guard
                    self.chase == nil && !self.isSeeking && self.isLoaded && !self.isLoading
                        && self.isPlaying
                else { return }
                // Re-read the clock NOW: the callback's `time` argument may be stale (captured before a
                // seek settled), which would roll the UI position back to a pre-seek value.
                let seconds = CMTimeGetSeconds(self.playbackClock.currentTime())
                if !seconds.isNaN && !seconds.isInfinite && seconds >= 0 {
                    self.currentTime = seconds
                    self.onTimeUpdate?(seconds, self.media.duration)

                    self.applyDueVariantChanges(at: seconds)
                    self.subtitles.timeDidChange(to: seconds, .tick)
                    self.checkForStarvation()
                    self.checkForAudioRendererLag()

                    // Check if playback reached the end
                    if self.isPlaying && self.isAtEndOfMedia(seconds) {
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

    /// Whether playback at `seconds` has reached the end: within the last quarter second, where the last frames and
    /// audio packets of a stream end apart.
    func isAtEndOfMedia(_ seconds: Double) -> Bool {
        media.duration > 0 && seconds >= media.duration - 0.25
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
        audioOutputRoute.startMonitoring(
            binding: audioRenderer,
            onChange: { [weak self] in self?.handleAudioOutputRouteChange() },
            onRunningChange: { [weak self] isRunning in self?.audioOutputRunningChanged(isRunning) })
    }

    /// The renderer has just moved to a new output (see `AudioOutputRoute`).
    func handleAudioOutputRouteChange() {
        audioOutputInterruptionLock.withLock { $0.outputDeviceChanged() }
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        audioRenderer.audioTimePitchAlgorithm = .timeDomain

        if isPlaying {
            audioSink.flush()
            audioDecoder?.flush()
        }
    }

    /// Ticks at once, so the process metrics shown first are current, then every 0.5 s.
    private func startMetricsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.isCollectingMetrics else { return }
            let statusDesc = self.isPlaying ? "Rendering" : "Paused"
            self.performanceMonitor.updateNativeLayerStatus(statusDesc)

            // Gather Mach kernel metrics on a low-priority utility queue to keep Main Thread 100% free
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                self.performanceMonitor.updateProcessMetrics()
                let metrics = self.performanceMonitor.currentMetrics
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCollectingMetrics else { return }
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
        prerollTimeoutTask?.cancel()
        prerollTimeoutTask = nil
        prerollAudioTask?.cancel()
        prerollAudioTask = nil
        if let observer = timeObserver {
            synchronizer.removeTimeObserver(observer)
        }
        audioOutputRoute.stopMonitoring()
        displayLink?.invalidate()
        displayLink = nil
        metricsTimer?.cancel()
        metricsTimer = nil
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
    }
}

extension PlayerEngine: ActionButtonHost {}
