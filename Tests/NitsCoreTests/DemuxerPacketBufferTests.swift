import Foundation
import Testing

@testable import NitsCore

@Suite("DemuxerPacketBuffer Invariant Tests")
struct DemuxerPacketBufferTests {
    struct TestPacket: MediaDemuxer.QueuedPacket, Equatable {
        let data: Data
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let isKeyFrame: Bool

        init(pts: Int64, isKeyFrame: Bool = false, size: Int = 100, duration: Int64 = 40) {
            self.data = Data(repeating: 0xAA, count: size)
            self.pts = pts
            self.dts = pts
            self.duration = duration
            self.isKeyFrame = isKeyFrame
        }
    }

    @Test("FIFO on-demand mode with maxBackBytes == 0 immediately evicts read packets")
    func testImmediateEvictionWhenHistoryDisabled() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 0)

        buffer.append(TestPacket(pts: 0, isKeyFrame: true, size: 50))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false, size: 50))
        buffer.append(TestPacket(pts: 80, isKeyFrame: false, size: 50))

        #expect(buffer.count == 3)
        #expect(buffer.byteCount == 150)
        #expect(buffer.backBytes == 0)

        let first = buffer.popFirst()
        #expect(first?.pts == 0)
        #expect(buffer.count == 2)
        #expect(buffer.byteCount == 100)
        #expect(buffer.backBytes == 0)
        #expect(buffer.headIndex == buffer.readIndex)
    }

    @Test("History mode retains consumed packets and updates forwardBytes and backBytes")
    func testHistoryRetentionAndCounters() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 1000)

        buffer.append(TestPacket(pts: 0, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false, size: 100))
        buffer.append(TestPacket(pts: 80, isKeyFrame: false, size: 100))

        #expect(buffer.forwardBytes == 300)
        #expect(buffer.backBytes == 0)
        #expect(!buffer.isEmpty)

        let p1 = buffer.popFirst()
        #expect(p1?.pts == 0)
        #expect(buffer.forwardBytes == 200)
        #expect(buffer.backBytes == 100)
        #expect(buffer.count == 2)
        #expect(buffer.totalCount == 3)

        let p2 = buffer.popFirst()
        #expect(p2?.pts == 40)
        #expect(buffer.forwardBytes == 100)
        #expect(buffer.backBytes == 200)

        let p3 = buffer.popFirst()
        #expect(p3?.pts == 80)
        #expect(buffer.forwardBytes == 0)
        #expect(buffer.backBytes == 300)
        #expect(buffer.isEmpty)
        #expect(buffer.popFirst() == nil)
    }

    @Test("Binary search findKeyframeIndex finds correct keyframe for exact, backward and forward seeks")
    func testKeyframeSearch() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        // GOP 1: 0, 40, 80
        buffer.append(TestPacket(pts: 0, isKeyFrame: true))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false))
        buffer.append(TestPacket(pts: 80, isKeyFrame: false))

        // GOP 2: 120, 160, 200
        buffer.append(TestPacket(pts: 120, isKeyFrame: true))
        buffer.append(TestPacket(pts: 160, isKeyFrame: false))
        buffer.append(TestPacket(pts: 200, isKeyFrame: false))

        // GOP 3: 240, 280, 320
        buffer.append(TestPacket(pts: 240, isKeyFrame: true))
        buffer.append(TestPacket(pts: 280, isKeyFrame: false))
        buffer.append(TestPacket(pts: 320, isKeyFrame: false))

        // Exact / backward seek (forward == false): finds latest keyframe <= target
        // Target 160 -> GOP 2 keyframe at index 3 (pts 120)
        let kf1 = buffer.findKeyframeIndex(targetPTS: 160, forward: false)
        #expect(kf1 == 3)

        // Target 120 exactly -> GOP 2 keyframe at index 3 (pts 120)
        let kf2 = buffer.findKeyframeIndex(targetPTS: 120, forward: false)
        #expect(kf2 == 3)

        // Target 239 -> GOP 2 keyframe at index 3 (pts 120)
        let kf3 = buffer.findKeyframeIndex(targetPTS: 239, forward: false)
        #expect(kf3 == 3)

        // Target 240 -> GOP 3 keyframe at index 6 (pts 240)
        let kf4 = buffer.findKeyframeIndex(targetPTS: 240, forward: false)
        #expect(kf4 == 6)

        // Target beyond downloaded frontier (pts 400 > 320) -> nil
        #expect(buffer.findKeyframeIndex(targetPTS: 400, forward: false) == nil)

        // Non-exact forward seek (forward == true): finds earliest keyframe >= target
        // Target 50 -> next keyframe is GOP 2 at index 3 (pts 120)
        let fwd1 = buffer.findKeyframeIndex(targetPTS: 50, forward: true)
        #expect(fwd1 == 3)

        // Target 120 -> keyframe at index 3 (pts 120)
        let fwd2 = buffer.findKeyframeIndex(targetPTS: 120, forward: true)
        #expect(fwd2 == 3)

        // Target 250 -> nil (no keyframe >= 250 in buffer)
        let fwd3 = buffer.findKeyframeIndex(targetPTS: 250, forward: true)
        #expect(fwd3 == nil)
    }

    @Test("Audio packet search findAudioPacketIndex finds packet covering targetPTS by end duration")
    func testAudioPacketSearch() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        // 3 audio packets with duration 40 each: [0..40], [40..80], [80..120]
        buffer.append(TestPacket(pts: 0, isKeyFrame: false, size: 50, duration: 40))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false, size: 50, duration: 40))
        buffer.append(TestPacket(pts: 80, isKeyFrame: false, size: 50, duration: 40))

        // Target 25: covered by packet 0 [0..40]
        #expect(buffer.findAudioPacketIndex(targetPTS: 25) == 0)

        // Target 40: packet 0 ends at 40, packet 1 starts at 40 -> first covering packet is index 0
        #expect(buffer.findAudioPacketIndex(targetPTS: 40) == 0)

        // Target 41: covered by packet 1 [40..80]
        #expect(buffer.findAudioPacketIndex(targetPTS: 41) == 1)

        // Target 100: covered by packet 2 [80..120]
        #expect(buffer.findAudioPacketIndex(targetPTS: 100) == 2)

        // Target 150: beyond downloaded frontier -> nil
        #expect(buffer.findAudioPacketIndex(targetPTS: 150) == nil)
    }

    @Test("seekTo repositions readIndex and correctly redistributes forwardBytes and backBytes")
    func testSeekToRepositioning() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        for i in 0..<10 {
            buffer.append(TestPacket(pts: Int64(i * 40), isKeyFrame: i % 4 == 0, size: 100))
        }

        // Consume first 5 packets (indices 0..4)
        for _ in 0..<5 {
            _ = buffer.popFirst()
        }

        #expect(buffer.readIndex == 5)
        #expect(buffer.backBytes == 500)
        #expect(buffer.forwardBytes == 500)

        // Seek backward to index 2
        buffer.seekTo(elementIndex: 2)
        #expect(buffer.readIndex == 2)
        #expect(buffer.backBytes == 200)
        #expect(buffer.forwardBytes == 800)
        #expect(buffer.count == 8)

        // Next popped packet should be packet with pts 80 (index 2)
        let popped = buffer.popFirst()
        #expect(popped?.pts == 80)
        #expect(buffer.readIndex == 3)
        #expect(buffer.backBytes == 300)
        #expect(buffer.forwardBytes == 700)

        // Seek forward to index 8
        buffer.seekTo(elementIndex: 8)
        #expect(buffer.readIndex == 8)
        #expect(buffer.backBytes == 800)
        #expect(buffer.forwardBytes == 200)
        #expect(buffer.count == 2)
    }

    @Test("pruneGOPs strictly deletes in whole GOPs ensuring headIndex is always a keyframe")
    func testGOPPruning() {
        // maxBackBytes = 400 (retains at most 1 GOP of 300 bytes, but cannot retain 2 GOPs of 600 bytes)
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 400)

        // GOP 0: indices 0, 1, 2 (100 bytes each = 300 bytes)
        buffer.append(TestPacket(pts: 0, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false, size: 100))
        buffer.append(TestPacket(pts: 80, isKeyFrame: false, size: 100))

        // GOP 1: indices 3, 4, 5 (300 bytes)
        buffer.append(TestPacket(pts: 120, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 160, isKeyFrame: false, size: 100))
        buffer.append(TestPacket(pts: 200, isKeyFrame: false, size: 100))

        // GOP 2: indices 6, 7, 8 (300 bytes)
        buffer.append(TestPacket(pts: 240, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 280, isKeyFrame: false, size: 100))
        buffer.append(TestPacket(pts: 320, isKeyFrame: false, size: 100))

        // Consume GOP 0 and GOP 1 (readIndex moves to 6)
        for _ in 0..<6 {
            _ = buffer.popFirst()
        }

        #expect(buffer.readIndex == 6)
        #expect(buffer.backBytes == 600)  // 6 packets * 100 = 600 > maxBackBytes 400

        // Trigger prune
        buffer.pruneGOPs()

        // GOP 0 (indices 0..2) should be pruned because backBytes was 600 > 400.
        // GOP 1 is retained because 300 <= 400.
        // headIndex must now be at keyframe 3 (GOP 1 start)!
        #expect(buffer.headIndex == 3)
        #expect(buffer.earliestPTS == 120)
        #expect(buffer.backBytes == 300)

        // Now prune with limit 150 (< 300 bytes) -> evicts GOP 1 up to readIndex (index 6)
        buffer.pruneGOPs(maxBackBytes: 150)
        #expect(buffer.headIndex == 6)
        #expect(buffer.earliestPTS == 240)
        #expect(buffer.backBytes == 0)

        // Crucial invariant: headIndex MUST never prune past readIndex!
        buffer.pruneGOPs()
        #expect(buffer.headIndex == 6)
        #expect(buffer.readIndex == 6)
    }

    @Test("pruneLinear prunes audio up to given PTS and respects maxBackBytes")
    func testLinearAudioPruning() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 500)

        for i in 0..<10 {
            buffer.append(TestPacket(pts: Int64(i * 40), isKeyFrame: false, size: 100))
        }

        // Consume first 7 packets
        for _ in 0..<7 {
            _ = buffer.popFirst()
        }

        #expect(buffer.readIndex == 7)
        #expect(buffer.backBytes == 700)

        // Prune before PTS 120 (packets at pts 0, 40, 80 have pts < 120 -> 3 packets)
        buffer.pruneLinear(beforePTS: 120)
        #expect(buffer.headIndex == 3)
        #expect(buffer.earliestPTS == 120)
        #expect(buffer.backBytes == 400)  // 4 packets retained (indices 3, 4, 5, 6)
    }

    @Test("removeAll resets all indices and counters completely")
    func testRemoveAll() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 1000)

        buffer.append(TestPacket(pts: 0, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false, size: 100))
        _ = buffer.popFirst()

        #expect(buffer.backBytes == 100)
        #expect(buffer.forwardBytes == 100)

        buffer.removeAll()

        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
        #expect(buffer.totalCount == 0)
        #expect(buffer.headIndex == 0)
        #expect(buffer.readIndex == 0)
        #expect(buffer.forwardBytes == 0)
        #expect(buffer.backBytes == 0)
        #expect(buffer.keyframeIndices.isEmpty)
    }

    @Test("removeAll(where:) filters packets and recalculates byte counts and keyframe indices")
    func testRemoveAllWhere() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        buffer.append(TestPacket(pts: 10, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 20, isKeyFrame: false, size: 100))
        buffer.append(TestPacket(pts: 30, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false, size: 100))

        // Consume 2 packets (pts 10, 20)
        _ = buffer.popFirst()
        _ = buffer.popFirst()

        #expect(buffer.backBytes == 200)
        #expect(buffer.forwardBytes == 200)

        // Remove all packets with pts < 25
        buffer.removeAll { $0.pts < 25 }

        // Packets remaining: pts 30 (keyframe, was forward), pts 40 (was forward)
        #expect(buffer.totalCount == 2)
        #expect(buffer.backBytes == 0)
        #expect(buffer.forwardBytes == 200)
        #expect(buffer.earliestPTS == 30)
        #expect(buffer.keyframeIndices == [0])
    }

    @Test("B-frame out-of-order decode order does not cause false cache miss")
    func testBFrameOutOfOrderKeyframeSearch() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        // Decode order (DTS):
        // 0: Keyframe, PTS 0, dur 40 [0..40]
        // 1: P-frame,   PTS 120, dur 40 [120..160]
        // 2: B-frame,   PTS 40, dur 40 [40..80]
        // 3: B-frame,   PTS 80, dur 40 [80..120]
        buffer.append(TestPacket(pts: 0, isKeyFrame: true, duration: 40))
        buffer.append(TestPacket(pts: 120, isKeyFrame: false, duration: 40))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false, duration: 40))
        buffer.append(TestPacket(pts: 80, isKeyFrame: false, duration: 40))

        // Target PTS 100:
        // Even though the last packet in decode order has PTS 80 < 100,
        // maxPacketEndPTS is 160 >= 100.
        // The covering keyframe is index 0 (PTS 0).
        let kf = buffer.findKeyframeIndex(targetPTS: 100, forward: false)
        #expect(kf == 0)

        // Target PTS 150: covered by packet 1 duration [120..160]
        let kfCovered = buffer.findKeyframeIndex(targetPTS: 150, forward: false)
        #expect(kfCovered == 0)

        // Target PTS 200: beyond maxPacketEndPTS (160) -> nil
        #expect(buffer.findKeyframeIndex(targetPTS: 200, forward: false) == nil)
    }

    @Test("Audio priming offset at stream start satisfies targetPTS == 0 within tolerance")
    func testAudioPrimingOffsetAtHeadIndexZero() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        // Audio starts with priming delay: first packet has PTS 23ms, duration 23ms
        buffer.append(TestPacket(pts: 23, isKeyFrame: false, duration: 23))
        buffer.append(TestPacket(pts: 46, isKeyFrame: false, duration: 23))

        // Seeking to 0 within 50ms priming tolerance succeeds and returns index 0
        let idx = buffer.findAudioPacketIndex(targetPTS: 0, primingTolerancePTS: 50)
        #expect(idx == 0)

        // Seeking to 0 with 10ms tolerance (less than 23ms) returns nil
        let strictIdx = buffer.findAudioPacketIndex(targetPTS: 0, primingTolerancePTS: 10)
        #expect(strictIdx == nil)
    }

    @Test("Seeking before buffer start returns nil even after removeAll or compacting (headIndex == 0)")
    func testSeekingBeforeBufferStartReturnsNilEvenWhenHeadIndexIsZero() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        // Stream sought to 1000: buffer starts at 1000 with headIndex == 0
        buffer.append(TestPacket(pts: 1000, isKeyFrame: true, duration: 40))
        buffer.append(TestPacket(pts: 1040, isKeyFrame: false, duration: 40))
        buffer.append(TestPacket(pts: 1080, isKeyFrame: true, duration: 40))

        #expect(buffer.headIndex == 0)

        // Target 50 is far before the buffer: MUST return nil, not 0!
        #expect(buffer.findKeyframeIndex(targetPTS: 50, forward: false) == nil)
        #expect(buffer.findKeyframeIndex(targetPTS: 50, forward: true) == nil)
        #expect(buffer.findAudioPacketIndex(targetPTS: 50) == nil)
        #expect(buffer.findAudioPacketIndex(targetPTS: 0, primingTolerancePTS: 100) == nil)

        // Targets within buffer succeed
        #expect(buffer.findKeyframeIndex(targetPTS: 1050, forward: false) == 0)
        #expect(buffer.findKeyframeIndex(targetPTS: 1050, forward: true) == 2)
        #expect(buffer.findAudioPacketIndex(targetPTS: 1020) == 0)
    }

    @Test("Intra-refresh streams without keyframes respect hardCap in pruneGOPs to prevent OOM")
    func testIntraRefreshHardCapPruning() {
        let limit = 1000
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: limit)

        // Append 100 non-keyframe packets, 100 bytes each (10,000 bytes total)
        for i in 0..<100 {
            buffer.append(TestPacket(pts: Int64(i * 40), isKeyFrame: false, size: 100))
        }

        // Consume 90 packets
        for _ in 0..<90 {
            _ = buffer.popFirst()
        }

        #expect(buffer.backBytes == 9000)
        // Normal pruneGOPs would do nothing without keyframes.
        // With hardCap, if backBytes > hardCap (2 * limit = 2000), it prunes linearly to limit!
        buffer.pruneGOPs()
        #expect(buffer.backBytes <= limit)
    }

    @Test("peekAt returns packet within bounds and nil out of bounds")
    func testPeekAt() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)

        buffer.append(TestPacket(pts: 0, isKeyFrame: true))
        buffer.append(TestPacket(pts: 40, isKeyFrame: false))

        #expect(buffer.peekAt(0)?.pts == 0)
        #expect(buffer.peekAt(1)?.pts == 40)
        #expect(buffer.peekAt(2) == nil)
        #expect(buffer.peekAt(-1) == nil)
    }

    @Test("A seek to the start finds a first keyframe presented a little after 0, only within the tolerance")
    func testStartTolerance() {
        // A first picture at 80 ms (B-frames): 0 is before the first packet.
        var buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)
        buffer.append(TestPacket(pts: 80, isKeyFrame: true))
        buffer.append(TestPacket(pts: 120))
        buffer.append(TestPacket(pts: 160))

        #expect(buffer.findKeyframeIndex(targetPTS: 0) == nil, "No tolerance, no match")
        for forward in [false, true] {
            #expect(buffer.findKeyframeIndex(targetPTS: 0, forward: forward, startTolerancePTS: 250) == 0)
            #expect(buffer.findKeyframeIndex(targetPTS: 40, forward: forward, startTolerancePTS: 250) == 0)
            #expect(buffer.findKeyframeIndex(targetPTS: -10, forward: forward, startTolerancePTS: 250) == nil)
            #expect(buffer.findKeyframeIndex(targetPTS: 0, forward: forward, startTolerancePTS: 50) == nil)
        }

        // A head 5 s into the media (the start was pruned or never read) is not the start.
        var later = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)
        later.append(TestPacket(pts: 5000, isKeyFrame: true))
        later.append(TestPacket(pts: 5040))
        #expect(later.findKeyframeIndex(targetPTS: 0, startTolerancePTS: 250) == nil)

        // A head that is not a keyframe cannot be landed on.
        var inner = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 10000)
        inner.append(TestPacket(pts: 80, isKeyFrame: false))
        inner.append(TestPacket(pts: 120, isKeyFrame: true))
        #expect(inner.findKeyframeIndex(targetPTS: 0, startTolerancePTS: 250) == nil)
    }
}
