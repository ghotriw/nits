import CoreMedia
import CoreVideo
import Foundation
import os

/// A small, lazily-populated cache of decoded display frames around the current position, enabling cheap
/// paused frame-stepping in both directions without re-seeking to the keyframe and re-decoding the GOP.
///
/// Holds at most `capacity` frames in ascending PTS. When full, the frame furthest from the most recent
/// insertion is evicted so the retained window tracks where the user is stepping. It is populated only when
/// paused stepping is plausible (frames decoded around the target of a paused seek, plus frames produced by
/// an active forward-step pump) and cleared whenever playback resumes, media changes, or stepping goes idle,
/// so no pixel-buffer memory is retained during normal playback.
public final class StepFrameCache: @unchecked Sendable {
    public struct Entry: @unchecked Sendable {
        public let pixelBuffer: CVPixelBuffer
        public let pts: CMTime
        public let hdrMetadata: FrameHDRMetadata?
    }

    private let lock = OSAllocatedUnfairLock()
    private let capacity: Int
    private var entries: [Entry] = []  // ascending PTS, de-duplicated

    public init(capacity: Int = 32) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Number of cached frames with PTS strictly greater than `pts` (how many forward steps are buffered).
    public func countAfter(_ pts: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var n = 0
        for entry in entries where entry.pts.seconds > pts + 1e-4 { n += 1 }
        return n
    }

    /// Inserts a decoded display frame, preserving ascending PTS order and evicting the furthest frame
    /// from the insertion point when over capacity (keeps a window around recent stepping activity).
    public func append(pixelBuffer: CVPixelBuffer, pts: CMTime, hdrMetadata: FrameHDRMetadata? = nil) {
        guard pts.isValid else { return }
        let seconds = pts.seconds
        lock.lock()
        defer { lock.unlock() }
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].pts.seconds < seconds { lo = mid + 1 } else { hi = mid }
        }
        // Ignore exact-duplicate PTS (e.g. a frame re-decoded by an overlapping pump), checking both the
        // element at the insertion point and its left neighbor to absorb float rounding on either side.
        if lo < entries.count && abs(entries[lo].pts.seconds - seconds) < 1e-6 { return }
        if lo > 0 && abs(entries[lo - 1].pts.seconds - seconds) < 1e-6 { return }
        entries.insert(Entry(pixelBuffer: pixelBuffer, pts: pts, hdrMetadata: hdrMetadata), at: lo)
        if entries.count > capacity {
            // Drop whichever end is further from the just-inserted frame so the window follows stepping.
            if lo <= entries.count / 2 {
                entries.removeLast()
            } else {
                entries.removeFirst()
            }
        }
    }

    /// The cached frame with the smallest PTS strictly greater than `pts`, or `nil` if none is buffered.
    public func frameAfter(_ pts: Double) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries where entry.pts.seconds > pts + 1e-4 { return entry }
        return nil
    }

    /// The cached frame with the largest PTS strictly less than `pts`, or `nil` if none is buffered.
    public func frameBefore(_ pts: Double) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        var result: Entry? = nil
        for entry in entries {
            if entry.pts.seconds < pts - 1e-4 {
                result = entry
            } else {
                break
            }
        }
        return result
    }

    /// Releases all cached frames and their backing pixel buffers.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }
}
