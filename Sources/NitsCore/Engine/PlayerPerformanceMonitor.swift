import Darwin
import Foundation
import QuartzCore
import os

/// Provides low-overhead runtime statistics for the media engine:
/// - Process CPU % and memory footprint (via Mach task/thread APIs)
/// - Rendering FPS and frame delivery interval
/// - Video buffer queue fill level
/// - Apple `os.OSSignposter` intervals for Instruments profiling
public final class PlayerPerformanceMonitor: @unchecked Sendable {
    public static let shared = PlayerPerformanceMonitor()

    // Signposter for Instruments profiling (Points of Interest)
    private let logger = Logger(subsystem: "com.nits.app", category: "Performance")
    public let signposter: OSSignposter

    public enum ToneMapEngineMode: String, Sendable, Equatable {
        case none = ""
        case doviL2Trim = "DoVi L2 SDR Trim"
        case doviL1Auto = "DoVi L1 Dynamic"
        case hdr10PlusDynamic = "HDR10+ Dynamic"
        case bt2390 = "Metal BT.2390 EETF"
        case directSDR = "Direct SDR (Display P3)"
        case appleXDR = "Apple HDR Passthrough (Direct Scanout)"
    }

    public struct ToneMapParams: Sendable, Equatable {
        public var mode: ToneMapEngineMode = .none
        public var slope: Float = 1.0
        public var offset: Float = 0.0
        public var power: Float = 1.0
        public var saturation: Float = 0.0
        public var peakNits: Float = 0.0
        public var targetNits: Float = 203.0

        public init(
            mode: ToneMapEngineMode = .none,
            slope: Float = 1.0,
            offset: Float = 0.0,
            power: Float = 1.0,
            saturation: Float = 0.0,
            peakNits: Float = 0.0,
            targetNits: Float = 203.0
        ) {
            self.mode = mode
            self.slope = slope
            self.offset = offset
            self.power = power
            self.saturation = saturation
            self.peakNits = peakNits
            self.targetNits = targetNits
        }
    }

    public struct Metrics: Sendable, Equatable {
        // Performance
        public var cpuUsagePercent: Double = 0.0
        public var memoryUsageMB: Double = 0.0
        public var renderFps: Double = 0.0
        public var renderDurationMs: Double = 0.0
        public var frameQueueCount: Int = 0
        public var activeRenderModeName: String = "SDR"
        public var isDrainPaused: Bool = false
        public var droppedFrames: Int = 0
        public var pipelineDroppedFrames: Int = 0
        public var speedSkippedFrames: Int = 0
        public var playbackRate: Double = 1.0

        // Native pipeline details
        public var nativeFeedRate: Double = 0.0
        public var nativeEnqueuedFrames: Int = 0
        public var nativeLayerStatus: String = "Ready"

        // Stream details
        public var resolution: String = ""
        public var codecName: String = ""
        public var bitDepth: Int = 8
        public var colorPrimaries: String = ""
        public var transferFunction: String = ""
        public var sourcePeakNits: Float = 0
        public var targetNits: Float = 203
        public var avSyncDriftMs: Double = 0.0

        // Dolby Vision & Tone-Mapping details
        public var dolbyVisionProfile: String? = nil
        public var toneMapParams: ToneMapParams = ToneMapParams()
        public var toneMapPipeline: String {
            toneMapParams.mode.rawValue
        }
    }

    private let metricsLock = OSAllocatedUnfairLock(initialState: Metrics())
    public var currentMetrics: Metrics {
        metricsLock.withLock { $0 }
    }

    // FPS calculation tracking
    private let fpsLock = OSAllocatedUnfairLock(initialState: (frameCount: 0, lastTimestamp: CACurrentMediaTime()))
    // Native feed rate calculation tracking
    private let nativeRateLock = OSAllocatedUnfairLock(
        initialState: (sampleCount: 0, totalCount: 0, lastTimestamp: CACurrentMediaTime()))

    // Mach timebase info for duration measurements
    private var timebaseInfo = mach_timebase_info()

    public init() {
        self.signposter = OSSignposter(logger: logger)
        mach_timebase_info(&timebaseInfo)
    }

    /// Records that a frame was rendered by CADisplayLink / MetalVideoRenderer.
    public func recordRenderedFrame(
        durationMs: Double,
        queueCount: Int,
        renderModeName: String,
        isDrainPaused: Bool,
        avSyncDriftMs: Double,
        droppedFrames: Int,
        pipelineDroppedFrames: Int = 0,
        speedSkippedFrames: Int = 0,
        playbackRate: Double = 1.0
    ) {
        let now = CACurrentMediaTime()

        let calculatedFps = fpsLock.withLock { state -> Double? in
            state.frameCount += 1
            let elapsed = now - state.lastTimestamp
            if elapsed >= 0.5 {
                let fps = Double(state.frameCount) / elapsed
                state.frameCount = 0
                state.lastTimestamp = now
                return fps
            }
            return nil
        }

        metricsLock.withLock { metrics in
            if let fps = calculatedFps {
                metrics.renderFps = fps
            }
            metrics.renderDurationMs = durationMs
            metrics.frameQueueCount = queueCount
            metrics.activeRenderModeName = renderModeName
            metrics.isDrainPaused = isDrainPaused
            metrics.avSyncDriftMs = avSyncDriftMs
            metrics.droppedFrames = droppedFrames
            metrics.pipelineDroppedFrames = pipelineDroppedFrames
            metrics.speedSkippedFrames = speedSkippedFrames
            metrics.playbackRate = playbackRate
        }
    }

    /// Records that a video sample buffer was enqueued directly into AVSampleBufferDisplayLayer (Native HDR mode).
    public func recordNativeEnqueuedSample() {
        let now = CACurrentMediaTime()
        let calculatedRate = nativeRateLock.withLock { state -> (rate: Double?, total: Int) in
            state.sampleCount += 1
            state.totalCount += 1
            let elapsed = now - state.lastTimestamp
            if elapsed >= 0.5 {
                let rate = Double(state.sampleCount) / elapsed
                state.sampleCount = 0
                state.lastTimestamp = now
                return (rate, state.totalCount)
            }
            return (nil, state.totalCount)
        }

        metricsLock.withLock { metrics in
            if let rate = calculatedRate.rate {
                metrics.nativeFeedRate = rate
            }
            metrics.nativeEnqueuedFrames = calculatedRate.total
        }
    }

    /// Updates the current status description of AVSampleBufferDisplayLayer.
    public func updateNativeLayerStatus(_ statusDescription: String) {
        metricsLock.withLock { metrics in
            metrics.nativeLayerStatus = statusDescription
        }
    }

    /// Resets rendering/feed rates when playback pauses to avoid stale FPS in the HUD.
    public func handlePlaybackStateChange(isPlaying: Bool) {
        if !isPlaying {
            fpsLock.withLock { state in
                state.frameCount = 0
                state.lastTimestamp = CACurrentMediaTime()
            }
            nativeRateLock.withLock { state in
                state.sampleCount = 0
                state.lastTimestamp = CACurrentMediaTime()
            }
            metricsLock.withLock { metrics in
                metrics.renderFps = 0.0
                metrics.nativeFeedRate = 0.0
            }
        }
    }

    /// Updates static or slowly changing stream/color metadata from demuxer and configuration.
    public func updateStreamMetadata(
        resolution: String,
        codecName: String,
        bitDepth: Int,
        colorPrimaries: String,
        transferFunction: String,
        sourcePeakNits: Float,
        targetNits: Float,
        dolbyVisionProfile: String? = nil
    ) {
        metricsLock.withLock { metrics in
            metrics.resolution = resolution
            metrics.codecName = codecName
            metrics.bitDepth = bitDepth
            metrics.colorPrimaries = colorPrimaries
            metrics.transferFunction = transferFunction
            metrics.sourcePeakNits = sourcePeakNits
            metrics.targetNits = targetNits
            metrics.dolbyVisionProfile = dolbyVisionProfile
        }
    }

    /// Updates dynamic tone-mapping parameters if changed (comparing raw numeric values without heap allocation).
    public func updateToneMapParams(_ params: ToneMapParams) {
        metricsLock.withLock { metrics in
            if metrics.toneMapParams != params {
                metrics.toneMapParams = params
                metrics.sourcePeakNits = params.peakNits
                metrics.targetNits = params.targetNits
            }
        }
    }

    /// Updates target reference white nits dynamically.
    public func updateTargetNits(_ targetNits: Float) {
        metricsLock.withLock { metrics in
            metrics.targetNits = targetNits
        }
    }

    /// Updates process-wide CPU and memory metrics (called periodically, e.g. every 500ms).
    public func updateProcessMetrics() {
        let cpu = currentProcessCpuPercentage()
        let memory = currentProcessMemoryFootprintMB()

        metricsLock.withLock { metrics in
            metrics.cpuUsagePercent = cpu
            metrics.memoryUsageMB = memory
        }
    }

    // MARK: - Mach Kernel Queries

    private func currentProcessCpuPercentage() -> Double {
        var threadsList: thread_act_array_t?
        var threadsCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadsList, &threadsCount)
        guard kr == KERN_SUCCESS, let threads = threadsList else { return 0.0 }

        defer {
            for i in 0..<Int(threadsCount) {
                mach_port_deallocate(mach_task_self_, threads[i])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: threads),
                vm_size_t(threadsCount * UInt32(MemoryLayout<thread_t>.stride))
            )
        }

        var totalCpuUsage: Double = 0.0
        for i in 0..<Int(threadsCount) {
            var threadInfo = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let threadKr = withUnsafeMutablePointer(to: &threadInfo) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: 1) { intPtr in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), intPtr, &count)
                }
            }

            if threadKr == KERN_SUCCESS {
                if (threadInfo.flags & TH_FLAGS_IDLE) == 0 {
                    totalCpuUsage += (Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
                }
            }
        }
        return totalCpuUsage
    }

    private func currentProcessMemoryFootprintMB() -> Double {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &taskInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: 1) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0.0 }
        return Double(taskInfo.phys_footprint) / (1024.0 * 1024.0)
    }
}
