import Foundation
import Testing

@testable import NitsCore

/// The tail of a packet queue taken back (`DemuxerPacketBuffer.truncate`): the packets of a variant given up for a lower
/// one, which the new variant's keyframe replaces.
@Suite("DemuxerPacketBuffer tail cut")
struct DemuxerPacketBufferTruncateTests {
    typealias TestPacket = DemuxerPacketBufferTests.TestPacket
    typealias Buffer = MediaDemuxer.DemuxerPacketBuffer<TestPacket>

    /// A packet of a variant (`generation`), as `variantGeneration` tells them apart.
    struct GenerationPacket: MediaDemuxer.QueuedPacket {
        let data = Data(repeating: 1, count: 10)
        let pts: Int64
        let dts: Int64
        let duration: Int64 = 40
        let isKeyFrame: Bool
        let generation: Int

        init(pts: Int64, isKeyFrame: Bool, generation: Int) {
            self.pts = pts
            self.dts = pts
            self.isKeyFrame = isKeyFrame
            self.generation = generation
        }
    }

    /// `gops` groups of `length` pictures 40 apart from `start`, the first of each a keyframe, 100 bytes each.
    private func buffer(gops: Int, length: Int = 3, start: Int64 = 0, maxBackBytes: Int = 0) -> Buffer {
        var buffer = Buffer(maxBackBytes: maxBackBytes)
        for gop in 0..<gops {
            for picture in 0..<length {
                let pts = start + Int64(gop * length + picture) * 40
                buffer.append(TestPacket(pts: pts, isKeyFrame: picture == 0, size: 100))
            }
        }
        return buffer
    }

    @Test("The tail goes with its bytes and keyframes; what is before the cut and the cursor stay")
    func dropsTheTail() throws {
        var buffer = buffer(gops: 3)  // 9 packets, keyframes at 0, 3, 6
        _ = buffer.popFirst()
        #expect(buffer.forwardBytes == 800 && buffer.keyframeIndices == [0, 3, 6])
        let cut6 = buffer.truncate(from: 6)
        #expect(cut6)
        #expect(buffer.count == 5 && buffer.forwardBytes == 500)
        #expect(buffer.keyframeIndices == [0, 3])
        var seen: [Int64] = []
        while let packet = buffer.popFirst() { seen.append(packet.pts) }
        #expect(seen == [40, 80, 120, 160, 200])
        // The cut is not a break: a packet appended after it carries on the timeline.
        buffer.append(TestPacket(pts: 240, isKeyFrame: true, size: 100))
        #expect(buffer.breakCount == 0 && buffer.keyframeIndices == [0, 3, 6])
    }

    @Test("A cut behind the cursor is refused, one at the end cuts nothing")
    func refusesWhatWasHandedOut() {
        var buffer = buffer(gops: 2)
        _ = buffer.popFirst()
        _ = buffer.popFirst()
        let cut1 = buffer.truncate(from: 1)
        #expect(!cut1)
        #expect(buffer.count == 4)
        let cut6 = buffer.truncate(from: 6)
        #expect(cut6)
        #expect(buffer.count == 4)
        let cut2 = buffer.truncate(from: 2)
        #expect(cut2)
        #expect(buffer.isEmpty && buffer.forwardBytes == 0)
    }

    @Test("A break in the cut tail is taken back, one before it stays")
    func takesBackBreaks() {
        var buffer = buffer(gops: 2)  // keyframes at index 0 and 3
        // The timeline goes back at index 6 (a keyframe earlier than the one before it), and again at 9.
        buffer.append(TestPacket(pts: 100, isKeyFrame: true, size: 100))
        buffer.append(TestPacket(pts: 140, isKeyFrame: false, size: 100))
        buffer.append(TestPacket(pts: 180, isKeyFrame: false, size: 100))
        buffer.append(TestPacket(pts: 50, isKeyFrame: true, size: 100))
        #expect(buffer.breakCount == 2 && buffer.breakIndices == [6, 9] && buffer.searchFloor == 9)
        buffer.truncate(from: 9)
        #expect(buffer.breakCount == 1 && buffer.breakIndices == [6] && buffer.searchFloor == 6)
        buffer.truncate(from: 6)
        #expect(buffer.breakCount == 0 && buffer.breakIndices.isEmpty && buffer.searchFloor == 0)
        #expect(!buffer.isBeforeBreak)
    }

    @Test("The timeline after the cut is the packets left: a later keyframe carries on, an earlier one is a break")
    func timelineAfterTheCut() {
        var carried = buffer(gops: 3)
        carried.truncate(from: 6)
        carried.append(TestPacket(pts: 240, isKeyFrame: true, size: 100))
        #expect(carried.breakCount == 0)

        var broken = buffer(gops: 3)
        broken.truncate(from: 6)
        // Before the last keyframe left (pts 120): the timeline went back.
        broken.append(TestPacket(pts: 40, isKeyFrame: true, size: 100))
        #expect(broken.breakCount == 1 && broken.searchFloor == 6)
    }

    @Test("The furthest end is that of the packets left since the start of the timeline")
    func furthestEnd() {
        var buffer = buffer(gops: 3)
        #expect(buffer.maxPacketEndPTS == 8 * 40 + 40)
        buffer.truncate(from: 6)
        #expect(buffer.maxPacketEndPTS == 5 * 40 + 40)
    }

    /// Decode order I0 P3 B1 B2 P6 B4 B5 I9, pictures 40 apart (B-frames come after the picture they are presented
    /// before).
    private func bFrames() -> Buffer {
        var buffer = Buffer(maxBackBytes: 0)
        for (picture, isKey) in [
            (0, true), (3, false), (1, false), (2, false), (6, false), (4, false), (5, false), (9, true),
        ] {
            buffer.append(TestPacket(pts: Int64(picture) * 40, isKeyFrame: isKey, size: 100))
        }
        return buffer
    }

    @Test("A new keyframe's time cuts from the first picture in decode order presented at or after it")
    func cutsInDecodeOrderAtATime() {
        // The new keyframe at 4.5 pictures: walking back from the end while presented at or after it (ExoPlayer) would stop
        // at B4 and keep P6 among the new variant's pictures. From P6 on in decode order nothing kept is presented after it.
        var buffer = bFrames()
        let index = buffer.firstIndex(atOrAfterPTS: 180)
        #expect(index == 4)
        let isCut = buffer.truncate(from: 4)
        #expect(isCut)
        var kept: [Int64] = []
        while let packet = buffer.popFirst() { kept.append(packet.pts) }
        #expect(kept == [0, 120, 40, 80], "B4 is lost: a picture repeated, not a hole")
        #expect(kept.allSatisfy { $0 < 180 })
    }

    @Test("The latest picture handed out is the largest time since the keyframe, not the last packet's")
    func largestHandedOut() {
        var buffer = bFrames()
        #expect(buffer.largestHandedOutPTS == Int64.min)
        _ = buffer.popFirst()  // I0
        _ = buffer.popFirst()  // P3
        _ = buffer.popFirst()  // B1
        #expect(buffer.lastHandedOutPTS == 40)
        #expect(buffer.largestHandedOutPTS == 120, "P3 is decoded: a cut at 100 would put a picture behind it")
        for _ in 0..<4 { _ = buffer.popFirst() }  // B2 P6 B4 B5
        #expect(buffer.largestHandedOutPTS == 240)
        _ = buffer.popFirst()  // I9
        #expect(buffer.largestHandedOutPTS == 360, "A keyframe starts it again")
    }

    @Test("The first keyframe at or after a time is found from the cursor on, with the time known to within a little")
    func findsTheKeyframeAtOrAfter() {
        var buffer = buffer(gops: 3)  // keyframes at 0, 120, 240 (index 0, 3, 6)
        #expect(buffer.keyframeIndex(atOrAfterPTS: 110) == 3)
        #expect(buffer.keyframeIndex(atOrAfterPTS: 120) == 3)
        #expect(buffer.keyframeIndex(atOrAfterPTS: 121) == 6)
        #expect(buffer.keyframeIndex(atOrAfterPTS: 241) == nil)
        for _ in 0..<4 { _ = buffer.popFirst() }
        #expect(buffer.keyframeIndex(atOrAfterPTS: 110) == 6, "The keyframe at 120 is handed out")
    }

    @Test("The last packet held is the newest, history or not")
    func lastElementIsTheNewest() {
        var buffer = buffer(gops: 2, maxBackBytes: 1000)
        #expect(buffer.lastElement?.pts == 200)
        buffer.truncate(from: 3)
        #expect(buffer.lastElement?.pts == 80)
        for _ in 0..<3 { _ = buffer.popFirst() }
        #expect(buffer.lastElement?.pts == 80, "History is kept")
        var none = Buffer(maxBackBytes: 0)
        #expect(none.lastElement == nil)
        none.append(TestPacket(pts: 0, isKeyFrame: true))
        _ = none.popFirst()
        #expect(none.lastElement == nil, "Without history what is handed out is gone")
    }

    @Test("Sound is cut by presentation time, from the first packet at or after it")
    func cutsSoundByTime() {
        var audio = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 0, indexesKeyframes: false)
        for index in 0..<10 { audio.append(TestPacket(pts: Int64(index) * 21, isKeyFrame: true, size: 10)) }
        _ = audio.popFirst()
        #expect(audio.firstIndex(atOrAfterPTS: 100) == 5)  // 105
        audio.truncate(fromPTS: 100)
        #expect(audio.count == 4 && audio.forwardBytes == 40)
        #expect(audio.maxPacketEndPTS == 4 * 21 + 40)
        // Nothing at or after it: nothing to cut.
        audio.truncate(fromPTS: 10_000)
        #expect(audio.count == 4)
    }

    @Test("A buffer cut and then pruned keeps a keyframe at its head")
    func pruningKeepsAKeyframeHead() {
        var buffer = buffer(gops: 4, maxBackBytes: 250)  // history kept: a GOP is 300 bytes
        for _ in 0..<7 { _ = buffer.popFirst() }
        buffer.truncate(from: 9)
        buffer.pruneGOPs()
        let head = buffer.peekAt(buffer.headIndex)
        #expect(head?.isKeyFrame == true, "Head at \(buffer.headIndex): \(String(describing: head?.pts))")
        #expect(buffer.count == 2 && buffer.byteCount == 200)
        #expect(buffer.backBytes <= 250 * 2)
    }

    @Test("A cut of the sound behind what is handed out is refused, with history or without")
    func refusesSoundPastTheCut() {
        for maxBackBytes in [0, 1000] {
            var audio = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(
                maxBackBytes: maxBackBytes, indexesKeyframes: false)
            for index in 0..<10 { audio.append(TestPacket(pts: Int64(index) * 21, isKeyFrame: true, size: 10)) }
            for _ in 0..<7 { _ = audio.popFirst() }  // handed out up to 126
            #expect(audio.lastHandedOutPTS == 126)
            // At 100 the sound has gone past: the first not handed out (147) is also after 100, and would be cut.
            let refused = audio.truncate(fromPTS: 100)
            #expect(!refused, "History \(maxBackBytes)")
            #expect(audio.count == 3 && audio.forwardBytes == 30)
            // Past what is handed out it cuts.
            let cut = audio.truncate(fromPTS: 150)
            #expect(cut)
            #expect(audio.count == 1)
        }
    }

    @Test("A seek moves the record of what is handed out with the cursor")
    func handOutFollowsTheCursor() {
        var audio = MediaDemuxer.DemuxerPacketBuffer<TestPacket>(maxBackBytes: 1000, indexesKeyframes: false)
        for index in 0..<10 { audio.append(TestPacket(pts: Int64(index) * 21, isKeyFrame: true, size: 10)) }
        for _ in 0..<8 { _ = audio.popFirst() }
        #expect(audio.lastHandedOutPTS == 147)
        audio.seekTo(elementIndex: 3)
        #expect(audio.lastHandedOutPTS == 42)
        let cut = audio.truncate(fromPTS: 100)
        #expect(cut)
        #expect(audio.count == 2)
        audio.removeAll()
        #expect(audio.lastHandedOutPTS == Int64.min)
    }

    @Test("Cutting the whole queue with no history leaves the timeline to carry on from the cut")
    func wholeQueueCutKeepsTheTimeline() {
        var buffer = Buffer(maxBackBytes: 0)
        for index in 0..<6 { buffer.append(TestPacket(pts: Int64(index) * 40, isKeyFrame: index % 3 == 0)) }
        _ = buffer.popFirst()  // history off: the packet is gone, the queue is all ahead of the cursor
        let cut = buffer.truncate(from: buffer.readIndex)
        #expect(cut && buffer.isEmpty)
        // A keyframe of the time the cut tail's first keyframe (120) had carries on; an earlier one is a break.
        var carried = buffer
        carried.append(TestPacket(pts: 120, isKeyFrame: true))
        #expect(carried.breakCount == 0)
        var broken = buffer
        broken.append(TestPacket(pts: 80, isKeyFrame: true))
        #expect(broken.breakCount == 1)
    }

    @Test("Filtering packets out keeps every break, on the packet kept at or after it")
    func removeAllWhereKeepsBreaks() {
        var buffer = buffer(gops: 2)  // keyframes at 0 and 3
        // Two breaks ahead of the cursor: at element 6 and at 9.
        for pts: Int64 in [100, 140, 180] { buffer.append(TestPacket(pts: pts, isKeyFrame: pts == 100)) }
        for pts: Int64 in [50, 90, 130] { buffer.append(TestPacket(pts: pts, isKeyFrame: pts == 50)) }
        #expect(buffer.breakCount == 2 && buffer.breakIndices == [6, 9])
        // The packet of the first break is removed, with the one after it: the break passes to the next kept.
        buffer.removeAll(where: { $0.pts == 100 || $0.pts == 140 })
        #expect(buffer.breakCount == 2 && buffer.breakIndices == [6, 7], "\(buffer.breakIndices)")
        #expect(buffer.peekAt(6)?.pts == 180 && buffer.peekAt(7)?.pts == 50)
        // The count is what the stream was through: removing packets never changes it.
        // Both break packets removed, with a kept one after: two breaks stay, at that packet (the same index twice), so a
        // cut of it takes back both, as `breakCount` should follow.
        var merged = buffer
        merged.removeAll(where: { $0.pts == 180 || $0.pts == 50 })
        #expect(merged.breakCount == 2 && merged.breakIndices == [6, 6], "\(merged.breakIndices)")
        merged.truncate(from: 6)
        #expect(merged.breakCount == 0 && merged.breakIndices.isEmpty && merged.searchFloor == 0)
        // Nothing kept after a break: it is at the end of what is left, and a cut that takes the end's last packet takes it.
        var gone = buffer
        gone.removeAll(where: { $0.pts == 50 || $0.pts == 90 || $0.pts == 130 })
        #expect(gone.breakCount == 2 && gone.breakIndices == [6, 7], "\(gone.breakIndices)")
        #expect(gone.peekAt(6)?.pts == 180 && gone.count == 7)
        // The one at the end can be cut still: the buffer knows where it is.
        buffer.truncate(from: 7)
        #expect(buffer.breakCount == 1 && buffer.searchFloor == 6)
    }

    @Test("Breaks keep their places when the consumed head is compacted away")
    func breaksSurviveCompaction() {
        // History disabled: every packet taken is dropped, and the buffer compacts as the head grows.
        var buffer = Buffer(maxBackBytes: 0)
        for index in 0..<150 { buffer.append(TestPacket(pts: Int64(index) * 40, isKeyFrame: index % 10 == 0)) }
        buffer.append(TestPacket(pts: 10, isKeyFrame: true))  // a break at element 150
        for index in 1..<40 { buffer.append(TestPacket(pts: 10 + Int64(index) * 40, isKeyFrame: false)) }
        #expect(buffer.breakCount == 1 && buffer.breakIndices == [150])
        for _ in 0..<130 { _ = buffer.popFirst() }
        // Compacted: element 150 is at a smaller index now, and is the one the buffer says the break is at.
        let at = buffer.breakIndices[0]
        #expect(at < 150 && buffer.searchFloor == at)
        #expect(buffer.peekAt(at)?.pts == 10)
        buffer.truncate(from: at + 5)
        #expect(buffer.breakCount == 1 && buffer.searchFloor == at)
        buffer.truncate(from: at)
        #expect(buffer.breakCount == 0 && buffer.searchFloor == 0)
    }

    @Test("A cut exactly at the seam of two variants leaves the first one's packets alone for a seek")
    func cutAtTheSeamOfTwoGenerations() {
        var buffer = MediaDemuxer.DemuxerPacketBuffer<GenerationPacket>(maxBackBytes: 1000)
        for index in 0..<9 {
            buffer.append(GenerationPacket(pts: Int64(index) * 40, isKeyFrame: index % 3 == 0, generation: 1))
        }
        // The old variant's packets from the keyframe at 6 on are cut and the new variant's take their place.
        buffer.truncate(from: 6)
        for index in 6..<12 {
            buffer.append(GenerationPacket(pts: Int64(index) * 40, isKeyFrame: index % 3 == 0, generation: 2))
        }
        #expect(buffer.breakCount == 0)
        #expect(buffer.keyframeIndices == [0, 3, 6, 9])
        // A seek to a keyframe of the old variant, the cursor in it: they share a generation.
        #expect(buffer.keyframesShare(from: 3, withCursorBy: { $0.generation }))
        // A seek across the seam: the keyframe of the new variant against a cursor in the old.
        #expect(!buffer.keyframesShare(from: 6, withCursorBy: { $0.generation }))
    }
}
