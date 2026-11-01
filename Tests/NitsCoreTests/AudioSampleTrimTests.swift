import AudioToolbox
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("Audio sample trim")
struct AudioSampleTrimTests {
    private static let sampleRate = 48_000.0

    /// 1024 frames of 16-bit mono PCM starting at `start` seconds.
    private static func pcmBuffer(start: Double, frames: Int = 1024) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        try #require(
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        try #require(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: frames * 2, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr)
        try #require(
            CMBlockBufferFillDataBytes(
                with: 0, blockBuffer: try #require(block), offsetIntoDestination: 0, dataLength: frames * 2) == noErr)
        var buffer: CMSampleBuffer?
        try #require(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: try #require(block), formatDescription: try #require(format),
                sampleCount: frames,
                presentationTimeStamp: CMTime(seconds: start, preferredTimescale: Int32(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &buffer) == noErr)
        return try #require(buffer)
    }

    private static func cut(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    @Test("A buffer that ends before the cut is dropped, one that starts after it is kept whole")
    func dropsAndKeeps() throws {
        let buffer = try Self.pcmBuffer(start: 1.0)  // 1.0 ... 1.02133 s
        guard case .dropped = AudioSampleTrim.trim(buffer, before: Self.cut(1.5)) else {
            Issue.record("A buffer before the cut should be dropped")
            return
        }
        guard case .whole = AudioSampleTrim.trim(buffer, before: Self.cut(0.5)) else {
            Issue.record("A buffer after the cut should be kept whole")
            return
        }
    }

    @Test("The buffer that straddles the cut is shortened to the sample")
    func shortensToTheSample() throws {
        let buffer = try Self.pcmBuffer(start: 1.0)
        let cutSeconds = 1.0 + 500.0 / Self.sampleRate  // 500 samples in
        guard case .trimmed(let shortened) = AudioSampleTrim.trim(buffer, before: Self.cut(cutSeconds)) else {
            Issue.record("A buffer across the cut should be trimmed")
            return
        }
        #expect(CMSampleBufferGetNumSamples(shortened) == 1024 - 500)
        let start = CMSampleBufferGetPresentationTimeStamp(shortened).seconds
        #expect(abs(start - cutSeconds) < 1.0 / Self.sampleRate)
        let end = (CMSampleBufferGetPresentationTimeStamp(shortened) + CMSampleBufferGetDuration(shortened)).seconds
        let originalEnd = (CMSampleBufferGetPresentationTimeStamp(buffer) + CMSampleBufferGetDuration(buffer)).seconds
        #expect(abs(end - originalEnd) < 1.0 / Self.sampleRate)
    }
}
