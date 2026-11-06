import Foundation
import Observation
import Testing

@testable import NitsCore

@Suite("Parameter sets compared")
struct VideoParameterSetsTests {
    private static func sets(sps: [UInt8], pps: [UInt8], vps: [UInt8]? = nil)
        -> VideoFormatDescriptionBuilder.ParameterSets
    {
        .init(vps: vps.map { Data($0) }, sps: Data(sps), pps: Data(pps))
    }

    @Test("Zero bytes after a NAL unit are no change")
    func trailingZeros() {
        let first = Self.sets(sps: [0x67, 0x42, 0xC0, 0x1E, 0x22, 0x46, 0x72], pps: [0x68, 0xCB, 0x82, 0xCB, 0x20])
        let padded = Self.sets(
            sps: [0x67, 0x42, 0xC0, 0x1E, 0x22, 0x46, 0x72, 0x00, 0x00], pps: [0x68, 0xCB, 0x82, 0xCB, 0x20, 0x00])
        #expect(!MediaDemuxer.parameterSetsDiffer(first, padded))
        #expect(!MediaDemuxer.parameterSetsDiffer(padded, first))
        #expect(!MediaDemuxer.parameterSetsDiffer(first, first))
    }

    @Test("Other bytes in a set are a change, a zero inside is not trimmed")
    func realDifferences() {
        let first = Self.sets(sps: [0x67, 0x42, 0x00, 0x1E, 0x22], pps: [0x68, 0xCB])
        #expect(
            MediaDemuxer.parameterSetsDiffer(first, Self.sets(sps: [0x67, 0x42, 0x00, 0x1E, 0x23], pps: [0x68, 0xCB])))
        #expect(
            MediaDemuxer.parameterSetsDiffer(first, Self.sets(sps: [0x67, 0x42, 0x00, 0x1E, 0x22], pps: [0x68, 0xCC])))
        // The zero in the middle of the SPS is part of it.
        #expect(MediaDemuxer.parameterSetsDiffer(first, Self.sets(sps: [0x67, 0x42, 0x1E, 0x22], pps: [0x68, 0xCB])))
        // A set that appears or goes (HEVC's VPS).
        let withVPS = Self.sets(sps: [0x42, 0x01], pps: [0x44, 0x01], vps: [0x40, 0x01])
        let withoutVPS = Self.sets(sps: [0x42, 0x01], pps: [0x44, 0x01])
        #expect(MediaDemuxer.parameterSetsDiffer(withVPS, withoutVPS))
    }

    @Test("The size of the picture is written only when it changes, so a seek that lands in the same size wakes nobody")
    @MainActor
    func sizeWrittenOnlyOnAChange() async {
        let engine = PlayerEngine.makeForTesting()
        var video = engine.media.video
        video.width = 640
        video.height = 360
        engine.media.video = video

        final class Woken: @unchecked Sendable { var count = 0 }
        let woken = Woken()
        func watch() {
            withObservationTracking {
                _ = engine.media.video
            } onChange: {
                woken.count += 1
            }
        }
        let same = MediaDemuxer.VideoSizeChange(
            seconds: 1, width: 640, height: 360, sampleAspectRatio: engine.media.video.sampleAspectRatio)
        watch()
        engine.videoSizeDidChange(to: same)
        #expect(woken.count == 0, "A landing in the size shown woke the observers")

        let other = MediaDemuxer.VideoSizeChange(
            seconds: 1, width: 320, height: 180, sampleAspectRatio: engine.media.video.sampleAspectRatio)
        engine.videoSizeDidChange(to: other)
        #expect(woken.count == 1)
        #expect(engine.media.video.width == 320)
    }
}
