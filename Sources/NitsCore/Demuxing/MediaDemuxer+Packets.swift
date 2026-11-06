import CFFmpeg
import CoreMedia
import Foundation

extension MediaDemuxer {
    /// A demuxed audio packet, queued while video is read and handed to the audio decoder.
    public struct DemuxedAudioPacket: QueuedPacket {
        public let data: Data
        public let pts: Int64
        public let dts: Int64
        public let duration: Int64
        public let isKeyFrame: Bool

        /// Copies an audio packet's payload and timing out of FFmpeg's buffer.
        init(_ pkt: AVPacket) {
            self.data = Data(bytes: pkt.data, count: Int(pkt.size))
            self.pts = pkt.pts
            self.dts = pkt.dts
            self.duration = pkt.duration
            self.isKeyFrame = (pkt.flags & AV_PKT_FLAG_KEY) != 0
        }
    }

    /// What a video packet is read as, which a variant switch changes (`MediaDemuxer.videoFormat`).
    struct VideoPacketFormat: Sendable {
        let description: CMVideoFormatDescription?
        /// Start codes rather than length prefixes.
        let isAnnexB: Bool
        let timebase: AVRational
    }

    /// A demuxed video packet, queued while the audio pump reads ahead so no video is lost.
    struct DemuxedVideoPacket: QueuedPacket {
        let data: Data
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let flags: Int32
        /// The format the packet was read with: a variant switch can change it while the packet waits.
        let format: VideoPacketFormat

        var isKeyFrame: Bool {
            (flags & AV_PKT_FLAG_KEY) != 0
        }

        /// Copies a video packet's payload, timing and flags out of FFmpeg's buffer.
        init(_ pkt: AVPacket, format: VideoPacketFormat) {
            self.data = Data(bytes: pkt.data, count: Int(pkt.size))
            self.pts = pkt.pts
            self.dts = pkt.dts
            self.duration = pkt.duration
            self.flags = pkt.flags
            self.format = format
        }

        /// A packet held back (`HeldVideoPacket`) with the format it plays with.
        init(_ held: HeldVideoPacket, format: VideoPacketFormat) {
            self.init(held.packet.pointee, format: format)
        }
    }

    /// A video packet of a variant switched to, held back until the format it plays with is known
    /// (`VariantSwitch.heldVideo`). FFmpeg's packet itself, kept by reference: it goes through what every picture does
    /// when it is released (the captions in its SEI), in the order the decoder takes them.
    final class HeldVideoPacket: @unchecked Sendable {
        let packet: UnsafeMutablePointer<AVPacket>

        /// Nil when the packet can't be kept.
        init?(_ pkt: inout AVPacket) {
            guard let clone = av_packet_clone(&pkt) else { return nil }
            packet = clone
        }

        deinit {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
        }
    }

    /// A queued packet's payload size and timing, which `DemuxerPacketBuffer` totals and indexes.
    package protocol QueuedPacket: Sendable {
        var data: Data { get }
        var pts: Int64 { get }
        var dts: Int64 { get }
        var duration: Int64 { get }
        var isKeyFrame: Bool { get }
    }

    /// Bidirectional packet buffer for the demuxer supporting retained history, GOP-aligned pruning,
    /// and fast-path seek within the buffered range.
    package struct DemuxerPacketBuffer<T: QueuedPacket>: Sendable {
        private var elements: [T?] = []
        package private(set) var headIndex: Int = 0
        package private(set) var readIndex: Int = 0

        /// Indices of keyframes in `elements`, sorted ascending.
        package private(set) var keyframeIndices: [Int] = []

        /// Payload bytes of unconsumed forward packets (`readIndex ..< elements.count`).
        package private(set) var forwardBytes: Int = 0

        /// Payload bytes of consumed history packets (`headIndex ..< readIndex`).
        package private(set) var backBytes: Int = 0

        /// Highest presentation end timestamp seen among all appended packets.
        package private(set) var maxPacketEndPTS: Int64 = Int64.min

        /// Configured limit for retained history bytes. When 0 (default for local files),
        /// history is immediately pruned as packets are consumed.
        package var maxBackBytes: Int = 0

        /// Payload bytes queued ahead of playback (alias for forwardBytes, matching existing byteCount API).
        package var byteCount: Int {
            forwardBytes
        }

        /// Whether there are unconsumed packets ahead of the cursor.
        package var isEmpty: Bool {
            readIndex >= elements.count
        }

        /// Number of unconsumed packets ahead of the cursor.
        package var count: Int {
            max(0, elements.count - readIndex)
        }

        /// Total count of packets currently held in memory (history + future).
        package var totalCount: Int {
            max(0, elements.count - headIndex)
        }

        /// Effective PTS of the earliest packet currently retained in memory, if any.
        package var earliestPTS: Int64? {
            guard headIndex < elements.count, let p = elements[headIndex] else { return nil }
            return p.effectivePTS
        }

        /// Whether keyframes are indexed for `findKeyframeIndex` and GOP pruning: not for audio, whose packets all are.
        private let indexesKeyframes: Bool

        package init(maxBackBytes: Int = 0, indexesKeyframes: Bool = true) {
            self.indexesKeyframes = indexesKeyframes
            self.maxBackBytes = maxBackBytes
        }

        package mutating func append(_ element: T) {
            let newIndex = elements.count
            elements.append(element)
            forwardBytes += element.data.count
            let end = element.packetEnd
            if end > maxPacketEndPTS {
                maxPacketEndPTS = end
            }
            if indexesKeyframes, element.isKeyFrame {
                keyframeIndices.append(newIndex)
            }
        }

        package mutating func popFirst() -> T? {
            while readIndex < elements.count {
                guard let element = elements[readIndex] else {
                    readIndex += 1
                    continue
                }
                readIndex += 1
                let size = element.data.count
                forwardBytes -= size
                backBytes += size

                if maxBackBytes == 0 {
                    // History disabled (local files / on-demand): drop immediately
                    elements[readIndex - 1] = nil
                    headIndex = readIndex
                    backBytes = 0
                    compactIfNeeded()
                }
                return element
            }
            return nil
        }

        package func peek() -> T? {
            var i = readIndex
            while i < elements.count {
                if let el = elements[i] {
                    return el
                }
                i += 1
            }
            return nil
        }

        package func peekAt(_ index: Int) -> T? {
            guard index >= headIndex && index < elements.count else { return nil }
            return elements[index]
        }

        package mutating func seekTo(elementIndex: Int) {
            precondition(elementIndex >= headIndex && elementIndex <= elements.count)
            guard elementIndex != readIndex else { return }
            if elementIndex < readIndex {
                // Seeking backward: packets move from history to forward
                var delta = 0
                for i in elementIndex..<readIndex {
                    if let el = elements[i] {
                        delta += el.data.count
                    }
                }
                backBytes = max(0, backBytes - delta)
                forwardBytes += delta
            } else {
                // Seeking forward: packets move from forward to history
                var delta = 0
                for i in readIndex..<elementIndex {
                    if let el = elements[i] {
                        delta += el.data.count
                    }
                }
                forwardBytes = max(0, forwardBytes - delta)
                backBytes += delta
            }
            readIndex = elementIndex
        }

        /// Finds the element index of the keyframe covering `targetPTS`.
        /// - Parameter forward: If false (exact or backward), finds the latest keyframe with PTS <= targetPTS.
        ///                      If true (non-exact forward), finds the earliest keyframe with PTS >= targetPTS.
        /// - Parameter startTolerancePTS: A target before the first retained packet, at or after 0, still finds it when it
        ///   starts within this much of 0: the first picture of a file with B-frames or an edit list is presented a
        ///   little after 0, and a seek to the start asks for it.
        package func findKeyframeIndex(targetPTS: Int64, forward: Bool = false, startTolerancePTS: Int64 = 0) -> Int? {
            guard !elements.isEmpty, headIndex < elements.count else { return nil }
            guard let headPkt = elements[headIndex] else { return nil }
            let earliestPTS = headPkt.effectivePTS

            // Target cannot be beyond the downloaded frontier
            guard targetPTS <= maxPacketEndPTS else { return nil }

            if targetPTS < earliestPTS {
                guard targetPTS >= 0, earliestPTS <= startTolerancePTS, headPkt.isKeyFrame else { return nil }
                return headIndex
            }

            // Keyframes ascend in presentation time, so the ones at or after the head (older entries of
            // `keyframeIndices` are pruned history) are binary searched.
            let first = keyframePosition(atOrAfter: headIndex)
            func pts(at position: Int) -> Int64 {
                elements[keyframeIndices[position]]?.effectivePTS ?? Int64.max
            }
            if forward {
                // First keyframe with PTS >= target.
                var low = first
                var high = keyframeIndices.count
                while low < high {
                    let mid = (low + high) / 2
                    if pts(at: mid) >= targetPTS { high = mid } else { low = mid + 1 }
                }
                return low < keyframeIndices.count ? keyframeIndices[low] : nil
            } else {
                // Last keyframe with PTS <= target.
                var low = first
                var high = keyframeIndices.count
                while low < high {
                    let mid = (low + high) / 2
                    if pts(at: mid) <= targetPTS { low = mid + 1 } else { high = mid }
                }
                return low > first ? keyframeIndices[low - 1] : nil
            }
        }

        /// Finds the element index of the first audio packet whose end PTS is >= targetPTS.
        package func findAudioPacketIndex(targetPTS: Int64, primingTolerancePTS: Int64 = 0) -> Int? {
            guard !elements.isEmpty, headIndex < elements.count else { return nil }
            guard let headPkt = elements[headIndex] else { return nil }
            let earliestPTS = headPkt.effectivePTS

            // Target cannot be beyond what has been downloaded
            guard targetPTS <= maxPacketEndPTS else { return nil }

            if targetPTS < earliestPTS {
                // Allow priming delay at stream start (targetPTS >= 0 and the earliest packet is within the priming tolerance)
                if targetPTS >= 0, earliestPTS <= primingTolerancePTS {
                    return headIndex
                }
                return nil
            }

            for i in headIndex..<elements.count {
                guard let p = elements[i] else { continue }
                if p.packetEnd >= targetPTS {
                    return i
                }
            }
            return nil
        }

        /// Prunes history packets before `readIndex` in whole GOPs down to `limitBytes`.
        /// When keyframes are present, `elements[headIndex]` remains a keyframe after pruning.
        /// If keyframes are absent (e.g. intra-refresh or missing keyframe flags),
        /// history is pruned linearly once it exceeds `hardCap` (2x limit) to prevent memory exhaustion.
        package mutating func pruneGOPs(maxBackBytes: Int? = nil) {
            let limitBytes = maxBackBytes ?? self.maxBackBytes
            guard limitBytes > 0 else {
                pruneAllHistory()
                return
            }

            while backBytes > limitBytes {
                // Find next keyframe index strictly after headIndex and at or before readIndex
                guard let nextKF = nextKeyframeIndex(after: headIndex), nextKF <= readIndex else {
                    break
                }
                var prunedBytes = 0
                for i in headIndex..<nextKF {
                    if let el = elements[i] {
                        prunedBytes += el.data.count
                        elements[i] = nil
                    }
                }
                backBytes = max(0, backBytes - prunedBytes)
                headIndex = nextKF
            }

            // Safety fallback: if no keyframes are present (intra-refresh or missing flags)
            // and history exceeds safety margin, linearly prune to prevent memory leaks.
            let hardCap = limitBytes * 2
            if backBytes > hardCap {
                pruneLinear(maxBackBytes: limitBytes)
            }

            compactIfNeeded()
        }

        /// Prunes history packets before `readIndex` for streams without GOPs (e.g. audio),
        /// dropping packets whose timestamp is before `beforePTS` or to satisfy `maxBackBytes`.
        package mutating func pruneLinear(beforePTS: Int64? = nil, maxBackBytes: Int? = nil) {
            let limitBytes = maxBackBytes ?? self.maxBackBytes
            while headIndex < readIndex {
                guard let packet = elements[headIndex] else {
                    headIndex += 1
                    continue
                }
                let ptsExceeded = beforePTS != nil && packet.effectivePTS < beforePTS!
                let bytesExceeded = limitBytes > 0 && backBytes > limitBytes
                guard ptsExceeded || bytesExceeded else { break }

                backBytes = max(0, backBytes - packet.data.count)
                elements[headIndex] = nil
                headIndex += 1
            }
            compactIfNeeded()
        }

        package mutating func pruneAllHistory() {
            while headIndex < readIndex {
                if let el = elements[headIndex] {
                    backBytes = max(0, backBytes - el.data.count)
                    elements[headIndex] = nil
                }
                headIndex += 1
            }
            compactIfNeeded()
        }

        /// Position in `keyframeIndices` of the first keyframe at or after element `index`.
        private func keyframePosition(atOrAfter index: Int) -> Int {
            var low = 0
            var high = keyframeIndices.count
            while low < high {
                let mid = (low + high) / 2
                if keyframeIndices[mid] >= index { high = mid } else { low = mid + 1 }
            }
            return low
        }

        private func nextKeyframeIndex(after index: Int) -> Int? {
            let position = keyframePosition(atOrAfter: index + 1)
            return position < keyframeIndices.count ? keyframeIndices[position] : nil
        }

        private mutating func compactIfNeeded() {
            if headIndex > 64 && headIndex * 2 >= elements.count {
                elements.removeFirst(headIndex)
                readIndex -= headIndex
                let offset = headIndex
                headIndex = 0
                keyframeIndices = keyframeIndices.compactMap { idx in
                    let newIdx = idx - offset
                    return newIdx >= 0 ? newIdx : nil
                }
            }
        }

        package mutating func removeAll(keepingCapacity: Bool = false) {
            elements.removeAll(keepingCapacity: keepingCapacity)
            headIndex = 0
            readIndex = 0
            keyframeIndices.removeAll(keepingCapacity: keepingCapacity)
            forwardBytes = 0
            backBytes = 0
            maxPacketEndPTS = Int64.min
        }

        package mutating func removeAll(where shouldBeRemoved: (T) -> Bool) {
            var active: [T?] = []
            active.reserveCapacity(elements.count)
            var newKeyframes: [Int] = []
            var newReadIndex = 0
            var newForwardBytes = 0
            var newBackBytes = 0
            var newMaxPacketEndPTS = Int64.min

            for i in headIndex..<elements.count {
                guard let el = elements[i] else { continue }
                if shouldBeRemoved(el) { continue }
                let newIdx = active.count
                active.append(el)
                let end = el.packetEnd
                if end > newMaxPacketEndPTS {
                    newMaxPacketEndPTS = end
                }
                if indexesKeyframes, el.isKeyFrame {
                    newKeyframes.append(newIdx)
                }
                if i < readIndex {
                    newBackBytes += el.data.count
                    newReadIndex = newIdx + 1
                } else {
                    newForwardBytes += el.data.count
                }
            }
            elements = active
            headIndex = 0
            readIndex = newReadIndex
            keyframeIndices = newKeyframes
            forwardBytes = newForwardBytes
            backBytes = newBackBytes
            maxPacketEndPTS = newMaxPacketEndPTS
        }
    }
}

extension MediaDemuxer.QueuedPacket {
    package var effectivePTS: Int64 {
        pts != Int64.min ? pts : dts
    }

    package var packetEnd: Int64 {
        let start = effectivePTS
        guard start != Int64.min else { return Int64.min }
        return MediaDemuxer.packetEnd(pts: start, duration: duration)
    }
}
