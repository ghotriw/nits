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
        /// The size of the unit lengths in the packets (`MediaDemuxer.unitLengthSize`): 4 for Annex B ones.
        let unitLengthSize: Int
        let timebase: AVRational
        /// `MediaDemuxer.variantGeneration` when the packet was read: packets of one generation come from one stretch
        /// of one variant (the parameter sets within it may change, the description with them).
        let variantGeneration: Int
        /// The pixel aspect of the stream read: a variant switch changes it, and a description may not tell it (made of
        /// H.264 parameter sets, or square).
        let sampleAspectRatio: RationalAspectRatio
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

        /// Highest presentation end timestamp seen among the packets of the timeline now (since the last break).
        package private(set) var maxPacketEndPTS: Int64 = Int64.min

        /// The first element of the timeline now: a break in the presentation timestamps (a packet's, or a keyframe's
        /// for video, going back before the one before it: a discontinuity, a splice) starts a new timeline at its packet,
        /// and the elements before it are not searched, as their timestamps are not on this one. They stay queued: a break
        /// may be in what is not yet taken, which has to play. Consumed ones before it are dropped (`dropHistoryBeforeBreak`).
        package private(set) var searchFloor: Int = 0

        /// How many breaks the buffer has seen since it was emptied. A seek spans both streams: with the video and the
        /// audio at different counts, one is on a timeline the other has not reached yet (or the other way), and they
        /// do not match.
        package private(set) var breakCount = 0

        /// Where each break started (the elements the timeline broke at), in order; `searchFloor` is the last. A cut of the
        /// tail (`truncate`) takes back the breaks in it. Those before the head are dropped with it, as the elements are.
        package private(set) var breakIndices: [Int] = []

        /// The cursor is before the start of the timeline now: the position is on the older one, and a target compared
        /// against the newer would land on other content.
        package var isBeforeBreak: Bool {
            readIndex < searchFloor
        }

        /// Presentation timestamp of the latest packet (a keyframe's for video) appended: a smaller one is a break.
        private var lastTimelinePTS: Int64 = Int64.min

        /// Presentation timestamp of the last packet handed out (`popFirst`), or where the cursor was put (`seekTo`): a cut
        /// of a stream in presentation order (sound) at or before it would take back what is handed out, which the elements
        /// themselves no longer tell when history is off.
        package private(set) var lastHandedOutPTS: Int64 = Int64.min

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

        /// The first element a search looks at: the head, or the start of the timeline now if that is later.
        private var searchStart: Int {
            max(headIndex, searchFloor)
        }

        /// Effective PTS of the earliest packet retained of the timeline now, if any.
        package var earliestPTS: Int64? {
            guard searchStart < elements.count, let p = elements[searchStart] else { return nil }
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
            // The timeline breaks where the timestamps go back: at a keyframe for video (the pictures between keyframes
            // are reordered), at any packet for audio (with a packet's duration of leeway).
            let pts = element.effectivePTS
            let isTimelinePacket = !indexesKeyframes || element.isKeyFrame
            if isTimelinePacket, pts != Int64.min {
                let leeway = indexesKeyframes ? 0 : max(element.duration, 0)
                if lastTimelinePTS != Int64.min, pts.addingReportingOverflow(leeway).partialValue < lastTimelinePTS {
                    searchFloor = newIndex
                    breakIndices.append(newIndex)
                    breakCount += 1
                    maxPacketEndPTS = Int64.min
                }
                lastTimelinePTS = pts
            }
            let end = element.packetEnd
            if end > maxPacketEndPTS {
                maxPacketEndPTS = end
            }
            if indexesKeyframes, element.isKeyFrame {
                keyframeIndices.append(newIndex)
            }
        }

        /// Whether `key` is the same for the packet at `index` (a keyframe) and for the position of the cursor: the
        /// keyframes between them, and the one the cursor's packet follows, are compared; what is not held (pruned)
        /// fails.
        package func keyframesShare<K: Equatable>(from index: Int, withCursorBy key: (T) -> K) -> Bool {
            guard let reference = peekAt(index) else { return false }
            let wanted = key(reference)
            let low = min(index, readIndex)
            let high = max(index, readIndex)
            if let before = keyframeIndices.last(where: { $0 <= low }) {
                guard let element = peekAt(before), key(element) == wanted else { return false }
            }
            for keyframe in keyframeIndices where keyframe > low && keyframe <= high {
                guard let element = peekAt(keyframe), key(element) == wanted else { return false }
            }
            return true
        }

        /// Drops the consumed elements before the start of the timeline now: nothing searches them. When the break is
        /// still ahead of the cursor they stay, as does what the cursor has yet to reach.
        private mutating func dropHistoryBeforeBreak() {
            guard searchFloor > headIndex, searchFloor <= readIndex else { return }
            for i in headIndex..<searchFloor {
                if let el = elements[i] {
                    backBytes = max(0, backBytes - el.data.count)
                    elements[i] = nil
                }
            }
            headIndex = searchFloor
        }

        package mutating func popFirst() -> T? {
            while readIndex < elements.count {
                guard let element = elements[readIndex] else {
                    readIndex += 1
                    continue
                }
                readIndex += 1
                if element.effectivePTS != Int64.min { lastHandedOutPTS = element.effectivePTS }
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
            // The packet before the cursor, when it is held: with no history nothing says (a cut then refuses nothing it
            // should not, and takes only what is ahead of the cursor).
            var before = elementIndex - 1
            lastHandedOutPTS = Int64.min
            while before >= headIndex, lastHandedOutPTS == Int64.min {
                lastHandedOutPTS = elements[before]?.effectivePTS ?? Int64.min
                before -= 1
            }
        }

        /// Finds the element index of the keyframe covering `targetPTS`.
        /// - Parameter forward: If false (exact or backward), finds the latest keyframe with PTS <= targetPTS.
        ///                      If true (non-exact forward), finds the earliest keyframe with PTS >= targetPTS.
        /// - Parameter startTolerancePTS: A target before the first retained packet, at or after 0, still finds it when it
        ///   starts within this much of 0: the first picture of a file with B-frames or an edit list is presented a
        ///   little after 0, and a seek to the start asks for it.
        package func findKeyframeIndex(targetPTS: Int64, forward: Bool = false, startTolerancePTS: Int64 = 0) -> Int? {
            guard !elements.isEmpty, searchStart < elements.count else { return nil }
            guard let headPkt = elements[searchStart] else { return nil }
            let earliestPTS = headPkt.effectivePTS

            // Target cannot be beyond the downloaded frontier
            guard targetPTS <= maxPacketEndPTS else { return nil }

            if targetPTS < earliestPTS {
                guard targetPTS >= 0, earliestPTS <= startTolerancePTS, headPkt.isKeyFrame else { return nil }
                return searchStart
            }

            // Keyframes ascend in presentation time, so the ones at or after the head (older entries of
            // `keyframeIndices` are pruned history) are binary searched.
            let first = keyframePosition(atOrAfter: searchStart)
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
            guard !elements.isEmpty, searchStart < elements.count else { return nil }
            guard let headPkt = elements[searchStart] else { return nil }
            let earliestPTS = headPkt.effectivePTS

            // Target cannot be beyond what has been downloaded
            guard targetPTS <= maxPacketEndPTS else { return nil }

            if targetPTS < earliestPTS {
                // Allow priming delay at stream start (targetPTS >= 0 and the earliest packet is within the priming tolerance)
                if targetPTS >= 0, earliestPTS <= primingTolerancePTS {
                    return searchStart
                }
                return nil
            }

            for i in searchStart..<elements.count {
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
            dropHistoryBeforeBreak()
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
            dropHistoryBeforeBreak()
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
                searchFloor = max(0, searchFloor - offset)
                breakIndices = breakIndices.compactMap { $0 >= offset ? $0 - offset : nil }
                headIndex = 0
                keyframeIndices = keyframeIndices.compactMap { idx in
                    let newIdx = idx - offset
                    return newIdx >= 0 ? newIdx : nil
                }
            }
        }

        /// The index of the first keyframe at or after the cursor whose presentation timestamp is `pts`: the cut of a tail
        /// that a new variant's keyframe of the same time replaces (keyframes share their presentation times across
        /// variants, not their decode times).
        package func keyframeIndex(withPTS pts: Int64) -> Int? {
            guard indexesKeyframes else { return nil }
            var position = keyframePosition(atOrAfter: readIndex)
            while position < keyframeIndices.count {
                let index = keyframeIndices[position]
                if let packet = elements[index], packet.effectivePTS == pts { return index }
                position += 1
            }
            return nil
        }

        /// The index of the first packet at or after the cursor that is presented at or after `pts`, for a stream whose
        /// packets come in presentation order (audio): where the sound of a variant given up is cut.
        package func firstIndex(atOrAfterPTS pts: Int64) -> Int? {
            var index = readIndex
            while index < elements.count {
                if let packet = elements[index], packet.effectivePTS >= pts { return index }
                index += 1
            }
            return nil
        }

        /// Takes the packets from element `index` on out of the buffer, with what the buffer tells of them: their bytes, their
        /// keyframes and the breaks of the timeline that start in them. The cursor must not be past `index`: a packet already
        /// handed out is not taken back (false, nothing changed). An index at the end cuts nothing.
        ///
        /// What is kept of the timeline is what the packets before `index` make of it: the last timeline packet's time
        /// (the next append compares with it to tell a break) and the furthest end since the timeline's start.
        @discardableResult
        package mutating func truncate(from index: Int) -> Bool {
            guard index >= readIndex, index >= headIndex else { return false }
            guard index < elements.count else { return true }
            for position in index..<elements.count {
                if let packet = elements[position] { forwardBytes = max(0, forwardBytes - packet.data.count) }
            }
            // The first timeline packet of the tail, for a timeline the cut leaves with none of its own.
            var firstCutPTS = Int64.min
            for position in index..<elements.count {
                if let packet = elements[position], !indexesKeyframes || packet.isKeyFrame,
                    packet.effectivePTS != Int64.min
                {
                    firstCutPTS = packet.effectivePTS
                    break
                }
            }
            elements.removeSubrange(index...)
            while let last = keyframeIndices.last, last >= index { keyframeIndices.removeLast() }
            while let last = breakIndices.last, last >= index {
                breakIndices.removeLast()
                breakCount = max(0, breakCount - 1)
            }
            if searchFloor >= index { searchFloor = breakIndices.last ?? 0 }
            // The timeline as the packets left make it.
            lastTimelinePTS = Int64.min
            var position = elements.count
            while position > headIndex {
                position -= 1
                guard let packet = elements[position], !indexesKeyframes || packet.isKeyFrame,
                    packet.effectivePTS != Int64.min
                else { continue }
                lastTimelinePTS = packet.effectivePTS
                break
            }
            // Nothing of the timeline is left (no history: the whole queue was ahead of the cursor): the next packet carries
            // on from a tick before the first one cut, so a keyframe of that time is no break and an earlier one is.
            if lastTimelinePTS == Int64.min, firstCutPTS != Int64.min { lastTimelinePTS = firstCutPTS - 1 }
            maxPacketEndPTS = Int64.min
            for position in max(searchFloor, headIndex)..<elements.count {
                if let packet = elements[position] { maxPacketEndPTS = max(maxPacketEndPTS, packet.packetEnd) }
            }
            return true
        }

        /// `truncate(from:)` at the first packet presented at or after `pts` (`firstIndex(atOrAfterPTS:)`).
        @discardableResult
        package mutating func truncate(fromPTS pts: Int64) -> Bool {
            // A packet at or after `pts` already handed out is not taken back: the sound is past the cut, and the cut will
            // not do (the caller waits for another). Said by the cursor's own record, which holds with no history too.
            guard lastHandedOutPTS < pts else { return false }
            guard let index = firstIndex(atOrAfterPTS: pts) else { return true }
            return truncate(from: index)
        }

        package mutating func removeAll(keepingCapacity: Bool = false) {
            elements.removeAll(keepingCapacity: keepingCapacity)
            headIndex = 0
            readIndex = 0
            lastHandedOutPTS = Int64.min
            keyframeIndices.removeAll(keepingCapacity: keepingCapacity)
            forwardBytes = 0
            backBytes = 0
            maxPacketEndPTS = Int64.min
            searchFloor = 0
            lastTimelinePTS = Int64.min
            breakCount = 0
            breakIndices.removeAll(keepingCapacity: keepingCapacity)
        }

        package mutating func removeAll(where shouldBeRemoved: (T) -> Bool) {
            var active: [T?] = []
            active.reserveCapacity(elements.count)
            var newKeyframes: [Int] = []
            var newReadIndex = 0
            var newForwardBytes = 0
            var newBackBytes = 0
            var newMaxPacketEndPTS = Int64.min
            var newFloor: Int?
            // The breaks go to the packet that is kept at or after where each was: one whose packet is removed passes to the
            // next kept, two that meet there stay two (the same index twice), and one with nothing kept after it is at the
            // end. `breakCount` is what the stream has been through, and removing packets does not undo it: the cache
            // compares it between video and sound.
            var newBreaks: [Int] = []
            var breaks = breakIndices.filter { $0 >= headIndex }[...]

            for i in headIndex..<elements.count {
                guard let el = elements[i] else { continue }
                if shouldBeRemoved(el) { continue }
                let newIdx = active.count
                while let first = breaks.first, first <= i {
                    breaks.removeFirst()
                    newBreaks.append(newIdx)
                }
                active.append(el)
                let end = el.packetEnd
                if i >= searchFloor, newFloor == nil { newFloor = newIdx }
                if i >= searchFloor, end > newMaxPacketEndPTS {
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
            // Removing packets does not undo their hand-out: the record changes only when a packet before the cursor is kept.
            if newReadIndex > 0, let before = active[newReadIndex - 1] { lastHandedOutPTS = before.effectivePTS }
            keyframeIndices = newKeyframes
            forwardBytes = newForwardBytes
            backBytes = newBackBytes
            maxPacketEndPTS = newMaxPacketEndPTS
            searchFloor = newFloor ?? active.count
            breakIndices = newBreaks + Array(repeating: active.count, count: breaks.count)
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
