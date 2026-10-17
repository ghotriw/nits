import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("Audio renderer sink", .hostDependent)
struct AudioRendererSinkTests {
    private static func decodedAudio(seconds: Double) throws -> [CMSampleBuffer] {
        let path = try #require(SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC))
        let demuxer = try #require(MediaDemuxer(url: path))
        let params = try #require(demuxer.getAudioCodecParameters())
        let decoder = try #require(FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase))
        var buffers: [CMSampleBuffer] = []
        while let packet = demuxer.nextAudioPacket() {
            buffers += decoder.decode(packetData: packet.data, pts: packet.pts, timebase: demuxer.audioTimebase)
            if let last = buffers.last, CMSampleBufferGetPresentationTimeStamp(last).seconds > seconds { break }
        }
        return buffers
    }

    /// The feeder keeps a buffer whose enqueue threw `CancellationError` and delivers it after a resume; a buffer
    /// reported as taken but not taken is lost, and the gap is heard once playback reaches it.
    @available(macOS 27.0, *)
    @Test("A cancelled enqueue throws CancellationError instead of reporting the buffer as taken")
    func cancelledEnqueueThrows() async throws {
        let buffers = try Self.decodedAudio(seconds: 10)
        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = 0
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let sink = ReceiverAudioSink(receiver: synchronizer.sampleBufferReceiver(adding: renderer))
        defer { sink.flush() }

        // With the clock stopped the renderer fills up and the next enqueue waits for room.
        let accepted = LockIsolated(0)
        nonisolated(unsafe) let input = buffers
        let feeding = Task {
            for buffer in input {
                try await sink.enqueue(buffer)
                accepted.withValue { $0 += 1 }
            }
        }
        // A renderer that has taken nothing yet is still starting up, not applying backpressure: cancelling then
        // races the first enqueue, which completes and is rightly counted.
        let deadline = ContinuousClock.now + .seconds(10)
        var lastCount = -1
        while lastCount <= 0 || accepted.value != lastCount, ContinuousClock.now < deadline {
            lastCount = accepted.value
            try await Task.sleep(for: .milliseconds(300))
        }
        // CI runners (VMs without an audio output device) never take a buffer: there is no backpressure to test.
        guard lastCount > 0 else {
            feeding.cancel()
            _ = await feeding.result
            return
        }
        try #require(lastCount < buffers.count, "The renderer took all \(buffers.count) buffers without backpressure")

        feeding.cancel()
        let outcome = await feeding.result
        #expect(throws: CancellationError.self, "The waiting enqueue did not report the cancellation") {
            try outcome.get()
        }
        #expect(accepted.value == lastCount, "Buffers were reported as taken after the cancellation")
    }
}
