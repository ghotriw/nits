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

    private var loadingTask: Task<Void, Never>?
    private var currentInterruptContext: MediaDemuxer.InterruptContext?
    private var currentLoadID = UUID()
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
    private let activeRenderModeLock = OSAllocatedUnfairLock(initialState: RenderMode.system)
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
    public private(set) var baseAdaptiveTargetNits: Float = 203.0

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
    private let targetNitsScaleLock = OSAllocatedUnfairLock(initialState: Float(1.0))

    private struct BaseDynamicToneMapState {
        var basePeakNits: Float = 1000.0
        var baseTargetNits: Float = 203.0
        var smoothedPeakNits: Float = 1000.0
        var smoothedTargetNits: Float = 203.0
        var lastRenderModeName: String = "Metal SDR"
    }
    @ObservationIgnored
    private let dynamicToneMapLock = OSAllocatedUnfairLock(initialState: BaseDynamicToneMapState())

    private func recomputeEffectiveTargetNits() {
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
    private var activeSubtitleDocument: SubtitleDocument? = nil
    private var lastObservedLiveSubtitleVersion: Int = -1

    private func updateActiveSubtitles(at seconds: Double) {
        if let id = selectedSubtitleTrackId,
            let track = subtitleTracks.first(where: { $0.id == id }),
            !track.isExternal,
            let demuxer,
            let path = currentPath,
            MediaDemuxer.isNetworkURL(path)
        {
            // For live network streams, refresh the document only when in-band cues version changes
            let currentVersion = demuxer.liveSubtitleVersion
            if currentVersion != self.lastObservedLiveSubtitleVersion || self.activeSubtitleDocument == nil {
                self.lastObservedLiveSubtitleVersion = currentVersion
                self.activeSubtitleDocument = demuxer.getLiveSubtitleDocument()
            }
            if let doc = self.activeSubtitleDocument {
                self.currentSubtitleCues = doc.activeCues(at: seconds)
            } else {
                self.currentSubtitleCues = []
            }
            return
        }

        if let doc = self.activeSubtitleDocument {
            self.currentSubtitleCues = doc.activeCues(at: seconds)
        } else {
            self.currentSubtitleCues = []
        }
    }
    private var loadedSubtitleDocuments: [Int: SubtitleDocument] = [:]
    private var currentHeaders: [String: String] = [:]

    nonisolated private static let enqueueSampleBufferSelector = sel_registerName("enqueueSampleBuffer:")
    nonisolated private static let flushSelector = sel_registerName("flush")
    nonisolated private static let flushRemovingImageSelector = sel_registerName(
        "flushWithRemovalOfDisplayedImage:completionHandler:")

    /// Calls `flush(removingDisplayedImage: true)` via the Objective-C runtime.
    /// The display layer is deliberately NOT attached to the render synchronizer (see video_architecture.md 3.1),
    /// so the receiver-based replacement API is unavailable; this avoids the deprecation warning.
    nonisolated private static func flushRemovingDisplayedImage(_ renderer: NSObject) {
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
    nonisolated(unsafe) private let sampleBufferRenderer: AVSampleBufferVideoRenderer
    public let metalRenderer = MetalVideoRenderer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    public let audioReceiver: AVSampleBufferAudioRenderer.Receiver
    private var videoFeedingTask: Task<Void, Never>?
    private var audioFeedingTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?

    private var decoder: any VideoDecoderProtocol = VTVideoDecoder()
    private var audioDecoder: FFAudioDecoder?
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var demuxer: MediaDemuxer?
    private let feedQueue = DispatchQueue(label: "com.nativeplayer.feed", qos: .userInteractive)
    private let audioFeedQueue = DispatchQueue(label: "com.nativeplayer.audiofeed", qos: .userInteractive)
    private let seekQueue = DispatchQueue(label: "com.nativeplayer.seek", qos: .userInteractive)
    private var currentSeekId: Int = 0
    @ObservationIgnored
    private let activeSeekId = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored
    private var isSeeking: Bool = false
    @ObservationIgnored
    private var chaseTargetTime: Double? = nil
    @ObservationIgnored
    private var chaseExactSeek: Bool = true
    /// Keyframe-seek direction: forward seeks land on the next keyframe at/after the target.
    @ObservationIgnored
    private var chaseForwardSeek: Bool = false
    @ObservationIgnored
    private var resumePlaybackAfterChase: Bool = false
    @ObservationIgnored
    private var chaseSettleTask: Task<Void, Never>? = nil
    private static let relativeSeekBurstTimeout: Duration = .milliseconds(300)
    private static let relativeSeekBurstWatchdogTimeout: Duration = .seconds(3)
    private static let chaseSettleDebounceDuration: Duration = .milliseconds(300)
    /// Tracks whether a rapid relative seek burst sequence is currently active.
    @ObservationIgnored
    private var isRelativeSeekBurstActive: Bool = false
    @ObservationIgnored
    private var isRelativeSeekInFlight: Bool = false
    @ObservationIgnored
    private var relativeSeekBurstResetTask: Task<Void, Never>? = nil
    @ObservationIgnored
    private var relativeSeekSessionStartTime: Double? = nil
    private let audioRouteMonitor = AudioDeviceRouteMonitor()
    private var timeObserver: Any?
    private var lastSavedProgressSeconds: Double = 0.0
    private var configuration: PlayerConfiguration
    private var currentPath: String?
    public let historyStore: PlaybackHistoryStore
    public let playlist = PlaylistManager()
    @ObservationIgnored
    private let isFeeding = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    private let isMetalLayerVisibleLock = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    private let isVideoDrainPaused = OSAllocatedUnfairLock(initialState: false)
    public var showDebugHUD: Bool = false {
        didSet {
            if showDebugHUD {
                currentMetrics = performanceMonitor.currentMetrics
            }
        }
    }
    public var currentMetrics: PlayerPerformanceMonitor.Metrics = PlayerPerformanceMonitor.Metrics()
    public let performanceMonitor = PlayerPerformanceMonitor.shared
    private var metricsTimer: (any DispatchSourceTimer)?

    private let frameQueue = FrameQueue()
    public var currentFramePTS: Double {
        frameQueue.getLastRenderedPTS()
    }
    /// Returns the most recently presented pixel buffer.
    /// Internal for test verification and debugging inspection.
    func getLastRenderedBuffer() -> CVPixelBuffer? {
        frameQueue.getLastRenderedBuffer()
    }
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?

    private final class DisplayLinkTarget: NSObject, @unchecked Sendable {
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

    private func handlePlaybackCompleted() {
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

    private func setupAudioObservers() {
        // Monitor system-wide default audio device changes (e.g. connecting AirPods, Bluetooth, or HDMI)
        audioRouteMonitor.startMonitoring { [weak self] newUID in
            self?.handleAudioDeviceRouteChange(newUID: newUID)
        }
    }

    private func handleAudioDeviceRouteChange(newUID: String?) {
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

    private func setupMetricsMonitoring() {
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

    private func setupDisplayLink() {
        let target = DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        // If a screen is available on initialization, attach CADisplayLink to NSScreen.main
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            self.displayLink = link
        }
    }

    /// Attaches the engine's CADisplayLink to the video rendering host view.
    /// This ensures accurate VBLANK sync across ProMotion (120Hz) displays and seamless multi-monitor transitions.
    public func attachDisplayLink(to view: NSView) {
        displayLink?.invalidate()
        let target = displayLinkTarget ?? DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        let link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = !isPlaying
        self.displayLink = link
    }

    private func updateEffectiveRenderMode() {
        let newMode: RenderMode
        switch renderMode {
        case .auto:
            // Metal tone mapping is ONLY needed when video content is HDR and display is SDR
            if isHDRContent && !isHDRDisplay && isToneMappingPermitted {
                newMode = .metalToneMap
            } else {
                newMode = .system
            }
        case .system:
            newMode = .system
        case .metalToneMap:
            newMode = isToneMappingPermitted ? .metalToneMap : .system
        }
        let previousMode = activeRenderModeLock.withLock { mode -> RenderMode in
            let prev = mode
            mode = newMode
            return prev
        }

        guard previousMode != newMode else { return }

        if newMode == .system {
            isMetalLayerVisible = false
            performanceMonitor.updateToneMapParams(
                PlayerPerformanceMonitor.ToneMapParams(mode: .appleXDR)
            )
            if !isPlaying {
                renderCurrentFrame()
            }
        } else {
            let baseMode: PlayerPerformanceMonitor.ToneMapEngineMode = dynamicToneMapLock.withLock { state in
                if state.lastRenderModeName.contains("DoVi L2") {
                    return .doviL2Trim
                } else if state.lastRenderModeName.contains("DoVi L1") {
                    return .doviL1Auto
                } else if state.basePeakNits > 105.0 {
                    return .bt2390
                } else {
                    return .directSDR
                }
            }
            let (peak, target) = dynamicToneMapLock.withLock { ($0.basePeakNits, $0.baseTargetNits) }
            performanceMonitor.updateToneMapParams(
                PlayerPerformanceMonitor.ToneMapParams(mode: baseMode, peakNits: peak, targetNits: target)
            )
            if !isPlaying {
                renderCurrentFrame()
                isMetalLayerVisible = true
            }
        }

        if showDebugHUD {
            currentMetrics = performanceMonitor.currentMetrics
        }
    }

    nonisolated private func presentToDisplayLayer(pixelBuffer: CVPixelBuffer) {
        var formatDescription: CMVideoFormatDescription?
        let err = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard err == noErr, let formatDesc = formatDescription else { return }

        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: [timing],
            sampleBufferOut: &sampleBuffer
        )
        guard let sample = sampleBuffer else { return }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary],
            let dic = attachmentsArray.first
        {
            dic[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        _ = sampleBufferRenderer.perform(Self.enqueueSampleBufferSelector, with: sample)
    }

    nonisolated private func displayLinkTick() {
        let currentSyncTime = synchronizer.currentTime()
        guard currentSyncTime.isValid else { return }

        let start = CACurrentMediaTime()
        if let popped = frameQueue.popFrame(forSyncTime: currentSyncTime) {
            let durationMs = (CACurrentMediaTime() - start) * 1000.0
            let qCount = frameQueue.count
            let isPaused = isVideoDrainPaused.withLock { $0 }
            let driftMs = popped.pts.isValid ? (popped.pts.seconds - currentSyncTime.seconds) * 1000.0 : 0.0
            let dropped = frameQueue.droppedFramesCount

            let mode = activeRenderMode
            if mode == .metalToneMap {
                struct ResolvedToneMapParams {
                    let hasDoViL2Trim: UInt32
                    let slope: Float
                    let offset: Float
                    let power: Float
                    let saturation: Float
                    let peakNits: Float
                    let targetNits: Float
                    let modeName: String
                }

                let resolved = dynamicToneMapLock.withLock { state -> ResolvedToneMapParams in
                    let scale = self.targetNitsScaleLock.withLock { $0 }
                    let effectiveBaseTarget = max(min(state.baseTargetNits * scale, 500.0), 80.0)

                    if let dovi = popped.doviMetadata {
                        let isSceneRefresh = dovi.sceneRefresh
                        let alpha: Float = isSceneRefresh ? 1.0 : 0.15

                        if let trim = dovi.sdrTrim {
                            state.lastRenderModeName = "Metal SDR (DoVi L2 Trim)"
                            return ResolvedToneMapParams(
                                hasDoViL2Trim: 1,
                                slope: trim.slope,
                                offset: trim.offset,
                                power: trim.power,
                                saturation: trim.saturationGain,
                                peakNits: state.basePeakNits,
                                targetNits: effectiveBaseTarget,
                                modeName: state.lastRenderModeName
                            )
                        } else if let l1 = dovi.l1 {
                            let dynamicPeak = l1.maxNits > 0 ? l1.maxNits : state.basePeakNits
                            let rawTarget = Self.computeAdaptiveTargetNits(
                                baseTargetNits: 203.0,
                                maxPeakNits: dynamicPeak,
                                maxFallNits: l1.avgNits
                            )
                            let scaledTarget = max(min(rawTarget * scale, 500.0), 80.0)

                            state.smoothedPeakNits = (alpha * dynamicPeak) + ((1.0 - alpha) * state.smoothedPeakNits)
                            state.smoothedTargetNits =
                                (alpha * scaledTarget) + ((1.0 - alpha) * state.smoothedTargetNits)
                            state.lastRenderModeName = "Metal SDR (DoVi L1)"

                            return ResolvedToneMapParams(
                                hasDoViL2Trim: 0,
                                slope: 1.0,
                                offset: 0.0,
                                power: 1.0,
                                saturation: 0.0,
                                peakNits: state.smoothedPeakNits,
                                targetNits: state.smoothedTargetNits,
                                modeName: state.lastRenderModeName
                            )
                        } else {
                            state.lastRenderModeName = "Metal SDR"
                            return ResolvedToneMapParams(
                                hasDoViL2Trim: 0,
                                slope: 1.0,
                                offset: 0.0,
                                power: 1.0,
                                saturation: 0.0,
                                peakNits: state.basePeakNits,
                                targetNits: effectiveBaseTarget,
                                modeName: state.lastRenderModeName
                            )
                        }
                    } else {
                        // Frame without RPU metadata: cleanly revert to container static base values
                        return ResolvedToneMapParams(
                            hasDoViL2Trim: 0,
                            slope: 1.0,
                            offset: 0.0,
                            power: 1.0,
                            saturation: 0.0,
                            peakNits: state.basePeakNits,
                            targetNits: effectiveBaseTarget,
                            modeName: state.lastRenderModeName
                        )
                    }
                }

                metalRenderer?.updateUniforms { uniforms in
                    uniforms.hasDoViL2Trim = resolved.hasDoViL2Trim
                    if resolved.hasDoViL2Trim == 1 {
                        uniforms.doViTrimSlope = resolved.slope
                        uniforms.doViTrimOffset = resolved.offset
                        uniforms.doViTrimPower = resolved.power
                        uniforms.doViTrimSaturation = resolved.saturation
                    }
                    uniforms.sourcePeakNits = resolved.peakNits
                    uniforms.targetNits = resolved.targetNits
                }
                let currentModeName = resolved.modeName
                let toneMode: PlayerPerformanceMonitor.ToneMapEngineMode
                if resolved.hasDoViL2Trim == 1 {
                    toneMode = .doviL2Trim
                } else if currentModeName.contains("DoVi L1") {
                    toneMode = .doviL1Auto
                } else if resolved.peakNits > 105.0 {
                    toneMode = .bt2390
                } else {
                    toneMode = .directSDR
                }

                performanceMonitor.updateToneMapParams(
                    PlayerPerformanceMonitor.ToneMapParams(
                        mode: toneMode,
                        slope: resolved.slope,
                        offset: resolved.offset,
                        power: resolved.power,
                        saturation: resolved.saturation,
                        peakNits: resolved.peakNits,
                        targetNits: resolved.targetNits
                    )
                )

                metalRenderer?.render(pixelBuffer: popped.pixelBuffer)
                performanceMonitor.recordRenderedFrame(
                    durationMs: durationMs,
                    queueCount: qCount,
                    renderModeName: currentModeName,
                    isDrainPaused: isPaused,
                    avSyncDriftMs: driftMs,
                    droppedFrames: dropped
                )

                if !isMetalLayerVisibleLock.withLock({ $0 }) {
                    isMetalLayerVisibleLock.withLock { $0 = true }
                    DispatchQueue.main.async { [weak self] in
                        self?.isMetalLayerVisible = true
                    }
                }
            } else {
                presentToDisplayLayer(pixelBuffer: popped.pixelBuffer)
                performanceMonitor.updateToneMapParams(
                    PlayerPerformanceMonitor.ToneMapParams(mode: .appleXDR)
                )
                performanceMonitor.recordRenderedFrame(
                    durationMs: durationMs,
                    queueCount: qCount,
                    renderModeName: "Apple HDR (AVSBDL)",
                    isDrainPaused: isPaused,
                    avSyncDriftMs: driftMs,
                    droppedFrames: dropped
                )

                if isMetalLayerVisibleLock.withLock({ $0 }) {
                    isMetalLayerVisibleLock.withLock { $0 = false }
                    DispatchQueue.main.async { [weak self] in
                        self?.isMetalLayerVisible = false
                    }
                }
            }
        }

        // Backpressure check: if feeding was paused due to full frame buffer, resume when queue drops to <= 25 frames
        if frameQueue.count <= 25 && isVideoDrainPaused.withLock({ $0 }) {
            checkBackpressureAndResumeIfNeeded()
        }
    }

    public func renderCurrentFrame() {
        renderCurrentFrame(at: nil)
    }

    public func renderCurrentFrame(at explicitTime: CMTime?) {
        let currentSyncTime = explicitTime ?? synchronizer.currentTime()
        let buffer: CVPixelBuffer?
        if currentSyncTime.isValid, let b = frameQueue.getLatestFrame(forSyncTime: currentSyncTime) {
            buffer = b
        } else {
            buffer = frameQueue.getLastRenderedBuffer()
        }

        guard let buffer else { return }
        if activeRenderMode == .metalToneMap {
            metalRenderer?.render(pixelBuffer: buffer)
        } else {
            presentToDisplayLayer(pixelBuffer: buffer)
        }
    }

    /// Directly renders a decoded pixel buffer onto the active video canvas and updates last rendered state.
    public func renderDirect(pixelBuffer: CVPixelBuffer, pts: Double) {
        frameQueue.setLastRendered(buffer: pixelBuffer, pts: pts)
        if activeRenderMode == .metalToneMap {
            metalRenderer?.render(pixelBuffer: pixelBuffer)
        } else {
            presentToDisplayLayer(pixelBuffer: pixelBuffer)
        }
    }

    /// Completely flushes and clears the video display layer and Metal canvas, removing any lingering video frame.
    public func clearVideoSurface() {
        frameQueue.clear(resetDroppedFrames: true)
        Self.flushRemovingDisplayedImage(sampleBufferRenderer)
        metalRenderer?.clear()
    }

    /// Resolves the user-facing media title from a file/stream path, falling back to
    /// URL host or file name if no explicit title is provided.
    nonisolated public static func resolveTitle(from path: String, explicitTitle: String? = nil) -> String {
        if let explicitTitle, !explicitTitle.isEmpty {
            return explicitTitle
        }
        if MediaDemuxer.isNetworkURL(path), let url = URL(string: path) {
            let last = url.lastPathComponent
            if last.isEmpty || last == "/" {
                return url.host ?? path
            }
            return last
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    public func load(path: String) {
        load(path: path, title: nil, headers: [:], startTime: nil)
    }

    public func load(path: String, title: String?) {
        load(path: path, title: title, headers: [:], startTime: nil)
    }

    public func load(path: String, headers: [String: String]) {
        load(path: path, title: nil, headers: headers, startTime: nil)
    }

    public func load(path: String, headers: [String: String], startTime: Double?) {
        load(path: path, title: nil, headers: headers, startTime: startTime)
    }

    public func load(
        path: String,
        title: String? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil
    ) {
        load(
            path: path,
            title: title,
            artworkData: nil,
            artworkURL: nil,
            headers: headers,
            startTime: startTime
        )
    }

    public func load(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String] = [:],
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil
    ) {
        // If the path represents a playlist file (.m3u, .m3u8, .pls, .xspf, .cue), parse and load it into the playlist
        let isNetwork = MediaDemuxer.isNetworkURL(path)
        let isRemoteOrMounted = MediaDemuxer.isRemoteOrMountedVolume(path)
        if PlaylistParser.isPlaylistFile(path: path),
            let playlistURL = isNetwork ? URL(string: path) : URL(fileURLWithPath: path)
        {
            // Parse playlist asynchronously without blocking the MainActor
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let parsedItems = await PlaylistParser.parseAsync(url: playlistURL)
                if !parsedItems.isEmpty {
                    AppLog.info(
                        .playlist,
                        "Opening playlist '\(playlistURL.lastPathComponent)' with \(parsedItems.count) track(s)"
                    )
                    self.playlist.clear()
                    self.playlist.append(items: parsedItems)
                    if let firstItem = self.playlist.currentItem {
                        self.load(item: firstItem)
                    }
                } else if isNetwork {
                    // Fallback to loading via demuxer as HLS/stream if parsing yielded no separate items
                    await self.loadAsync(
                        path: path,
                        title: title,
                        artworkData: artworkData,
                        artworkURL: artworkURL,
                        headers: headers,
                        startTime: startTime,
                        audioTrack: audioTrack,
                        subtitleTrack: subtitleTrack
                    )
                }
            }
            return
        }

        // Save playback progress of previously active media before loading new track
        saveCurrentPlaybackProgress()

        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: title)
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        if isRemoteOrMounted {
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                await self?.loadAsync(
                    path: path,
                    title: title,
                    artworkData: artworkData,
                    artworkURL: artworkURL,
                    headers: headers,
                    startTime: startTime,
                    audioTrack: audioTrack,
                    subtitleTrack: subtitleTrack
                )
            }
        } else {
            loadSync(
                path: path,
                title: title,
                artworkData: artworkData,
                artworkURL: artworkURL,
                headers: headers,
                startTime: startTime,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack
            )
        }
    }

    /// Loads and begins playback of a playlist item.
    public func load(item: PlaylistItem) {
        let pathString = item.url.isFileURL ? item.url.standardizedFileURL.path : item.url.absoluteString
        self.load(
            path: pathString,
            title: item.title,
            artworkData: nil,
            artworkURL: nil,
            headers: item.customHeaders,
            startTime: item.startTime,
            audioTrack: nil,
            subtitleTrack: nil
        )
    }

    /// Advances to and loads the next item in the playlist.
    public func playNext() {
        if let item = playlist.playNext(isUserAction: true) {
            load(item: item)
        }
    }

    /// Returns to previous playlist item or restarts current track if played past 3 seconds.
    public func playPrevious() {
        let (item, shouldRestart) = playlist.playPrevious(
            restartThresholdSeconds: 3.0,
            currentPlaybackTime: currentTime
        )
        if shouldRestart {
            seek(to: 0)
            play()
        } else if let item {
            load(item: item)
        }
    }

    /// Selects and plays a specific item from the playlist by UUID.
    public func playPlaylistItem(id: UUID) {
        // If clicking on the currently active item, just ensure it plays without restarting
        if let currentItem = playlist.currentItem, currentItem.id == id, isLoaded {
            if !isPlaying {
                play()
            }
            return
        }

        if let item = playlist.selectItem(id: id) {
            load(item: item)
        }
    }

    /// Removes an item from the playlist. If the removed item was currently playing,
    /// stops playback or advances to the next remaining item.
    public func removePlaylistItem(id: UUID) {
        let isRemovingCurrent = (playlist.currentItem?.id == id)
        playlist.remove(id: id)

        if isRemovingCurrent {
            if let nextItem = playlist.currentItem {
                load(item: nextItem)
            } else {
                stop()
            }
        }
    }

    public func loadAsync(path: String) async {
        await loadAsync(path: path, title: nil, headers: [:], startTime: nil)
    }

    public func loadAsync(path: String, title: String?) async {
        await loadAsync(path: path, title: title, headers: [:], startTime: nil)
    }

    public func loadAsync(path: String, headers: [String: String]) async {
        await loadAsync(path: path, title: nil, headers: headers, startTime: nil)
    }

    public func loadAsync(
        path: String,
        title: String? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil
    ) async {
        await loadAsync(
            path: path,
            title: title,
            artworkData: nil,
            artworkURL: nil,
            headers: headers,
            startTime: startTime
        )
    }

    public func loadAsync(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String] = [:],
        startTime: Double? = nil,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil
    ) async {
        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: title)
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        AppLog.info(
            .engine,
            "Loading async: \(path) title: \(self.mediaTitle) with headers count: \(headers.count) startTime: \(String(describing: startTime))"
        )

        // Save progress for previously active media if present
        saveCurrentPlaybackProgress()

        // Reset playback tracking state so stale values from previous media do not leak
        self.currentPath = nil
        self.currentTime = 0
        self.duration = 0
        self.isLoaded = false
        self.isLoading = true

        let seekId = currentSeekId + 1
        currentSeekId = seekId
        activeSeekId.withLock { $0 = seekId }
        isSeeking = false
        chaseTargetTime = nil
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        resumePlaybackAfterChase = false

        // Generate a new load ID and cancel any in-flight requests immediately
        let loadID = UUID()
        self.currentLoadID = loadID

        currentInterruptContext?.cancel()
        demuxer?.cancel()
        demuxer = nil

        let interruptContext = MediaDemuxer.InterruptContext()
        self.currentInterruptContext = interruptContext

        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        clearVideoSurface()
        displayLink?.isPaused = true
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        isPlaying = false
        loadError = nil
        hasVideo = false
        playbackState = .loading

        let task = Task.detached(priority: .userInitiated) { () -> MediaDemuxer? in
            guard !Task.isCancelled, !interruptContext.isCancelled else { return nil }
            return MediaDemuxer(url: path, headers: headers, interruptContext: interruptContext)
        }

        let newDemuxer = await task.value

        // Prevent race condition: if another load started or task was cancelled, discard result
        if self.currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled {
            AppLog.warning(.engine, "Loading was superseded or cancelled for: \(path)")
            if self.currentLoadID == loadID {
                self.isLoading = false
                self.playbackState = .idle
            }
            return
        }

        guard let demuxer = newDemuxer else {
            AppLog.error(.engine, "Failed to open file or network stream: \(path)")
            self.isLoading = false
            let err = "Failed to open stream or media file."
            self.loadError = err
            self.playbackState = .failed(err)
            return
        }

        applyLoadedDemuxer(
            demuxer, path: path, headers: headers, requestedStartTime: startTime,
            requestedAudioTrack: audioTrack, requestedSubtitleTrack: subtitleTrack)
    }

    private func loadSync(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String],
        startTime: Double?,
        audioTrack: String?,
        subtitleTrack: String?
    ) {
        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: title)
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        AppLog.info(
            .engine,
            "Loading sync: \(path) title: \(self.mediaTitle) startTime: \(String(describing: startTime))"
        )

        // Save progress for previously active media if present
        saveCurrentPlaybackProgress()

        // Reset playback tracking state so stale values from previous media do not leak
        self.currentPath = nil
        self.currentTime = 0
        self.duration = 0
        self.isLoaded = false
        self.isLoading = true

        let seekId = currentSeekId + 1
        currentSeekId = seekId
        activeSeekId.withLock { $0 = seekId }
        isSeeking = false
        chaseTargetTime = nil
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        resumePlaybackAfterChase = false

        let loadID = UUID()
        self.currentLoadID = loadID

        loadingTask?.cancel()
        loadingTask = nil
        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        demuxer?.cancel()
        demuxer = nil

        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        clearVideoSurface()
        displayLink?.isPaused = true
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        isPlaying = false
        loadError = nil
        hasVideo = false
        playbackState = .loading

        guard let demuxer = MediaDemuxer(url: path, headers: headers) else {
            AppLog.error(.engine, "Failed to open file: \(path)")
            let err = "Failed to open media file."
            self.loadError = err
            self.isLoading = false
            self.playbackState = .failed(err)
            return
        }

        applyLoadedDemuxer(
            demuxer, path: path, headers: headers, requestedStartTime: startTime,
            requestedAudioTrack: audioTrack, requestedSubtitleTrack: subtitleTrack)
    }

    public func stop() {
        resetRelativeSeekBurst()
        let seekId = currentSeekId + 1
        currentSeekId = seekId
        activeSeekId.withLock { $0 = seekId }
        isSeeking = false
        chaseTargetTime = nil
        resumePlaybackAfterChase = false
        saveCurrentPlaybackProgress()
        loadingTask?.cancel()
        loadingTask = nil
        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        demuxer?.cancel()
        demuxer = nil
        stopPlaybackPipeline()
        clearVideoSurface()
        hasVideo = false
        videoWidth = 0
        videoHeight = 0
        videoCodecName = ""
        videoBitDepth = 8
        videoColorPrimaries = ""
        videoTransferFunction = ""
        videoDolbyVisionProfile = nil
        videoSourcePeakNits = 0
        currentMetrics = PlayerPerformanceMonitor.Metrics()
        dynamicToneMapLock.withLock {
            $0.basePeakNits = 1000.0
            $0.baseTargetNits = 203.0
            $0.smoothedPeakNits = 1000.0
            $0.smoothedTargetNits = 203.0
            $0.lastRenderModeName = "Metal SDR"
        }
        performanceMonitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(mode: .none, peakNits: 0, targetNits: 203)
        )
        mediaTitle = ""
        artworkData = nil
        artworkURL = nil
        isLoaded = false
        currentPath = nil
        currentTime = 0
        duration = 0
        playbackState = .idle
    }

    public func saveCurrentPlaybackProgress() {
        guard isLoaded, !isLoading, let path = currentPath, duration > 0 else { return }
        let progressTime = chaseTargetTime ?? currentTime
        AppLog.debug(.engine, "Saving playback progress for '\(path)' at \(progressTime)s / \(duration)s")
        if progressTime > 0 {
            historyStore.savePosition(
                for: path,
                position: progressTime,
                duration: duration,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio,
                audioTrackId: hasAudioTrackSelection ? selectedAudioTrackId : nil,
                subtitleTrackId: subtitleTrackIdForHistory
            )
        } else {
            historyStore.saveTrackSelection(
                for: path,
                duration: duration,
                audioTrackId: hasAudioTrackSelection ? selectedAudioTrackId : nil,
                subtitleTrackId: subtitleTrackIdForHistory
            )
        }
    }

    public enum SubtitleSelectionPreference: Equatable, Sendable {
        case disable
        case select(trackId: Int)
    }

    /// Subtitle selection to persist: `subtitlesOff` when disabled, `nil` for external files (not restorable).
    private var subtitleTrackIdForHistory: Int? {
        guard let id = selectedSubtitleTrackId else { return PlaybackRecord.subtitlesOff }
        if let track = subtitleTracks.first(where: { $0.id == id }), !track.isExternal {
            return id
        }
        return nil
    }

    private var hasAudioTrackSelection: Bool { selectedAudioTrackId >= 0 }

    /// Extracts an explicit stream index from strings formatted as `stream:N` or `s:N`.
    private nonisolated static func parseStreamIndex(from key: String) -> Int? {
        if key.hasPrefix("stream:") {
            return Int(key.dropFirst("stream:".count))
        } else if key.hasPrefix("s:") {
            return Int(key.dropFirst("s:".count))
        }
        return nil
    }

    /// Resolves an audio track spec to a track id.
    ///
    /// Resolution order:
    /// 1. Explicit container stream index via `stream:N` or `s:N` prefix (e.g. `stream:3`).
    /// 2. Direct numeric value interpreted first as internal `track.id` (`0, 1, 2...`).
    /// 3. Direct numeric value fallback to `streamIndex` if no matching `track.id` exists.
    /// 4. Language code match (`matchesLanguage`, e.g. `eng`, `jpn`).
    /// 5. Title fragment match (`matchesTitle`, e.g. `Commentary`).
    public nonisolated static func resolveAudioTrackId(_ spec: String, in tracks: [MediaDemuxer.AudioTrack]) -> Int? {
        let key = spec.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        // Explicit "stream:N" or "s:N" prefix (matching container stream index, e.g. from host app / FFmpeg)
        if let streamIdx = parseStreamIndex(from: key),
            let match = tracks.first(where: { $0.streamIndex == streamIdx })
        {
            return match.id
        }

        // Direct numeric match: prioritize track.id (0, 1, 2...), then fallback to container streamIndex
        if let id = Int(key) {
            if let byId = tracks.first(where: { $0.id == id }) { return byId.id }
            if let byStream = tracks.first(where: { $0.streamIndex == id }) { return byStream.id }
        }

        if let byLang = tracks.first(where: { matchesLanguage($0.language, key) }) {
            return byLang.id
        }
        return tracks.first(where: { matchesTitle($0.title, key) })?.id
    }

    /// Resolves a subtitle spec to a selection preference. Returns nil if unresolved.
    ///
    /// Resolution order:
    /// 1. Sentinel disable keywords (`off`, `none`, `no`, `disabled`).
    /// 2. Explicit container stream index via `stream:N` or `s:N` prefix (e.g. `stream:5`).
    /// 3. Direct numeric value interpreted first as internal `track.id`.
    /// 4. Direct numeric value fallback to `streamIndex` if no matching `track.id` exists.
    /// 5. Language code match (`matchesLanguage`, e.g. `rus`).
    /// 6. Title fragment match (`matchesTitle`, e.g. `SDH`).
    public nonisolated static func resolveSubtitleSelection(_ spec: String, in tracks: [SubtitleTrack])
        -> SubtitleSelectionPreference?
    {
        let key = spec.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if ["off", "none", "no", "disabled"].contains(key) { return .disable }

        // Explicit "stream:N" or "s:N" prefix (matching container stream index, e.g. from host app / FFmpeg)
        if let streamIdx = parseStreamIndex(from: key),
            let match = tracks.first(where: { $0.streamIndex == streamIdx })
        {
            return .select(trackId: match.id)
        }

        // Direct numeric match: prioritize track.id, then fallback to container streamIndex
        if let id = Int(key) {
            if let byId = tracks.first(where: { $0.id == id }) { return .select(trackId: byId.id) }
            if let byStream = tracks.first(where: { $0.streamIndex == id }) { return .select(trackId: byStream.id) }
        }

        if let byLang = tracks.first(where: { matchesLanguage($0.language, key) }) {
            return .select(trackId: byLang.id)
        }
        if let byTitle = tracks.first(where: { matchesTitle($0.title, key) }) {
            return .select(trackId: byTitle.id)
        }
        return nil
    }

    private nonisolated static func matchesLanguage(_ language: String, _ key: String) -> Bool {
        let lang = language.lowercased().trimmingCharacters(in: .whitespaces)
        return !lang.isEmpty && lang != "und" && (lang == key || lang.hasPrefix(key + "-") || key.hasPrefix(lang + "-"))
    }

    private nonisolated static func matchesTitle(_ title: String, _ key: String) -> Bool {
        let lowerTitle = title.lowercased()
        // If key is very short (1 or 2 characters), require exact word match or exact title match
        if key.count < 3 {
            let words = lowerTitle.components(separatedBy: CharacterSet.alphanumerics.inverted)
            return words.contains(key)
        }
        return lowerTitle.contains(key)
    }

    /// Computes the optimal target reference white (nits) for ITU-R BT.2390 tone mapping
    /// on standard SDR displays, adapting to content peak and frame-average luminance.
    public nonisolated static func computeAdaptiveTargetNits(
        baseTargetNits: Float = 203.0,
        maxPeakNits: Float,
        maxFallNits: Float = 0.0
    ) -> Float {
        // If content is high-peak mastering (>= 950 nits) and not extremely dark, keep ITU reference (203.0)
        if maxPeakNits >= 950.0 && (maxFallNits == 0 || maxFallNits >= 120.0) {
            return baseTargetNits
        }

        // Scale reference white down smoothly for lower-peak mastering (300...1000 -> 100...baseTargetNits)
        var target = 100.0 + (baseTargetNits - 100.0) * max(min((maxPeakNits - 300.0) / 700.0, 1.0), 0.0)

        // If the scene average (MaxFALL) is known and low (< 100 nits, e.g. low-key dark drama),
        // adjust the target white to prevent crushing midtones and shadows
        if maxFallNits > 0 && maxFallNits < 100.0 {
            let fallFactor = max(maxFallNits / 100.0, 0.7)
            target = min(target, 100.0 + (target - 100.0) * fallFactor)
        }

        return max(min(target, baseTargetNits), 100.0)
    }

    private func applyLoadedDemuxer(
        _ demuxer: MediaDemuxer, path: String, headers: [String: String], requestedStartTime: Double?,
        requestedAudioTrack: String?, requestedSubtitleTrack: String?
    ) {
        resetRelativeSeekBurst()
        self.demuxer = demuxer
        self.currentPath = path
        self.currentHeaders = headers
        self.hasVideo = demuxer.hasVideo
        self.duration = demuxer.durationSeconds
        self.videoWidth = demuxer.width
        self.videoHeight = demuxer.height
        self.isHDRContent = demuxer.isHDR
        if self.mediaTitle.isEmpty {
            self.mediaTitle = Self.resolveTitle(from: path)
        }

        // Synchronize playlist with current media
        let isNetwork = MediaDemuxer.isNetworkURL(path)
        let mediaURL = isNetwork ? URL(string: path) : URL(fileURLWithPath: path)
        if let mediaURL {
            let matchesCurrent: Bool = {
                guard let currentURL = playlist.currentItem?.url else { return false }
                if currentURL.isFileURL && mediaURL.isFileURL {
                    return currentURL.standardizedFileURL.path == mediaURL.standardizedFileURL.path
                }
                return currentURL.absoluteString == mediaURL.absoluteString
            }()

            if !matchesCurrent {
                playlist.setInitialMedia(
                    url: mediaURL,
                    title: self.mediaTitle,
                    autoLoadFolder: configuration.autoLoadFolderMedia
                )
            }
            playlist.updateCurrentItemDuration(demuxer.durationSeconds)
        }
        // Fall back to embedded container artwork if no explicit artwork data was provided
        if self.artworkData == nil, let embedded = demuxer.embeddedArtworkData {
            self.artworkData = embedded
        }
        // Track selection priority chain (per kind):
        // 1. Explicit request (CLI, host app, deep link)
        // 2. PlaybackHistoryStore saved selection (if resume is enabled)
        // 3. Demuxer default
        let savedTracks =
            configuration.resumePlayback
            ? historyStore.savedTrackSelection(for: path)
            : nil

        if let spec = requestedAudioTrack,
            let id = Self.resolveAudioTrackId(spec, in: demuxer.audioTracks)
        {
            demuxer.selectAudioTrack(trackId: id)
            AppLog.info(.audio, "Using explicit audio track: \(id)")
        } else if let saved = savedTracks?.audioTrackId,
            demuxer.audioTracks.contains(where: { $0.id == saved })
        {
            demuxer.selectAudioTrack(trackId: saved)
            AppLog.info(.audio, "Restored audio track from saved history: \(saved)")
        }

        self.audioTracks = demuxer.audioTracks
        self.selectedAudioTrackId = demuxer.selectedAudioTrackIndex
        self.subtitleTracks = demuxer.subtitleTracks
        self.selectedSubtitleTrackId = nil
        self.activeSubtitleDocument = nil
        self.currentSubtitleCues.removeAll()
        self.loadedSubtitleDocuments.removeAll()
        self.lastObservedLiveSubtitleVersion = -1
        self.loadError = nil

        if let spec = requestedSubtitleTrack,
            let preference = Self.resolveSubtitleSelection(spec, in: demuxer.subtitleTracks)
        {
            switch preference {
            case .disable:
                selectSubtitleTrack(id: nil, persistHistory: false)
                AppLog.info(.subtitles, "Explicit subtitle selection: disabled")
            case .select(let trackId):
                selectSubtitleTrack(id: trackId, persistHistory: false)
                AppLog.info(.subtitles, "Using explicit subtitle track: \(trackId)")
            }
        } else if let saved = savedTracks?.subtitleTrackId {
            if saved == PlaybackRecord.subtitlesOff {
                selectSubtitleTrack(id: nil, persistHistory: false)
            } else if demuxer.subtitleTracks.contains(where: { $0.id == saved }) {
                selectSubtitleTrack(id: saved, persistHistory: false)
                AppLog.info(.subtitles, "Restored subtitle track from saved history: \(saved)")
            }
        }

        if demuxer.hasVideo {
            let baseAdaptive = Self.computeAdaptiveTargetNits(
                baseTargetNits: 203.0,
                maxPeakNits: demuxer.maxPeakNits,
                maxFallNits: demuxer.maxFallNits
            )
            self.baseAdaptiveTargetNits = baseAdaptive
            let effectiveTargetNits = max(min(baseAdaptive * self.targetNitsScale, 500.0), 80.0)
            self.metalTargetNits = effectiveTargetNits
            let autoShadowLift: Float =
                (demuxer.maxFallNits > 0 && demuxer.maxFallNits < 80.0 && self.metalShadowLift == 0.0) ? 0.008 : 0.0

            self.dynamicToneMapLock.withLock {
                $0.basePeakNits = demuxer.maxPeakNits
                $0.baseTargetNits = baseAdaptive
                $0.smoothedPeakNits = demuxer.maxPeakNits
                $0.smoothedTargetNits = effectiveTargetNits
                $0.lastRenderModeName = "Metal SDR"
            }

            self.metalRenderer?.updateUniforms { uniforms in
                uniforms.sourcePeakNits = demuxer.maxPeakNits
                uniforms.targetNits = effectiveTargetNits
                if autoShadowLift > 0.0 {
                    uniforms.outputShadowLift = autoShadowLift
                }
                if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                    uniforms.colorPrimaries = 1
                } else if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                    || demuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
                {
                    uniforms.colorPrimaries = 2
                } else {
                    uniforms.colorPrimaries = 0  // BT.2020
                }

                if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                    || demuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
                {
                    uniforms.transferFunction = 2  // SDR
                } else if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG {
                    uniforms.transferFunction = 1  // HLG
                } else {
                    uniforms.transferFunction = 0  // PQ
                }

                uniforms.bitDepth = UInt32(demuxer.bitDepth)
                uniforms.isFullRange = demuxer.isFullRange ? 1 : 0
                if demuxer.isDolbyVisionProfile5 {
                    uniforms.colorSpaceMode = 2  // Dolby Vision IPT / ICtCp
                } else if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                    uniforms.colorSpaceMode = 1  // BT.709
                } else {
                    uniforms.colorSpaceMode = 0  // Standard BT.2020 YCbCr
                }
            }

            // Update telemetry metadata
            let primariesStr: String = {
                if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 { return "BT.709" }
                if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                    || demuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
                {
                    return "DCI-P3"
                }
                return "BT.2020"
            }()
            let transferStr: String = {
                if demuxer.isDolbyVisionProfile5 { return "Dolby Vision (Profile 5 ICtCp)" }
                if let dvStr = demuxer.dolbyVisionProfileString {
                    return "Dolby Vision (Profile \(dvStr))"
                }
                if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                    || demuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
                {
                    return "BT.709 / SDR"
                }
                if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG { return "HLG" }
                return "PQ (ST 2084)"
            }()

            let dvProfileStr: String? = {
                if demuxer.isDolbyVisionProfile5 { return "Profile 5 (ICtCp)" }
                if let dvStr = demuxer.dolbyVisionProfileString {
                    if demuxer.dolbyVisionProfile == 8 {
                        if demuxer.dolbyVisionCompatibilityId == 1 { return "Profile 8.1 (HDR10 Base)" }
                        if demuxer.dolbyVisionCompatibilityId == 4 { return "Profile 8.4 (HLG Base)" }
                    }
                    return "Profile \(dvStr)"
                }
                return nil
            }()

            let codecDisplay: String =
                switch demuxer.codec {
                case .hevc: "HEVC"
                case .h264: "H.264"
                case .av1: "AV1"
                case .unknown: "Unknown"
                }
            self.videoCodecName = codecDisplay
            self.videoBitDepth = demuxer.bitDepth
            self.videoColorPrimaries = primariesStr
            self.videoTransferFunction = transferStr
            self.videoDolbyVisionProfile = dvProfileStr
            self.videoSourcePeakNits = demuxer.maxPeakNits

            self.performanceMonitor.updateStreamMetadata(
                resolution: "\(demuxer.width)x\(demuxer.height)",
                codecName: codecDisplay,
                bitDepth: demuxer.bitDepth,
                colorPrimaries: primariesStr,
                transferFunction: transferStr,
                sourcePeakNits: demuxer.maxPeakNits,
                targetNits: effectiveTargetNits,
                dolbyVisionProfile: dvProfileStr
            )

            let initialToneMode: PlayerPerformanceMonitor.ToneMapEngineMode
            if self.activeRenderMode == .system {
                initialToneMode = .appleXDR
            } else if demuxer.isDolbyVisionProfile5 || demuxer.dolbyVisionProfile != nil {
                initialToneMode = .doviL2Trim
            } else if demuxer.isHDR {
                initialToneMode = .bt2390
            } else {
                initialToneMode = .directSDR
            }
            self.performanceMonitor.updateToneMapParams(
                PlayerPerformanceMonitor.ToneMapParams(
                    mode: initialToneMode,
                    peakNits: demuxer.maxPeakNits,
                    targetNits: effectiveTargetNits
                )
            )
            self.currentMetrics = self.performanceMonitor.currentMetrics
        }

        AppLog.info(
            .engine,
            "Loaded successfully. Duration: \(self.duration)s, peakNits: \(demuxer.maxPeakNits), formatDesc: \(String(describing: demuxer.formatDescription))"
        )

        // Initialize video decoder if video stream is present
        if demuxer.hasVideo {
            guard let videoDecoder = VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer) else {
                let err = "Failed to initialize video decoder for \(demuxer.codec)."
                AppLog.error(.engine, err)
                self.loadError = err
                self.isLoading = false
                self.playbackState = .failed(err)
                return
            }
            self.decoder = videoDecoder
            let queue = self.frameQueue
            self.decoder.setOutputHandler { frame in
                queue.push(frame)
            }
        }

        // Initialize audio decoder if audio stream is present
        if demuxer.hasAudio, let audioParams = demuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: audioParams, timebase: demuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            AppLog.info(
                .audio,
                "Audio decoder initialized: \(String(describing: self.audioDecoder != nil)), channels: \(demuxer.audioChannels), rate: \(demuxer.audioSampleRate)"
            )
        } else {
            self.audioDecoder = nil
            AppLog.warning(.audio, "No audio track found or failed to get codec parameters")
        }

        if !demuxer.hasVideo {
            clearVideoSurface()
        } else {
            _ = self.sampleBufferRenderer.perform(Self.flushSelector)
        }
        self.audioReceiver.flush()
        self.audioDecoder?.flush()

        // Determine effective start time using the priority chain:
        // 1. Explicit requestedStartTime (CLI, host app, deep link)
        // 2. PlaybackHistoryStore saved position (if resume is enabled)
        // 3. Fallback to 0.0
        let effectiveStartTime: Double
        if let explicit = requestedStartTime, explicit > 0 {
            effectiveStartTime = min(explicit, max(0.0, self.duration - 1.0))
            AppLog.info(.engine, "Using explicit start time: \(effectiveStartTime)s (ignoring history)")
        } else if configuration.resumePlayback,
            let saved = historyStore.savedPosition(
                for: path,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio
            )
        {
            effectiveStartTime = min(saved, max(0.0, self.duration - 1.0))
            AppLog.info(.engine, "Resuming playback from saved history: \(effectiveStartTime)s")
        } else {
            effectiveStartTime = 0.0
        }

        if effectiveStartTime > 0 {
            demuxer.seek(to: effectiveStartTime)
            demuxer.purgeAudio(beforeSeconds: effectiveStartTime)
        }

        self.currentTime = effectiveStartTime
        self.isLoaded = true
        self.isLoading = false

        let decoder = self.decoder
        let hasVideo = demuxer.hasVideo
        let loadID = self.currentLoadID
        let seekId = self.currentSeekId
        self.feedQueue.async { [weak self] in
            if hasVideo {
                decoder.flush()
            }
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.currentLoadID == loadID else { return }
                self.frameQueue.clear(resetDroppedFrames: true)
                self.startFeeding()
                if self.currentSeekId == seekId && self.chaseTargetTime == nil {
                    let targetCMTime = CMTime(seconds: effectiveStartTime, preferredTimescale: 60000)
                    self.currentTime = effectiveStartTime
                    self.synchronizer.setRate(Float(self.playbackRate), time: targetCMTime)
                }
                self.displayLink?.isPaused = !hasVideo
                self.isPlaying = true
                self.playbackState = .playing
                self.performanceMonitor.handlePlaybackStateChange(isPlaying: true)
            }
        }
    }

    nonisolated private func checkBackpressureAndResumeIfNeeded() {
        let shouldResume = isVideoDrainPaused.withLock { isPaused -> Bool in
            if isPaused {
                isPaused = false
                return true
            }
            return false
        }
        guard shouldResume, isFeeding.withLock({ $0 }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFeeding.withLock({ $0 }) else { return }
            self.startFeedingVideo()
        }
    }

    private func stopFeedingVideo() {
        videoFeedingTask?.cancel()
        videoFeedingTask = nil
    }

    private func stopFeedingAudio() {
        audioFeedingTask?.cancel()
        audioFeedingTask = nil
    }

    private func startFeeding() {
        guard let demuxer = self.demuxer else { return }
        isFeeding.withLock { $0 = true }
        isVideoDrainPaused.withLock { $0 = false }

        if demuxer.hasVideo {
            startFeedingVideo()
        }
        startFeedingAudio()
    }

    private func startFeedingVideo() {
        guard let demuxer = self.demuxer else { return }
        stopFeedingVideo()

        let feedingLock = self.isFeeding
        let drainPausedLock = self.isVideoDrainPaused
        let decoder = self.decoder
        let queue = self.frameQueue

        videoFeedingTask = Task.detached(priority: .userInitiated) {
            await Self.runVideoFeeding(
                demuxer: demuxer,
                decoder: decoder,
                queue: queue,
                feedingLock: feedingLock,
                drainPausedLock: drainPausedLock
            )
        }
    }

    private nonisolated static func runVideoFeeding(
        demuxer: MediaDemuxer,
        decoder: any VideoDecoderProtocol,
        queue: FrameQueue,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        drainPausedLock: OSAllocatedUnfairLock<Bool>
    ) async {
        let sampleCountLock = OSAllocatedUnfairLock(initialState: 0)
        while !Task.isCancelled && feedingLock.withLock({ $0 }) {
            // Cooperative backpressure: pause decoding when queue has >= 40 frames
            if queue.count >= 40 {
                drainPausedLock.withLock { $0 = true }
                while !Task.isCancelled && queue.count > 25 && feedingLock.withLock({ $0 }) {
                    try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                }
                drainPausedLock.withLock { $0 = false }
                if Task.isCancelled || !feedingLock.withLock({ $0 }) { break }
            }

            guard let sample = demuxer.nextVideoSample() else {
                if demuxer.isEOF {
                    AppLog.debug(.engine, "Demuxer reached EOF for video. Draining decoder...")
                    decoder.drain()
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }

            let count = sampleCountLock.withLock { count -> Int in
                count += 1
                return count
            }
            if count <= 5 || count % 200 == 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                AppLog.debug(
                    .video,
                    "Decoding video sample #\(count), pts: \(CMTimeGetSeconds(pts))s, queueCount: \(queue.count)"
                )
            }

            let signpostID = PlayerPerformanceMonitor.shared.signposter.makeSignpostID()
            let interval = PlayerPerformanceMonitor.shared.signposter.beginInterval(
                "EnqueueDecodeFrame", id: signpostID)
            decoder.decode(sampleBuffer: sample)
            PlayerPerformanceMonitor.shared.signposter.endInterval("EnqueueDecodeFrame", interval)
        }
    }

    private func startFeedingAudio() {
        guard let demuxer = self.demuxer, let aDecoder = self.audioDecoder else { return }
        stopFeedingAudio()

        let feedingLock = self.isFeeding
        let receiver = self.audioReceiver
        let audioTimebase = demuxer.audioTimebase

        audioFeedingTask = Task.detached(priority: .userInitiated) {
            await Self.runAudioFeeding(
                demuxer: demuxer,
                audioDecoder: aDecoder,
                receiver: receiver,
                feedingLock: feedingLock,
                audioTimebase: audioTimebase
            )
        }
    }

    private nonisolated static func runAudioFeeding(
        demuxer: MediaDemuxer,
        audioDecoder: FFAudioDecoder,
        receiver: AVSampleBufferAudioRenderer.Receiver,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        audioTimebase: AVRational
    ) async {
        while !Task.isCancelled && feedingLock.withLock({ $0 }) {
            guard let packet = demuxer.nextAudioPacket() else {
                if demuxer.isEOF {
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            let pcmBuffers = audioDecoder.decode(
                packetData: packet.data,
                pts: packet.pts,
                timebase: audioTimebase
            )
            for buf in pcmBuffers {
                if Task.isCancelled || !feedingLock.withLock({ $0 }) { break }
                nonisolated(unsafe) let sBuf = buf
                let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent> = CMReadySampleBuffer(unsafeBuffer: sBuf)
                _ = try? await receiver.enqueue(ready)
            }
        }
    }

    public func selectAudioTrack(id: Int) {
        guard let demuxer = self.demuxer else { return }
        AppLog.info(.audio, "Switching to audio track: \(id)")
        let wasPlaying = isPlaying
        pause()

        // Stop requesting data and flush renderers
        stopFeedingAudio()
        audioReceiver.flush()
        audioDecoder?.flush()

        demuxer.selectAudioTrack(trackId: id)
        self.selectedAudioTrackId = id
        saveCurrentPlaybackProgress()
        if let params = demuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        } else {
            self.audioDecoder = nil
        }

        if wasPlaying {
            play()
        }
    }

    public func selectSubtitleTrack(id: Int?) {
        selectSubtitleTrack(id: id, persistHistory: true)
    }

    private func selectSubtitleTrack(id: Int?, persistHistory: Bool) {
        guard let id else {
            // Disable subtitles
            self.selectedSubtitleTrackId = nil
            self.activeSubtitleDocument = nil
            self.currentSubtitleCues.removeAll()
            self.lastObservedLiveSubtitleVersion = -1
            demuxer?.selectSubtitleTrack(trackId: nil)
            if persistHistory {
                saveCurrentPlaybackProgress()
            }
            return
        }

        guard let track = subtitleTracks.first(where: { $0.id == id }) else { return }
        self.selectedSubtitleTrackId = id
        demuxer?.selectSubtitleTrack(trackId: id)
        if persistHistory {
            saveCurrentPlaybackProgress()
        }

        if track.isExternal {
            self.activeSubtitleDocument = loadedSubtitleDocuments[id]
            self.updateActiveSubtitles(at: currentTime)
        } else if let path = currentPath {
            if MediaDemuxer.isNetworkURL(path) {
                // For network streams: bind immediately to in-band demuxed cues.
                // Do NOT launch a background secondary demuxer that hangs trying to reach EOF or fails on single-token URLs.
                let liveDoc = demuxer?.getLiveSubtitleDocument() ?? SubtitleDocument(cues: [])
                self.lastObservedLiveSubtitleVersion = demuxer?.liveSubtitleVersion ?? -1
                self.activeSubtitleDocument = liveDoc
                self.updateActiveSubtitles(at: currentTime)
                AppLog.info(
                    .subtitles,
                    "Selected network subtitle track id=\(id) ('\(track.title)'). Active in-band streaming."
                )
            } else if let cached = loadedSubtitleDocuments[id] {
                self.activeSubtitleDocument = cached
                self.updateActiveSubtitles(at: currentTime)
            } else {
                let headers = self.currentHeaders
                let demuxer = self.demuxer
                Task.detached(priority: .userInitiated) { [weak self, demuxer, path, headers] in
                    let doc = demuxer?.loadSubtitleDocument(for: id, url: path, headers: headers)
                    await MainActor.run {
                        guard let self, self.selectedSubtitleTrackId == id else { return }
                        if let doc {
                            self.loadedSubtitleDocuments[id] = doc
                            self.activeSubtitleDocument = doc
                            self.updateActiveSubtitles(at: self.currentTime)
                        } else {
                            AppLog.warning(
                                .subtitles,
                                "Warning: Failed to extract embedded subtitle document for track id=\(id)"
                            )
                        }
                    }
                }
            }
        }
    }

    public func loadExternalSubtitle(url: URL) {
        var content: String? = nil
        let encodings: [String.Encoding] = [.utf8, .windowsCP1251, .windowsCP1252, .isoLatin1, .utf16]
        for enc in encodings {
            if let str = try? String(contentsOf: url, encoding: enc) {
                content = str
                break
            }
        }

        guard let validContent = content else {
            AppLog.error(.subtitles, "Unable to decode subtitle file with supported encodings: \(url)")
            return
        }

        let isVTT = url.pathExtension.lowercased() == "vtt" || validContent.hasPrefix("WEBVTT")
        let document = isVTT ? SubtitleDocument.parseWebVTT(validContent) : SubtitleDocument.parseSRT(validContent)

        let trackId = 1000 + subtitleTracks.count
        let trackName = url.deletingPathExtension().lastPathComponent
        let track = SubtitleTrack(
            id: trackId,
            streamIndex: -1,
            title: "\(trackName) (External)",
            language: "und",
            isExternal: true
        )
        subtitleTracks.append(track)
        loadedSubtitleDocuments[trackId] = document
        selectSubtitleTrack(id: trackId)
    }

    public func play() {
        resetRelativeSeekBurst()
        guard isLoaded else { return }

        // If video reached the end or is in completed state, restart from the beginning
        if playbackState == .completed || (duration > 0 && currentTime >= (duration - 0.25)) {
            seek(to: 0.0)
        }

        // If a chase seek is currently in flight or queued, record intent to play once seeking finishes
        if isSeeking || chaseTargetTime != nil {
            resumePlaybackAfterChase = true
            return
        }

        let feedingActive = isFeeding.withLock { $0 }
        if !feedingActive {
            startFeeding()
        }
        synchronizer.setRate(Float(playbackRate), time: synchronizer.currentTime())
        displayLink?.isPaused = !hasVideo
        isPlaying = true
        playbackState = .playing
        performanceMonitor.handlePlaybackStateChange(isPlaying: true)
    }

    public func pause() {
        resetRelativeSeekBurst()
        if isSeeking || chaseTargetTime != nil {
            resumePlaybackAfterChase = false
        }
        stopPlaybackPipeline()
        playbackState = .paused
        saveCurrentPlaybackProgress()
    }

    /// Halts clock synchronization and feeders without altering user-facing isPlaying or playbackState.
    private func haltPlaybackPipeline() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        displayLink?.isPaused = true
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        seekTask?.cancel()
        seekTask = nil
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
    }

    /// Stops audio/video feeding and halts the clock, marking playback as paused.
    private func stopPlaybackPipeline() {
        haltPlaybackPipeline()
        isPlaying = false
        performanceMonitor.handlePlaybackStateChange(isPlaying: false)
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(to seconds: Double) {
        seek(to: seconds, exact: true)
    }

    public func seek(to seconds: Double, exact: Bool) {
        resetRelativeSeekBurst()
        seek(to: seconds, exact: exact, forward: false)
    }

    private func resetRelativeSeekBurst() {
        relativeSeekBurstResetTask?.cancel()
        relativeSeekBurstResetTask = nil
        isRelativeSeekBurstActive = false
        isRelativeSeekInFlight = false
        relativeSeekSessionStartTime = nil
    }

    private func armRelativeSeekBurstTimer() {
        relativeSeekBurstResetTask?.cancel()
        relativeSeekBurstResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.relativeSeekBurstTimeout)
            guard !Task.isCancelled, let self else { return }
            if !self.isSeeking && self.chaseTargetTime == nil {
                self.resetRelativeSeekBurst()
            } else if !self.isRelativeSeekInFlight {
                self.resetRelativeSeekBurst()
            } else {
                // Safety watchdog: if in-flight seek hangs or takes unusually long, reset unconditionally
                try? await Task.sleep(for: Self.relativeSeekBurstWatchdogTimeout)
                guard !Task.isCancelled else { return }
                self.resetRelativeSeekBurst()
            }
        }
    }

    private func seek(to seconds: Double, exact: Bool, forward: Bool) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        AppLog.info(.engine, "Seek requested to seconds: \(target), exact: \(exact), forward: \(forward)")
        guard demuxer != nil else { return }

        // Cancel any pending settle debounce from an earlier seek in the burst
        chaseSettleTask?.cancel()
        chaseSettleTask = nil

        // 1. Maintain play intent across seek bursts (Apple QA1820 / mpv)
        if !isSeeking && chaseTargetTime == nil {
            resumePlaybackAfterChase = isPlaying
            if isPlaying {
                // Instantly pause playback clock during active seek burst to prevent clock jitter
                synchronizer.setRate(0.0, time: synchronizer.currentTime())
            }
        }

        // 2. Immediate responsive UI update (0ms latency for exact seek)
        chaseTargetTime = target
        chaseExactSeek = exact
        chaseForwardSeek = forward
        if exact {
            currentTime = target
            updateActiveSubtitles(at: target)
        }

        // 3. Increment generation token
        currentSeekId += 1
        let seekId = currentSeekId
        activeSeekId.withLock { $0 = seekId }

        // 4. If a seek is already in flight on seekQueue, let it complete its current work;
        // it will check activeSeekId and latest chaseTargetTime upon finishing.
        if isSeeking { return }

        executeDemuxerSeek()
    }

    private func executeDemuxerSeek() {
        guard let targetSeconds = chaseTargetTime else { return }
        guard let demuxer = self.demuxer else { return }

        isSeeking = true
        let isExact = self.chaseExactSeek
        let isForward = self.chaseForwardSeek
        let seekId = currentSeekId

        let shouldResume = self.resumePlaybackAfterChase

        // Stop feeding packets from the old position.
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        frameQueue.clear(resetDroppedFrames: true)

        let decoder = self.decoder
        let audioDecoder = self.audioDecoder
        let audioReceiver = self.audioReceiver
        let hasVideo = self.hasVideo
        let seekIdLock = self.activeSeekId
        let frameQueue = self.frameQueue

        seekQueue.async { [weak self, demuxer, decoder, frameQueue] in
            guard let self else { return }

            let isSuperseded = {
                seekIdLock.withLock { $0 != seekId }
            }

            if !isSuperseded() {
                if hasVideo {
                    decoder.flush()
                }
                demuxer.seek(to: targetSeconds, exact: isExact, forward: isForward)
            }

            var previewFrame: SeekPreviewResult? = nil
            if hasVideo {
                previewFrame = Self.seekPreview(
                    demuxer: demuxer,
                    decoder: decoder,
                    frameQueue: frameQueue,
                    seconds: targetSeconds,
                    exact: isExact,
                    isCurrent: { !isSuperseded() }
                )
                let resolvedSeconds = previewFrame?.pts ?? targetSeconds
                if !isExact, let preview = previewFrame {
                    demuxer.setTargetAudioPts(seconds: preview.pts)
                }
                if !shouldResume {
                    demuxer.purgeAudio(beforeSeconds: resolvedSeconds)
                }
                // Render the freshly previewed frame directly (avoiding queue miss & stale fallback)
                if !isSuperseded(), let preview = previewFrame {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.currentSeekId == seekId else { return }
                        self.renderDirect(pixelBuffer: preview.pixelBuffer, pts: preview.pts)
                    }
                }
            }

            // Expensive audio reset only for the seek that is still current (final chase target).
            if !isSuperseded() {
                audioDecoder?.flush()
                audioReceiver.flush()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // If superseded by a newer target, immediately continue to the latest chase position
                if self.currentSeekId != seekId {
                    if self.chaseTargetTime != nil {
                        self.executeDemuxerSeek()
                    } else {
                        self.isSeeking = false
                        self.isRelativeSeekInFlight = false
                    }
                    return
                }
                let resolvedSeconds = previewFrame?.pts ?? targetSeconds
                let resolvedTime = CMTime(seconds: resolvedSeconds, preferredTimescale: 1000)
                let didRenderPreview = previewFrame != nil
                self.completeChaseSeek(
                    targetSeconds: targetSeconds,
                    completedSeconds: resolvedSeconds,
                    targetTime: resolvedTime,
                    seekId: seekId,
                    didRenderPreview: didRenderPreview
                )
            }
        }
    }

    private func completeChaseSeek(
        targetSeconds: Double,
        completedSeconds: Double,
        targetTime: CMTime,
        seekId: Int,
        didRenderPreview: Bool
    ) {
        guard currentSeekId == seekId else {
            if chaseTargetTime != nil {
                executeDemuxerSeek()
            } else {
                self.isSeeking = false
                self.isRelativeSeekInFlight = false
            }
            return
        }

        // Check if user requested a newer position while this seek was executing (Apple QA1820 / mpv queue_seek)
        if let latestTarget = chaseTargetTime, abs(latestTarget - targetSeconds) > 0.001 {
            // Chase the newer target immediately without resuming yet.
            executeDemuxerSeek()
            return
        }

        // Settled decoding for this position. Mark seek background work as done.
        isSeeking = false

        // If a preview frame was already rendered directly via renderDirect, do NOT overwrite it
        // by popping from frameQueue.getLatestFrame (which may drop preroll frames tagged doNotDisplay).
        if hasVideo && !didRenderPreview {
            renderCurrentFrame(at: targetTime)
        }

        // Immediately apply actual completed PTS so timer and subtitles match the displayed keyframe
        self.currentTime = completedSeconds
        updateActiveSubtitles(at: completedSeconds)
        onTimeUpdate?(completedSeconds, duration)

        if isRelativeSeekInFlight {
            isRelativeSeekInFlight = false
            armRelativeSeekBurstTimer()
        }

        if let sessionStart = relativeSeekSessionStartTime {
            let actualOffset = completedSeconds - sessionStart
            onRelativeSeekResolved?(actualOffset, completedSeconds)
        }

        let shouldResume = resumePlaybackAfterChase
        if !shouldResume {
            // Paused mode: settle immediately
            chaseTargetTime = nil
            synchronizer.setRate(0.0, time: targetTime)
            isPlaying = false
            playbackState = .paused
            performanceMonitor.handlePlaybackStateChange(isPlaying: false)
            AppLog.debug(.engine, "Chase seek settled at \(completedSeconds)s (paused)")
            return
        }

        // Playing mode: debounce resumption slightly (300ms) so that sustained key-hold repeat
        // events (which fire every 40-70ms) don't repeatedly unpause and roll the clock forward.
        chaseTargetTime = completedSeconds
        chaseSettleTask?.cancel()
        chaseSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.chaseSettleDebounceDuration)
            guard !Task.isCancelled, let self, self.currentSeekId == seekId else { return }

            self.chaseTargetTime = nil
            self.startFeeding()
            self.synchronizer.setRate(Float(self.playbackRate), time: targetTime)
            self.displayLink?.isPaused = !self.hasVideo
            self.isPlaying = true
            self.playbackState = .playing
            self.performanceMonitor.handlePlaybackStateChange(isPlaying: true)
            AppLog.debug(.engine, "Chase seek settled and resumed at \(completedSeconds)s")
        }
    }

    private struct SeekPreviewResult: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let pts: Double
    }

    private final class SeekPreviewBox: @unchecked Sendable {
        var buffer: CVPixelBuffer?
        var pts: Double = -1.0
    }

    private nonisolated static func seekPreview(
        demuxer: MediaDemuxer,
        decoder: any VideoDecoderProtocol,
        frameQueue: FrameQueue,
        seconds: Double,
        exact: Bool,
        isCurrent: () -> Bool
    ) -> SeekPreviewResult? {
        let lock = OSAllocatedUnfairLock()
        let box = SeekPreviewBox()
        decoder.setOutputHandler { frame in
            frameQueue.push(frame)
            if (exact || !frame.doNotDisplay) && frame.pts.isValid {
                lock.lock()
                let framePts = frame.pts.seconds
                let shouldUpdate: Bool
                if box.buffer == nil {
                    shouldUpdate = true
                } else if exact {
                    // Exact seek: select the decoded frame closest to the requested target time,
                    // handling out-of-order B-frames and trailing pipeline flushes accurately.
                    shouldUpdate = abs(framePts - seconds) <= abs(box.pts - seconds)
                } else {
                    // Keyframe seek: keep the earliest displayable frame (frame-threaded decoders
                    // may emit several frames once their pipeline fills).
                    shouldUpdate = framePts < box.pts
                }

                if shouldUpdate {
                    box.buffer = frame.pixelBuffer
                    box.pts = framePts
                }
                lock.unlock()
            }
        }

        defer {
            decoder.setOutputHandler { [weak frameQueue] frame in
                frameQueue?.push(frame)
            }
        }

        let hasPreview: () -> Bool = {
            lock.lock()
            defer { lock.unlock() }
            return box.buffer != nil
        }

        var attempts = 0
        var reachedTargetPacket = false
        var extraPipelineAttempts = 0
        var foundTarget = false
        var decodedAtLeastOne = false
        var hasCalculatedMaxAttempts = false
        // For non-exact (keyframe) seeks (IINA / mpv style), decode from the keyframe until the decoder
        // emits its first frame (1 packet for VideoToolbox; a few for frame-threaded libdav1d).
        // For exact seeks, decode from keyframe up to target seconds, dynamically sizing the attempt limit
        // based on the distance between the landing keyframe and the requested target position.
        var maxAttempts = exact ? 120 : 24
        while attempts < maxAttempts && !foundTarget && (isCurrent() || !decodedAtLeastOne) {
            if let sample = demuxer.nextVideoSample() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let ptsSeconds = CMTimeGetSeconds(pts)

                if exact && !hasCalculatedMaxAttempts && ptsSeconds.isFinite {
                    hasCalculatedMaxAttempts = true
                    // Dynamic ceiling: estimate needed packets from keyframe to target position.
                    // Generous 60fps * 1.5 multiplier + buffer accommodates 60fps streams, VFR, and B-frame reordering.
                    let distance = max(seconds - ptsSeconds, 1.0)
                    let estimatedPackets = Int(distance * 90.0) + 64
                    maxAttempts = min(max(estimatedPackets, 120), 1200)
                }

                decoder.decode(sampleBuffer: sample)
                decodedAtLeastOne = true
                attempts += 1
                if exact {
                    if ptsSeconds >= seconds {
                        reachedTargetPacket = true
                    }
                    if reachedTargetPacket {
                        decoder.waitForPendingFrames()
                        // Ensure we feed at least 6 packets past reachedTargetPacket so that
                        // any trailing B-frames or reordered pictures in display order are decoded.
                        extraPipelineAttempts += 1
                        if hasPreview() && extraPipelineAttempts >= 6 {
                            foundTarget = true
                        } else if extraPipelineAttempts >= 16 {
                            foundTarget = true
                        }
                    }
                } else {
                    decoder.waitForPendingFrames()
                    if hasPreview() { foundTarget = true }
                }
            } else {
                break
            }
        }
        // Non-destructive: decoding continues from the next packet in runVideoFeeding, so the
        // decoder's reference frames must be preserved (a destructive flush breaks AV1/dav1d).
        decoder.waitForPendingFrames()

        lock.lock()
        let finalBuf = box.buffer
        let finalPts = box.pts
        lock.unlock()

        if let finalBuf, finalPts >= 0 {
            AppLog.debug(
                .engine,
                "seekPreview settled: pts=\(finalPts)s for target=\(seconds)s (exact=\(exact), attempts=\(attempts))")
            return SeekPreviewResult(pixelBuffer: finalBuf, pts: finalPts)
        }
        AppLog.debug(
            .engine, "seekPreview found no frame for target=\(seconds)s (exact=\(exact), attempts=\(attempts))")
        return nil
    }

    @discardableResult
    public func seekRelative(by seconds: Double) -> Double {
        guard isLoaded, demuxer != nil else { return 0.0 }
        armRelativeSeekBurstTimer()

        let isFirstInBurst = !isRelativeSeekBurstActive && !isRelativeSeekInFlight
        isRelativeSeekBurstActive = true
        isRelativeSeekInFlight = true

        // While a seek is in flight, baseTime steps from the pending target (mpv queue_seek model).
        // On slow frame-threaded streams (e.g. software AV1), rapid keypresses advance the goal,
        // while the demuxer chases the latest target to prevent stale frame freezes.
        let baseTime = chaseTargetTime ?? currentTime
        if isFirstInBurst || relativeSeekSessionStartTime == nil {
            relativeSeekSessionStartTime = baseTime
        }

        let isExact = !hasVideo || (exactSeekOnSinglePress && isFirstInBurst)
        let isForward = seconds > 0 && !isExact

        // In burst mode (keyframe seek), always step from the latest targeted or settled frame
        // so every press advances past the current GOP to the next/prev keyframe without freezing.
        seek(to: baseTime + seconds, exact: isExact, forward: isForward)

        let startPos = relativeSeekSessionStartTime ?? baseTime
        return (chaseTargetTime ?? currentTime) - startPos
    }

    public func seekRelative(by seconds: Double, exact: Bool) {
        resetRelativeSeekBurst()
        let baseTime = chaseTargetTime ?? currentTime
        // Forward keyframe steps must land on the next keyframe; a backward search on sparse-GOP
        // streams (AV1) would snap back to the current keyframe and the position would never advance.
        seek(to: baseTime + seconds, exact: exact, forward: seconds > 0 && !exact)
    }

    public func stepFrameForward() {
        stepFrame(forward: true)
    }

    public func stepFrameBackward() {
        stepFrame(forward: false)
    }

    private func stepFrame(forward: Bool) {
        if isPlaying { pause() }
        let stepDuration = demuxer?.nominalFrameDuration ?? (hasVideo ? (1.0 / 24.0) : 1.0)
        resumePlaybackAfterChase = false
        let baseTime = chaseTargetTime ?? (currentFramePTS >= 0 ? currentFramePTS : currentTime)
        let targetTime = forward ? (baseTime + stepDuration) : (baseTime - stepDuration * 1.05)
        let clampedTarget = max(0, duration > 0 ? min(targetTime, duration) : targetTime)
        seek(to: clampedTarget)
    }

    public func stepVolume(by delta: Float) {
        volume = max(0.0, min(1.0, volume + delta))
    }

    public func toggleMute() {
        isMuted.toggle()
    }

    public func setPlaybackRate(_ rate: Double) {
        let rounded = (rate * 100).rounded() / 100.0
        let clamped = max(0.5, min(rounded, 4.0))
        guard clamped != playbackRate else { return }
        playbackRate = clamped
        AppLog.info(.engine, "Playback rate changed to \(playbackRate)x")
    }

    public func stepPlaybackRate(by delta: Double) {
        let target = ((playbackRate + delta) * 10).rounded() / 10.0
        setPlaybackRate(target)
    }

    public func resetPlaybackRate() {
        setPlaybackRate(1.0)
    }

    public func toggleDebugHUD() {
        showDebugHUD.toggle()
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
