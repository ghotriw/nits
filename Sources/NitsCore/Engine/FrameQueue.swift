import CoreMedia
import CoreVideo
import Foundation
import os

/// A high-performance, PTS-sorted ring buffer for decoded video frames.
///
/// Designed specifically for VSYNC deadlines up to 120Hz (ProMotion):
/// - **Zero Allocation:** Backed by a fixed-capacity ring buffer (`[DecodedFrame?]`), avoiding memory reallocations.
/// - **O(1) Pop & Instant Surface Release:** Fast head pointer advancement and immediate `nil` clearing of popped slots,
///   promptly returning `IOSurface` backing memory to the `VTDecompressionSession` hardware pool.
/// - **PTS Sorting with Fast-Path Append & Binary Search:** Preserves strict PTS ordering across B-frames.
///   95% of frames (in-order PTS) append at `tail` in O(1); out-of-order B-frames (1–3 slots backward) use O(log N)
///   binary search and minimal slot shifting within the ring.
public final class FrameQueue: @unchecked Sendable {
    public static let defaultCapacity: Int = 60
    static let droppedFramesWarningThreshold: Int = 1

    private let lock = OSAllocatedUnfairLock()
    private let capacity: Int
    private var buffer: [DecodedFrame?]
    private var head: Int = 0
    private var countInternal: Int = 0
    private var lastRenderedBuffer: CVPixelBuffer?
    private var lastRenderedPTS: Double = -1.0
    /// RPU of `lastRenderedBuffer`, so a frame drawn again (paused, after a render mode switch) is tone-mapped as it was.
    private var lastRenderedHDRMetadata: FrameHDRMetadata?
    private var pipelineDroppedFramesCountInternal: Int = 0
    private var speedSkippedFramesCountInternal: Int = 0
    private var lastDropWarningInstant: ContinuousClock.Instant = .now - .seconds(10)

    /// Exact-seek display floor (mpv `hrseek_pts`): decoded frames presenting before it are discarded on push.
    /// After an exact seek the decoder must decode from the preceding keyframe, and reordered B-frames presenting
    /// before the target still emerge after the first post-target frame, so the filter has to act on decoded output
    /// rather than on demuxed packets. Stays in effect until the next seek/load replaces it.
    private var displayFloorPts: CMTime = .invalid

    public init(capacity: Int = defaultCapacity) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        self.buffer = [DecodedFrame?](repeating: nil, count: capacity)
    }

    /// The total number of frames dropped due to hardware/pipeline/decoder falling behind master clock.
    public var pipelineDroppedFramesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pipelineDroppedFramesCountInternal
    }

    /// The total number of frames intentionally skipped because effective frame rate exceeded display refresh rate (speed > 1.0x).
    public var speedSkippedFramesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return speedSkippedFramesCountInternal
    }

    /// The total cumulative dropped and skipped frames count (pipeline drops + rate skips).
    public var droppedFramesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pipelineDroppedFramesCountInternal + speedSkippedFramesCountInternal
    }

    /// The number of decoded frames currently held in the buffer.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countInternal
    }

    /// Presentation timestamp of the next frame `popFrame` would consider, or `nil` when the queue is empty.
    public var headFramePTS: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        guard countInternal > 0 else { return nil }
        return buffer[head]?.pts
    }

    /// Sets (or with `.invalid` clears) the exact-seek display floor; see `displayFloorPts`.
    public func setDisplayFloor(_ floor: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        displayFloorPts = floor
    }

    /// Pushes a decoded frame into the queue, maintaining strict ascending PTS order.
    /// If the buffer is full, the furthest future frame at the tail is discarded to preserve imminent playback frames.
    public func push(_ frame: DecodedFrame) {
        lock.lock()
        defer { lock.unlock() }

        if displayFloorPts.isValid && frame.pts.isValid && frame.pts < displayFloorPts {
            return
        }

        if countInternal == 0 {
            buffer[head] = frame
            countInternal = 1
            return
        }

        // Fast path (95%+ of video playback): Monotonically increasing PTS appends directly to tail in O(1)
        let lastPhysicalIdx = (head + countInternal - 1) % capacity
        if let lastFrame = buffer[lastPhysicalIdx], frame.pts >= lastFrame.pts {
            if countInternal < capacity {
                let nextTail = (head + countInternal) % capacity
                buffer[nextTail] = frame
                countInternal += 1
            } else {
                // Buffer is full: discard furthest future frame at tail, keep imminent head frames
                buffer[lastPhysicalIdx] = frame
            }
            return
        }

        // B-frame out-of-order path: Find insertion point relative to logical queue [0 ..< countInternal]
        // Binary search in O(log N)
        var low = 0
        var high = countInternal
        while low < high {
            let mid = low + (high - low) / 2
            let physicalMid = (head + mid) % capacity
            if let midFrame = buffer[physicalMid], midFrame.pts <= frame.pts {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let insertIndex = low  // logical index in [0 ... countInternal]

        if countInternal < capacity {
            // Shift elements right starting from insertIndex up to countInternal - 1
            var i = countInternal
            while i > insertIndex {
                let fromIdx = (head + i - 1) % capacity
                let toIdx = (head + i) % capacity
                buffer[toIdx] = buffer[fromIdx]
                i -= 1
            }
            let targetIdx = (head + insertIndex) % capacity
            buffer[targetIdx] = frame
            countInternal += 1
        } else {
            // Buffer is full and insertIndex is within existing frames:
            // Drop furthest future frame at tail and shift elements right from insertIndex to capacity - 2
            if insertIndex < capacity {
                var i = capacity - 1
                while i > insertIndex {
                    let fromIdx = (head + i - 1) % capacity
                    let toIdx = (head + i) % capacity
                    buffer[toIdx] = buffer[fromIdx]
                    i -= 1
                }
                let targetIdx = (head + insertIndex) % capacity
                buffer[targetIdx] = frame
            }
        }
    }

    public struct PoppedFrame: @unchecked Sendable {
        public let pixelBuffer: CVPixelBuffer
        public let pts: CMTime
        public let hdrMetadata: FrameHDRMetadata?

        public init(pixelBuffer: CVPixelBuffer, pts: CMTime, hdrMetadata: FrameHDRMetadata? = nil) {
            self.pixelBuffer = pixelBuffer
            self.pts = pts
            self.hdrMetadata = hdrMetadata
        }
    }

    /// Pops the next frame eligible for display at `syncTime`.
    ///
    /// Pacing and dropping invariants:
    /// - `maxLeadTime`: A narrow lead window in movie PTS (clamped to `[0.002, 0.035]` seconds, defaulting to half of `safeFrameDuration`)
    ///   allowing the imminent frame to be picked for the current VSYNC tick without grabbing future frames meant for subsequent ticks.
    ///   Must NOT be scaled down by `playbackRate` because `syncTime` and PTS both advance in movie PTS.
    /// - `lateTolerance`: Frames whose PTS has fallen behind `syncTime - lateTolerance` (missed their presentation deadline due to
    ///   decoding stall or system lag) are discarded and counted as pipeline dropped frames.
    ///   Scaled with `max(1.0, playbackRate)` because in movie PTS, real-world lag covers a wider range of media time when playing faster.
    /// - `speedSkippedFrames`: When playing faster than 1.0x (e.g. 1.7x), effective video FPS ($50 \times 1.7 = 85\text{ fps}$) may exceed
    ///   display refresh rate (60Hz). When lookahead replacement discards intermediate frames to keep up with the master clock at rate > 1.01,
    ///   they are counted as `speedSkippedFrames` instead of `pipelineDroppedFrames`.
    /// Dynamic lead window in movie PTS: half the frame interval so future frames wait for the next VSYNC tick.
    /// Clamped between 2ms (supporting HFR up to 240fps) and 35ms (~28fps half-frame max).
    static func leadWindowSeconds(nominalFrameDuration: Double) -> Double {
        max(0.002, min(nominalFrameDuration * 0.5, 0.035))
    }

    public func popFrame(
        forSyncTime syncTime: CMTime,
        nominalFrameDuration: Double = 1.0 / 24.0,
        playbackRate: Double = 1.0
    ) -> PoppedFrame? {
        struct DropWarningPayload {
            let droppedCount: Int
            let syncTimeSeconds: Double
            let chosenPtsSeconds: Double
            let remaining: Int
        }

        let (popped, warningPayload) = lock.withLock { () -> (PoppedFrame?, DropWarningPayload?) in
            guard countInternal > 0 else { return (nil, nil) }

            // Sanitize input nominalFrameDuration to prevent NaN/Infinity or <= 0 leading to invalid CMTime
            let safeFrameDuration =
                (nominalFrameDuration.isFinite && nominalFrameDuration > 0)
                ? nominalFrameDuration
                : (1.0 / 24.0)

            let safePlaybackRate = (playbackRate.isFinite && playbackRate > 0) ? playbackRate : 1.0

            let maxLeadTime = CMTime(
                seconds: Self.leadWindowSeconds(nominalFrameDuration: safeFrameDuration), preferredTimescale: 1_000_000)

            // Late drop tolerance: base host-time tolerance scaled to movie PTS by max(1.0, playbackRate)
            let baseToleranceSeconds = max(0.040, min(safeFrameDuration * 1.5, 0.100))
            let lateToleranceSeconds = baseToleranceSeconds * max(1.0, safePlaybackRate)
            let lateThreshold = syncTime - CMTime(seconds: lateToleranceSeconds, preferredTimescale: 1_000_000)

            var chosen: CVPixelBuffer?
            var chosenPts: CMTime = .invalid
            var chosenHDRMetadata: FrameHDRMetadata? = nil
            var droppedInThisTick = 0

            while countInternal > 0 {
                guard let frame = buffer[head] else {
                    head = (head + 1) % capacity
                    countInternal -= 1
                    continue
                }

                // If the frame has not yet reached its display window (it is in the future), hold it!
                if frame.pts > syncTime + maxLeadTime {
                    break
                }

                // If the frame is displayable
                if !frame.doNotDisplay {
                    // Check if this frame is already obsolete / late compared to another frame or the clock
                    if frame.pts < lateThreshold && countInternal > 1 {
                        // Truly late frame: decoder/pipeline fell behind master clock
                        pipelineDroppedFramesCountInternal += 1
                        droppedInThisTick += 1
                        buffer[head] = nil
                        head = (head + 1) % capacity
                        countInternal -= 1
                        continue
                    }

                    if chosen == nil {
                        // First valid candidate within [lateThreshold ... syncTime + maxLeadTime]
                        chosen = frame.pixelBuffer
                        chosenPts = frame.pts
                        chosenHDRMetadata = frame.hdrMetadata
                        buffer[head] = nil
                        head = (head + 1) % capacity
                        countInternal -= 1

                        // Look ahead at the next frame in the queue:
                        // Only replace chosen if nextHead is closer to syncTime than chosen
                        // (and still within the maxLeadTime window).
                        // If chosen is closer or on-time, leave the next frame in the queue for the next tick!
                        if let nextHead = buffer[head], !nextHead.doNotDisplay {
                            let currentDelta = abs(chosenPts.seconds - syncTime.seconds)
                            let nextDelta = abs(nextHead.pts.seconds - syncTime.seconds)
                            if currentDelta > nextDelta && nextHead.pts <= syncTime + maxLeadTime {
                                // Next frame is strictly closer to syncTime: continue loop to replace chosen
                                continue
                            } else {
                                // Next frame belongs to the next tick: preserve it!
                                break
                            }
                        } else {
                            break
                        }
                    } else {
                        // We previously picked a frame, but next frame was even closer to syncTime.
                        // Classify: intentional rate skip (playbackRate > 1.01) vs micro-jitter pipeline drop (1.0x).
                        if safePlaybackRate > 1.01 {
                            speedSkippedFramesCountInternal += 1
                        } else {
                            pipelineDroppedFramesCountInternal += 1
                            droppedInThisTick += 1
                        }
                        chosen = frame.pixelBuffer
                        chosenPts = frame.pts
                        chosenHDRMetadata = frame.hdrMetadata
                        buffer[head] = nil
                        head = (head + 1) % capacity
                        countInternal -= 1
                        break
                    }
                } else {
                    // Frame marked as doNotDisplay
                    buffer[head] = nil
                    head = (head + 1) % capacity
                    countInternal -= 1
                }
            }

            if let chosen {
                lastRenderedBuffer = chosen
                lastRenderedHDRMetadata = chosenHDRMetadata
                if chosenPts.isValid {
                    lastRenderedPTS = chosenPts.seconds
                }
            }

            var payload: DropWarningPayload? = nil
            if droppedInThisTick > Self.droppedFramesWarningThreshold {
                let now = ContinuousClock.now
                if (now - lastDropWarningInstant) >= .seconds(1) {
                    lastDropWarningInstant = now
                    payload = DropWarningPayload(
                        droppedCount: droppedInThisTick,
                        syncTimeSeconds: syncTime.seconds,
                        chosenPtsSeconds: chosenPts.isValid ? chosenPts.seconds : -1.0,
                        remaining: countInternal
                    )
                }
            }

            let result = chosen.map {
                PoppedFrame(pixelBuffer: $0, pts: chosenPts, hdrMetadata: chosenHDRMetadata)
            }
            return (result, payload)
        }

        if let payload = warningPayload {
            AppLog.debug(
                .video,
                "FrameQueue popFrame dropped \(payload.droppedCount) frames in a single tick! syncTime: \(String(format: "%.3f", payload.syncTimeSeconds))s, chosenPts: \(payload.chosenPtsSeconds >= 0 ? String(format: "%.3f", payload.chosenPtsSeconds) : "invalid")s, remaining: \(payload.remaining)"
            )
        }

        return popped
    }

    /// Retrieves the latest displayable frame matching `syncTime + leadTime`, without popping from the queue.
    public func getLatestFrame(forSyncTime syncTime: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard countInternal > 0 else { return lastRenderedBuffer }

        let leadThreshold = syncTime + CMTime(value: 100, timescale: 1000)
        var latestMatching: CVPixelBuffer?
        var matchingPts: CMTime = .invalid
        var matchingHDRMetadata: FrameHDRMetadata?

        // Scan backward from newest frame
        for i in stride(from: countInternal - 1, through: 0, by: -1) {
            let physicalIdx = (head + i) % capacity
            if let frame = buffer[physicalIdx], !frame.doNotDisplay, frame.pts <= leadThreshold {
                latestMatching = frame.pixelBuffer
                matchingPts = frame.pts
                matchingHDRMetadata = frame.hdrMetadata
                break
            }
        }

        if let latestMatching {
            lastRenderedBuffer = latestMatching
            lastRenderedHDRMetadata = matchingHDRMetadata
            if matchingPts.isValid {
                lastRenderedPTS = matchingPts.seconds
            }
            return latestMatching
        }

        // Fallback: first displayable frame
        for i in 0..<countInternal {
            let physicalIdx = (head + i) % capacity
            if let frame = buffer[physicalIdx], !frame.doNotDisplay {
                lastRenderedBuffer = frame.pixelBuffer
                lastRenderedHDRMetadata = frame.hdrMetadata
                if frame.pts.isValid {
                    lastRenderedPTS = frame.pts.seconds
                }
                return frame.pixelBuffer
            }
        }

        return lastRenderedBuffer
    }

    /// Explicitly updates the last rendered frame and its presentation timestamp.
    public func setLastRendered(buffer: CVPixelBuffer, pts: Double, hdrMetadata: FrameHDRMetadata? = nil) {
        lock.lock()
        defer { lock.unlock() }
        lastRenderedBuffer = buffer
        lastRenderedPTS = pts
        lastRenderedHDRMetadata = hdrMetadata
    }

    /// Returns the presentation timestamp (in seconds) of the most recently rendered frame.
    public func getLastRenderedPTS() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return lastRenderedPTS
    }

    /// Returns the most recently rendered `CVPixelBuffer` for freeze-frame display parity during pause.
    public func getLastRenderedBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return lastRenderedBuffer
    }

    /// The most recently rendered frame, its presentation time (seconds) and its RPU, read together.
    public func getLastRenderedFrame()
        -> (pixelBuffer: CVPixelBuffer, pts: Double, hdrMetadata: FrameHDRMetadata?)?
    {
        lock.lock()
        defer { lock.unlock() }
        return lastRenderedBuffer.map { ($0, lastRenderedPTS, lastRenderedHDRMetadata) }
    }

    /// Resets the cumulative dropped and skipped frames counters (e.g. on new media load or manual seek).
    public func resetDroppedFramesCount() {
        lock.lock()
        defer { lock.unlock() }
        pipelineDroppedFramesCountInternal = 0
        speedSkippedFramesCountInternal = 0
    }

    /// Clears all frames and releases all `IOSurface` backing buffers immediately.
    public func clear(resetDroppedFrames: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<capacity {
            buffer[i] = nil
        }
        head = 0
        countInternal = 0
        lastRenderedBuffer = nil
        lastRenderedPTS = -1.0
        lastRenderedHDRMetadata = nil
        if resetDroppedFrames {
            pipelineDroppedFramesCountInternal = 0
            speedSkippedFramesCountInternal = 0
        }
    }
}
