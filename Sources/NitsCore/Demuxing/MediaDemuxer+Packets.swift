import CFFmpeg
import Foundation

extension MediaDemuxer {
    /// A demuxed audio packet, queued while video is read and handed to the audio decoder.
    public struct DemuxedAudioPacket: Sendable {
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

    /// A demuxed video packet, queued while the audio pump reads ahead so no video is lost.
    struct DemuxedVideoPacket: Sendable {
        let data: Data
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let flags: Int32

        /// Copies a video packet's payload, timing and flags out of FFmpeg's buffer.
        init(_ pkt: AVPacket) {
            self.data = Data(bytes: pkt.data, count: Int(pkt.size))
            self.pts = pkt.pts
            self.dts = pkt.dts
            self.duration = pkt.duration
            self.flags = pkt.flags
        }
    }

    /// Fast FIFO queue avoiding O(N) array shifts on pop.
    struct PacketFifoQueue<T: Sendable>: Sendable {
        private var elements: [T?] = []
        private var headIndex: Int = 0

        var isEmpty: Bool {
            headIndex >= elements.count
        }

        var count: Int {
            max(0, elements.count - headIndex)
        }

        mutating func append(_ element: T) {
            elements.append(element)
        }

        mutating func popFirst() -> T? {
            guard headIndex < elements.count else { return nil }
            let element = elements[headIndex]
            elements[headIndex] = nil
            headIndex += 1
            // Periodically compact buffer to prevent unbounded growth while preserving O(1) amortized pop
            if headIndex > 64 && headIndex * 2 >= elements.count {
                elements.removeFirst(headIndex)
                headIndex = 0
            }
            return element
        }

        mutating func removeAll(keepingCapacity: Bool = false) {
            elements.removeAll(keepingCapacity: keepingCapacity)
            headIndex = 0
        }

        mutating func removeAll(where shouldBeRemoved: (T) -> Bool) {
            var active: [T] = []
            active.reserveCapacity(count)
            for i in headIndex..<elements.count {
                if let el = elements[i], !shouldBeRemoved(el) {
                    active.append(el)
                }
            }
            elements = active.map { Optional($0) }
            headIndex = 0
        }
    }
}
