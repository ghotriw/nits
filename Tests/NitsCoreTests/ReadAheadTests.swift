import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// The read-ahead thread (`MediaDemuxer+ReadAhead.swift`) on local files: it is started for network sources, and
/// reads them no differently.
@Suite("Demuxer read-ahead")
struct ReadAheadTests {
    private struct Read: Equatable {
        var pictures: [Int64] = []
        var audio: [Int64] = []
    }

    /// Every picture, then every audio packet, as `nextVideoSample` and `nextAudioPacket` hand them out.
    private static func readAll(_ demuxer: MediaDemuxer) -> Read {
        var read = Read()
        while let sample = demuxer.nextVideoSample() {
            read.pictures.append(CMSampleBufferGetPresentationTimeStamp(sample).value)
        }
        while let packet = demuxer.nextAudioPacket() {
            read.audio.append(packet.pts)
        }
        return read
    }

    @Test("Reading ahead hands out the same packets as reading on demand, then reports the end")
    func samePacketsAsOnDemand() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let onDemand = Self.readAll(try #require(MediaDemuxer(url: path)))

        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.startReadAhead(limits: .init(seconds: 3))
        let ahead = Self.readAll(demuxer)
        #expect(ahead.pictures.count == 720)
        #expect(ahead == onDemand)
        #expect(demuxer.isEOF)
    }

    @Test("It reads up to the limit ahead of what was taken, and on as packets are taken")
    func stopsAtLimit() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.startReadAhead(limits: .init(seconds: 4))
        _ = try #require(demuxer.nextVideoSample())

        try await Task.sleep(for: .milliseconds(500))
        #expect((4.0..<5.0).contains(demuxer.readAheadSeconds), "read ahead to \(demuxer.readAheadSeconds) s")
        for _ in 0..<(24 * 5) { _ = demuxer.nextVideoSample() }
        try await Task.sleep(for: .milliseconds(500))
        #expect((9.0..<10.0).contains(demuxer.readAheadSeconds), "read ahead to \(demuxer.readAheadSeconds) s")
    }

    @Test("Audio playing on past the last picture by more than the limit is read to its end")
    func readsAudioPastVideoEnd() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .videoEndsBeforeAudio) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.startReadAhead(limits: .init(seconds: 1))
        while demuxer.nextVideoSample() != nil {}

        var lastAudio = 0.0
        let deadline = ContinuousClock.now + .seconds(5)
        while !demuxer.isEOF, ContinuousClock.now < deadline {
            if let packet = demuxer.nextAudioPacket() {
                lastAudio = Double(packet.pts) * Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)
            } else {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(demuxer.isEOF)
        #expect(lastAudio > 9.5, "audio read to \(lastAudio) s")
    }

    @Test("A seek clears what was read ahead and reads on from its target")
    func seekReadsFromTarget() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.startReadAhead(limits: .init(seconds: 3))
        for _ in 0..<48 { _ = demuxer.nextVideoSample() }

        demuxer.seek(to: 20, exact: false)
        let first = try #require(demuxer.nextVideoSample())
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(first).seconds - 20) < 0.05)
        var queuedAudio = demuxer.nextAudioPacket()
        while queuedAudio == nil, !demuxer.isEOF {
            try await Task.sleep(for: .milliseconds(1))
            queuedAudio = demuxer.nextAudioPacket()
        }
        let audio = try #require(queuedAudio)
        #expect(
            abs(Double(audio.pts) * Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den) - 20) < 0.1)

        var pictures = 1
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures == 240)
    }

    @Test("Without waiting, an empty queue returns at once and the feeder retries")
    func nonWaitingTakesWhatIsQueued() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.startReadAhead(limits: .init(seconds: 3))
        var pictures = 0
        while !demuxer.isEOF {
            if demuxer.nextVideoSample(waitingForReadAhead: false) != nil {
                pictures += 1
            } else if demuxer.nextAudioPacket() == nil {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        #expect(pictures == 720)
    }
}
