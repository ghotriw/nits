import Foundation
import Testing

@testable import NitsCore

/// A read-ahead demuxer that drops its video (the app is in the background and plays the audio on): the audio alone
/// drives the read-ahead limit, the video queue stays empty, and seeks go by the audio.
@Suite("Demuxer video drop", .serialized)
struct DemuxerVideoDropTests {
    private static func makeDemuxer(seconds: Double = 2) throws -> MediaDemuxer? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return nil }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.startReadAhead(limits: MediaDemuxer.ReadAheadLimits(seconds: seconds))
        return demuxer
    }

    private static func queuedVideoPackets(_ demuxer: MediaDemuxer) -> Int {
        demuxer.queueLock.lock()
        defer { demuxer.queueLock.unlock() }
        return demuxer.videoQueue.count
    }

    @Test("The audio keeps coming past the read-ahead limit while the video is dropped")
    func audioKeepsFillingWhileVideoIsDropped() async throws {
        guard let demuxer = try Self.makeDemuxer() else { return }
        demuxer.setVideoDropped(true)

        let rate = Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)
        var lastSeconds = 0.0
        var idleSince = ContinuousClock.now
        while lastSeconds < 12, !demuxer.isAudioEOF {
            if let packet = demuxer.nextAudioPacket() {
                lastSeconds = Double(packet.pts) * rate
                idleSince = .now
            } else {
                #expect(ContinuousClock.now - idleSince < .seconds(2), "The audio ran dry at \(lastSeconds) s")
                if ContinuousClock.now - idleSince >= .seconds(2) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(lastSeconds >= 12)
        #expect(demuxer.consumedSeconds >= 10, "The audio drives the position the limit is measured from")
        #expect(Self.queuedVideoPackets(demuxer) == 0)
    }

    @Test("Reading stops at the seconds limit with the audio unconsumed, not at the end of the input")
    func readStopsAtTheSecondsLimit() async throws {
        guard let demuxer = try Self.makeDemuxer() else { return }
        demuxer.setVideoDropped(true)
        try await Task.sleep(for: .seconds(1.5))

        let ended = demuxer.queueLock.withLockUnchecked { demuxer.readAheadEnded }
        let ahead = demuxer.readAheadState.withLock { $0 } - demuxer.consumedSeconds
        #expect(!ended, "A 30 s file would have been read to its end")
        #expect(ahead < 5, "Read \(ahead) s ahead with a limit of 2 s")
        #expect(Self.queuedVideoPackets(demuxer) == 0)
    }

    @Test("Dropping the video takes the history limits to 0 and giving it back restores them")
    func limitsAreRestored() throws {
        guard let demuxer = try Self.makeDemuxer() else { return }
        func limits() -> (video: Int, audio: Int) {
            demuxer.queueLock.lock()
            defer { demuxer.queueLock.unlock() }
            return (demuxer.videoQueue.maxBackBytes, demuxer.audioQueue.maxBackBytes)
        }
        let before = limits()
        try #require(before.video > 0)

        demuxer.setVideoDropped(true)
        #expect(limits() == (0, 0))
        demuxer.setVideoDropped(false)
        #expect(limits() == before)
    }
}

extension DemuxerVideoDropTests {
    @Test("A seek while the video is dropped lands the audio at the target and queues no video")
    func seekWhileDroppedLandsAudioAtTarget() async throws {
        guard let demuxer = try Self.makeDemuxer() else { return }
        demuxer.setVideoDropped(true)

        let outcome = demuxer.seekReportingCache(to: 5.0, exact: true)
        #expect(!outcome.fromCache)
        let rate = Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)
        var first: MediaDemuxer.DemuxedAudioPacket?
        for _ in 0..<400 where first == nil {
            first = demuxer.nextAudioPacket()
            if first == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let packet = try #require(first)
        #expect(
            abs(Double(packet.pts) * rate - 5.0) < 0.1, "The first audio packet is at \(Double(packet.pts) * rate) s")
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.queuedVideoPackets(demuxer) == 0)
    }

    @Test("Packets read before the video was dropped do not serve a seek after it is taken back")
    func cacheRefusesAfterDrop() async throws {
        guard let demuxer = try Self.makeDemuxer() else { return }
        var pictures = 0
        while pictures < 30 {
            if demuxer.nextVideoSample() != nil { pictures += 1 } else { try await Task.sleep(for: .milliseconds(5)) }
        }
        demuxer.setVideoDropped(true)
        demuxer.setVideoDropped(false)
        #expect(!demuxer.seekReportingCache(to: 0.5, exact: true).fromCache)
    }

    @Test("While the video is dropped no seek is served from the cache")
    func cacheRefusesWhileDropped() async throws {
        guard let demuxer = try Self.makeDemuxer() else { return }
        demuxer.setVideoDropped(true)
        demuxer.seekReportingCache(to: 5.0, exact: true)
        for _ in 0..<100 where demuxer.nextAudioPacket() == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!demuxer.seekReportingCache(to: 5.2, exact: true).fromCache)
    }
}

extension DemuxerVideoDropTests {
    @Test("Without read-ahead (a local file) the audio pulled on demand does not stop at the video queue's limit")
    func audioIsPulledWithoutVideoBackpressure() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.setVideoDropped(true)

        let rate = Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)
        var lastSeconds = 0.0
        while lastSeconds < 20, let packet = demuxer.nextAudioPacket() {
            lastSeconds = Double(packet.pts) * rate
        }
        #expect(lastSeconds >= 20, "The audio stopped at \(lastSeconds) s: the video queue filled behind it")
        #expect(Self.queuedVideoPackets(demuxer) == 0)
    }
}
