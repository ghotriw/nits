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
    public var currentTime: Double = 0
    public var pendingSeekTime: Double? { chaseTargetTime }
    public var duration: Double = 0
    public var isPlaying: Bool = false {
        didSet {
            displaySleepManager.update(isPlaying: isPlaying, hasVideo: hasVideo)
        }
    }
    public var isLoaded: Bool = false
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

    struct BaseDynamicToneMapState {
        var basePeakNits: Float = 1000.0
        var baseTargetNits: Float = 203.0
        var smoothedPeakNits: Float = 1000.0
        var smoothedTargetNits: Float = 203.0
        var lastRenderModeName: String = "Metal SDR"
    }
    @ObservationIgnored
    let dynamicToneMapLock = OSAllocatedUnfairLock(initialState: BaseDynamicToneMapState())

    func recomputeEffectiveTargetNits() {
        let effective = max(min(baseAdaptiveTargetNits * targetNitsScale, 500.0), 80.0)
        self.metalTargetNits = effective
        dynamicToneMapLock.withLock {
            $0.baseTargetNits = effective
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
        self.subtitleFontSize = config.subtitleFontSize
        self.subtitleFontName = config.subtitleFontName
        self.subtitleFontWeight = config.subtitleFontWeight
        self.subtitleTextColorHex = config.subtitleTextColorHex
        self.subtitleBgColorHex = config.subtitleBgColorHex
        self.subtitleBgOpacity = config.subtitleBgOpacity
        self.enableOSD = config.enableOSD
        self.seekStepSeconds = config.seekStepSeconds
        self.exactSeekOnSinglePress = config.exactSeekOnSinglePress
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
            if isPlaying {
                synchronizer.setRate(Float(playbackRate), time: synchronizer.currentTime())
            }
        }
    }
    public var audioTracks: [MediaDemuxer.AudioTrack] = []
    public var selectedAudioTrackId: Int = -1

    public var subtitleTracks: [SubtitleTrack] = []
    public var selectedSubtitleTrackId: Int? = nil
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
    var activeSubtitleDocument: SubtitleDocument? = nil
    var lastObservedLiveSubtitleVersion: Int = -1

    var loadedSubtitleDocuments: [Int: SubtitleDocument] = [:]
    var currentHeaders: [String: String] = [:]

    nonisolated static let enqueueSampleBufferSelector = sel_registerName("enqueueSampleBuffer:")
    nonisolated static let flushSelector = sel_registerName("flush")
    nonisolated static let flushRemovingImageSelector = sel_registerName(
        "flushWithRemovalOfDisplayedImage:completionHandler:")

    /// Calls `flush(removingDisplayedImage: true)` via the Objective-C runtime.
    /// The display layer is deliberately NOT attached to the render synchronizer (see video_architecture.md 3.1),
    /// so the receiver-based replacement API is unavailable; this avoids the deprecation warning.
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
    public let metalRenderer = MetalVideoRenderer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    public let audioReceiver: AVSampleBufferAudioRenderer.Receiver
    var videoFeedingTask: Task<Void, Never>?
    var audioFeedingTask: Task<Void, Never>?
    var seekTask: Task<Void, Never>?

    var decoder: any VideoDecoderProtocol = VTVideoDecoder()
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
    var isSeeking: Bool = false
    @ObservationIgnored
    var chaseTargetTime: Double? = nil
    @ObservationIgnored
    var chaseExactSeek: Bool = true
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
    var currentPath: String?
    public let historyStore: PlaybackHistoryStore
    public let playlist = PlaylistManager()
    @ObservationIgnored
    let isFeeding = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    let isMetalLayerVisibleLock = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    let isVideoDrainPaused = OSAllocatedUnfairLock(initialState: false)
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
    public var currentFramePTS: Double {
        frameQueue.getLastRenderedPTS()
    }
    /// Returns the most recently presented pixel buffer.
    /// Internal for test verification and debugging inspection.
    func getLastRenderedBuffer() -> CVPixelBuffer? {
        frameQueue.getLastRenderedBuffer()
    }
    var displayLink: CADisplayLink?
    var displayLinkTarget: DisplayLinkTarget?

    final class DisplayLinkTarget: NSObject, @unchecked Sendable {
        private weak var engine: PlayerEngine?

        init(engine: PlayerEngine) {
            self.engine = engine
            super.init()
        }

        @objc func onTick(_ link: CADisplayLink) {
            engine?.displayLinkTick()
        }
    }

    public convenience init() {
        self.init(configuration: PlayerConfiguration())
    }

    public init(configuration: PlayerConfiguration, historyStore: PlaybackHistoryStore = .shared) {
        self.configuration = configuration
        self.historyStore = historyStore
        self.renderMode = configuration.defaultRenderMode
        self.isToneMappingPermitted = configuration.enableToneMapping
        self.targetNitsScale = configuration.targetNitsScale
        self.targetNitsScaleLock.withLock { $0 = configuration.targetNitsScale }
        self.baseAdaptiveTargetNits = 203.0
        let effectiveNits = max(min(203.0 * configuration.targetNitsScale, 500.0), 80.0)
        self.metalTargetNits = effectiveNits
        self.metalSharpness = configuration.sharpness
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

        metalRenderer?.uniforms.targetNits = effectiveNits
        metalRenderer?.uniforms.outputSharpness = configuration.sharpness
        self.sampleBufferRenderer = displayLayer.sampleBufferRenderer
        // Synchronizer manages audio receiver and master clock timeline
        self.audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        displayLayer.videoGravity = .resizeAspect

        let queue = self.frameQueue
        decoder.setOutputHandler { frame in
            queue.push(frame)
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
                // Do not overwrite currentTime while a seek is in flight or chasing a target
                guard self.chaseTargetTime == nil && !self.isSeeking else { return }
                // Re-read the clock NOW: the callback's `time` argument may be stale (captured before a
                // seek settled), which would roll the UI position back to a pre-seek value.
                let seconds = CMTimeGetSeconds(self.synchronizer.currentTime())
                if !seconds.isNaN && !seconds.isInfinite && seconds >= 0 {
                    self.currentTime = seconds
                    self.onTimeUpdate?(seconds, self.duration)

                    // Update active subtitle cues
                    self.updateActiveSubtitles(at: seconds)

                    // Check if playback reached the end
                    if self.isPlaying && self.duration > 0 && seconds >= (self.duration - 0.25) {
                        self.stopPlaybackPipeline()
                        self.playbackState = .completed
                        self.saveCurrentPlaybackProgress()
                        self.handlePlaybackCompleted()
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

    func handlePlaybackCompleted() {
        if playlist.repeatMode == .one {
            AppLog.info(.engine, "Repeating current item (repeatMode: .one)")
            seek(to: 0)
            play()
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
            audioReceiver.flush()
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
