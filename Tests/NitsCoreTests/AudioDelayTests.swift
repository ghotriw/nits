import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Records what reaches the renderer instead of playing it.
private final class RecordingAudioSink: AudioRendererSink, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var timestamps: [CMTime] = []
    private var flushes = 0

    var enqueuedTimestamps: [CMTime] {
        lock.withLock { timestamps }
    }

    var flushCount: Int {
        lock.withLock { flushes }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lock.withLock { timestamps.append(pts) }
    }

    func flush() {
        lock.withLock {
            timestamps.removeAll()
            flushes += 1
        }
    }
}

/// Holds each buffer until `release()`, like a renderer applying backpressure; a flush cancels the wait.
private final class GatedAudioSink: AudioRendererSink {
    private let waiting = OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>(initialState: nil)

    var isWaiting: Bool {
        waiting.withLock { $0 != nil }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiting.withLock { $0 = continuation }
        }
    }

    func release() {
        waiting.withLock { waiting in
            waiting?.resume()
            waiting = nil
        }
    }

    func flush() {
        waiting.withLock { waiting in
            waiting?.resume(throwing: CancellationError())
            waiting = nil
        }
    }
}

@Suite("Audio delay sink")
struct DelayedAudioSinkTests {
    /// Decoded audio from the start of the synthetic FLAC up to `seconds`, or `nil` without FFmpeg.
    private static func decodedAudio(seconds: Double) -> [CMSampleBuffer]? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC),
            let demuxer = MediaDemuxer(url: path),
            let params = demuxer.getAudioCodecParameters(),
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
        else { return nil }
        var buffers: [CMSampleBuffer] = []
        while let packet = demuxer.nextAudioPacket() {
            buffers += decoder.decode(packetData: packet.data, pts: packet.pts, timebase: demuxer.audioTimebase)
            if let last = buffers.last, CMSampleBufferGetPresentationTimeStamp(last).seconds > seconds { break }
        }
        return buffers
    }

    private static func end(of buffer: CMSampleBuffer) -> Double {
        (CMSampleBufferGetPresentationTimeStamp(buffer) + CMSampleBufferGetDuration(buffer)).seconds
    }

    private static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 1_000_000)
    }

    @Test("Audio reaches the renderer shifted by the delay")
    func shiftsTimestamps() async throws {
        guard let buffers = Self.decodedAudio(seconds: 1) else { return }
        let recorder = RecordingAudioSink()
        let sink = DelayedAudioSink(wrapping: BufferTrackingAudioSink(wrapping: recorder))
        sink.setDelay(Self.seconds(0.25))
        for buffer in buffers {
            try await sink.enqueue(buffer)
        }

        let expected = buffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds + 0.25 }
        let actual = recorder.enqueuedTimestamps.map(\.seconds)
        try #require(actual.count == expected.count)
        for (a, e) in zip(actual, expected) {
            #expect(abs(a - e) < 1e-6)
        }
        let bufferedEnd = try #require(sink.bufferedEnd?.seconds)
        #expect(abs(bufferedEnd - (Self.end(of: buffers[buffers.count - 1]) + 0.25)) < 1e-6)
    }

    @Test("A delay change flushes the renderer and hands back the audio still to be heard")
    func changeDelayReturnsAudioAfterClock() async throws {
        guard let buffers = Self.decodedAudio(seconds: 3) else { return }
        let recorder = RecordingAudioSink()
        let sink = DelayedAudioSink(wrapping: BufferTrackingAudioSink(wrapping: recorder))
        for buffer in buffers {
            try await sink.enqueue(buffer)
        }

        // At 1 s with audio played 0.5 s later, the media's audio from 0.5 s on is still to be heard.
        let replay = sink.changeDelay(to: Self.seconds(0.5), keepingAudioAfter: Self.seconds(1))
        #expect(recorder.flushCount == 1)
        #expect(recorder.enqueuedTimestamps.isEmpty)
        #expect(sink.bufferedEnd == nil)
        let first = try #require(replay.first)
        #expect(Self.end(of: first) > 0.5)
        #expect(CMSampleBufferGetPresentationTimeStamp(first).seconds <= 0.5)
        #expect(replay.count == buffers.count { Self.end(of: $0) > 0.5 })

        // Enqueued again, it plays with the new delay and is kept for the next change.
        for buffer in replay {
            try await sink.enqueue(buffer)
        }
        let replayedStart = try #require(recorder.enqueuedTimestamps.first).seconds
        #expect(abs(replayedStart - (CMSampleBufferGetPresentationTimeStamp(first).seconds + 0.5)) < 1e-6)
        #expect(
            sink.changeDelay(to: .zero, keepingAudioAfter: Self.seconds(1)).count
                == replay.count { Self.end(of: $0) > 1 })

        // A flush (seek, reload) forgets it.
        for buffer in buffers {
            try await sink.enqueue(buffer)
        }
        sink.flush()
        #expect(sink.changeDelay(to: Self.seconds(0.1), keepingAudioAfter: .invalid).isEmpty)
    }

    @Test("The audio the renderer holds back is known until it is taken or flushed")
    func pendingStartFollowsBackpressure() async throws {
        guard let decoded = Self.decodedAudio(seconds: 0.1)?.first else { return }
        nonisolated(unsafe) let buffer = decoded
        let gate = GatedAudioSink()
        let sink = DelayedAudioSink(wrapping: BufferTrackingAudioSink(wrapping: gate))
        sink.setDelay(Self.seconds(0.25))
        #expect(sink.pendingStart == nil)

        let taken = Task { try await sink.enqueue(buffer) }
        while !gate.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        // On the clock's timeline, like `bufferedEnd`.
        let pending = try #require(sink.pendingStart?.seconds)
        #expect(abs(pending - (CMSampleBufferGetPresentationTimeStamp(buffer).seconds + 0.25)) < 1e-6)
        gate.release()
        try await taken.value
        #expect(sink.pendingStart == nil)

        let flushed = Task { try await sink.enqueue(buffer) }
        while !gate.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        sink.flush()
        #expect(sink.pendingStart == nil)
        await #expect(throws: CancellationError.self) { try await flushed.value }
    }

    @Test("Only the last few seconds of audio are kept")
    func retentionIsBounded() async throws {
        let retained = DelayedAudioSink.retainedSeconds
        guard let buffers = Self.decodedAudio(seconds: retained + 3) else { return }
        let sink = DelayedAudioSink(wrapping: BufferTrackingAudioSink(wrapping: RecordingAudioSink()))
        for buffer in buffers {
            try await sink.enqueue(buffer)
        }
        let kept = sink.changeDelay(to: .zero, keepingAudioAfter: .invalid)
        let lastEnd = Self.end(of: try #require(buffers.last))
        let firstKept = try #require(kept.first)
        #expect(Self.end(of: firstKept) >= lastEnd - retained)
        #expect(CMSampleBufferGetPresentationTimeStamp(firstKept).seconds < lastEnd - retained + 0.1)
        #expect(kept.count < buffers.count)
    }
}

/// Changing the delay during playback moves the queued audio without seeking; seeks start audio at the shifted
/// position.
@Suite("Audio delay during playback", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
@MainActor
struct AudioDelayPlaybackTests {
    /// Seconds of audio the renderer holds past the clock.
    private func audioAhead(of engine: PlayerEngine) -> Double? {
        guard let end = engine.audioSink.bufferedEnd, end.isNumeric else { return nil }
        return (end - engine.synchronizer.currentTime()).seconds
    }

    @Test("A delay change while playing shifts the queued audio and keeps the clock running")
    func changeWhilePlaying() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 1.0))
        #expect(audioAhead(of: engine) != nil)
        let seekId = engine.seekGeneration.current
        let clockBefore = engine.synchronizer.currentTime().seconds

        engine.setAudioDelay(0.5)
        #expect(engine.audioDelay == 0.5)
        // Audio is fed again (the feeding run restarts, `firstFedAudioPTS` is set by its first buffer). How far the
        // renderer then holds audio ahead shows no shift when it was already full: it holds 1.1–1.4 s at most.
        #expect(await engine.waitUntil(timeout: .seconds(3)) { engine.firstFedAudioPTS.withLock { $0 } != nil })
        // It starts with audio already played once, now heard again at the clock: no gap. Continuing with the next
        // decoded audio instead would start as far past the clock as the renderer held audio.
        let firstFed = try #require(engine.firstFedAudioPTS.withLock { $0 }?.seconds)
        #expect(firstFed + 0.5 < clockBefore + 0.2, "Audio resumed from \(firstFed)s of the media at \(clockBefore)s")
        #expect(engine.seekGeneration.current == seekId, "The delay change seeked")
        #expect(!engine.isBuffering)
        #expect(engine.synchronizer.currentTime().seconds > clockBefore, "The clock stopped")
        #expect(await engine.waitForClock(toPass: engine.synchronizer.currentTime().seconds + 0.5))
    }

    @Test("A delay change while paused takes effect when playback resumes")
    func changeWhilePaused() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback(advancingBy: 1.0))
        engine.pause()
        let seekId = engine.seekGeneration.current
        let pausedAt = engine.synchronizer.currentTime().seconds

        engine.setAudioDelay(0.5)
        #expect(await engine.waitUntil(timeout: .seconds(3)) { engine.audioSink.bufferedEnd == nil })
        engine.play()
        #expect(await engine.waitUntil(timeout: .seconds(3)) { engine.firstFedAudioPTS.withLock { $0 } != nil })
        // Heard at the clock, the audio is from half a second earlier in the media (see `changeWhilePlaying`).
        let firstFed = try #require(engine.firstFedAudioPTS.withLock { $0 }?.seconds)
        #expect(firstFed + 0.5 < pausedAt + 0.2, "Audio resumed from \(firstFed)s of the media at \(pausedAt)s")
        #expect(engine.seekGeneration.current == seekId, "The delay change seeked")
        #expect(await engine.waitForClock(toPass: engine.synchronizer.currentTime().seconds + 0.5))
    }

    @Test("A seek reads audio from the target minus the delay")
    func seekStartsAudioAtShiftedPosition() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        engine.setAudioDelay(-0.5)

        engine.seek(to: 3.0, exact: true)
        try #require(await engine.waitForPlayback())
        // Audio played half a second early starts with the media's audio at 3.5 s, scheduled at 3 s; read from 3 s
        // as without a delay, it would be scheduled at 2.5 s and dropped as late. `firstFedAudioPTS` is media time.
        let firstFed = try #require(engine.firstFedAudioPTS.withLock { $0 }?.seconds)
        #expect(abs(firstFed - 3.5) < 0.1, "First audio fed from \(firstFed)s of the media")
    }

    @Test("A keyframe seek with audio played late starts audio before the keyframe")
    func keyframeSeekWithPositiveDelay() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        engine.setAudioDelay(0.5)

        engine.pause()
        engine.seek(to: 4.0, exact: false)
        try #require(await engine.waitForSeekToSettle())
        // The seek lands on a keyframe; audio heard with it is the media's audio half a second earlier.
        let keyframe = engine.currentTime
        engine.play()
        try #require(await engine.waitForPlayback())
        let firstFed = try #require(engine.firstFedAudioPTS.withLock { $0 }?.seconds)
        #expect(
            abs(firstFed - (keyframe - 0.5)) < 0.1,
            "Landed on \(keyframe)s; first audio fed from \(firstFed)s of the media")
    }

    @Test("The delay is clamped, rounded to milliseconds and restored when the media is opened again")
    func delayIsSavedPerFile() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(engine.isLoaded)

        engine.setAudioDelay(5)
        #expect(engine.audioDelay == PlayerEngine.audioDelayRange.upperBound)
        engine.setAudioDelay(.nan)
        #expect(engine.audioDelay == PlayerEngine.audioDelayRange.upperBound)
        engine.setAudioDelay(0)
        for _ in 0..<3 { engine.stepAudioDelay(by: -0.05) }
        #expect(engine.audioDelay == -0.15)
        engine.setAudioDelay(0.12345)
        #expect(engine.audioDelay == 0.123)

        engine.load(path: path)
        try #require(engine.isLoaded)
        #expect(engine.audioDelay == 0.123)
        engine.resetAudioDelay()
        engine.load(path: path)
        try #require(engine.isLoaded)
        #expect(engine.audioDelay == 0)
    }
}
