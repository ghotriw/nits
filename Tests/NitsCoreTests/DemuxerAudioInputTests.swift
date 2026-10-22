import CFFmpeg
import Foundation
import Testing

@testable import NitsCore

/// What lets the audio heard come from another input than the picture: each stream's own end, no audio track
/// selected, and an input read for its audio alone.
@Suite("Demuxer audio inputs")
struct DemuxerAudioInputTests {
    @Test("Video ending before audio ends on its own, read on demand and ahead", arguments: [false, true])
    func videoEndsBeforeAudio(readingAhead: Bool) async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .videoEndsBeforeAudio) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        if readingAhead { demuxer.startReadAhead() }

        var pictures = 0
        while demuxer.nextVideoSample() != nil { pictures += 1 }
        #expect(pictures > 0)
        #expect(demuxer.isVideoEOF)
        #expect(!demuxer.isAudioEOF, "8 s of audio play on past the last picture")
        #expect(!demuxer.isEOF)

        var audio = 0
        for _ in 0..<10_000 where !demuxer.isAudioEOF {
            if demuxer.nextAudioPacket() != nil {
                audio += 1
            } else if readingAhead {
                // The read-ahead thread queues it.
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(audio > 0)
        #expect(demuxer.isAudioEOF && demuxer.isEOF)
    }

    @Test("With no audio track selected, the input hands on pictures only and its audio counts as ended")
    func deselectsAudio() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        try #require(demuxer.audioTracks.count >= 2)

        demuxer.selectAudioTrack(trackId: nil)
        #expect(demuxer.isAudioEOF && !demuxer.isVideoEOF)
        #expect(demuxer.nextAudioPacket() == nil)
        for _ in 0..<48 { _ = try #require(demuxer.nextVideoSample()) }
        #expect(demuxer.nextAudioPacket() == nil, "Audio read with the pictures was queued")
        #expect(demuxer.audioDecoderInput() == nil)

        // Selected again, its track plays from where reading is.
        let track = try #require(demuxer.audioTracks.first)
        demuxer.selectAudioTrack(trackId: track.id)
        #expect(!demuxer.isAudioEOF)
        #expect(demuxer.nextAudioPacket() != nil)
    }

    @Test("An input opened for its audio has no picture, subtitles or captions, and reads its audio to the end")
    func readsAudioOnly() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let demuxer = try #require(MediaDemuxer(url: path, audioOnly: true))
        #expect(!demuxer.hasVideo && demuxer.videoStreamIndex < 0)
        #expect(demuxer.audioTracks.count >= 2)
        #expect(demuxer.subtitleTracks.isEmpty)
        #expect(demuxer.isVideoEOF)

        var last: MediaDemuxer.DemuxedAudioPacket?
        for _ in 0..<100_000 where !demuxer.isAudioEOF {
            guard let packet = demuxer.nextAudioPacket() else { break }
            last = packet
        }
        #expect(demuxer.isAudioEOF)
        // The whole 30 s track.
        let end = try #require(last).pts
        let timebase = demuxer.audioTimebase
        #expect(Double(end) * Double(timebase.num) / Double(timebase.den) > 29)
    }
}
