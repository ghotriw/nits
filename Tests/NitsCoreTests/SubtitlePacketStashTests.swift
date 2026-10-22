import CFFmpeg
import Foundation
import Testing

@testable import NitsCore

@Suite("Subtitle packets playback read, for a track chosen later")
struct SubtitlePacketStashTests {
    /// Reads the file to its end, as playback does.
    private func readToEnd(_ demuxer: MediaDemuxer) {
        while demuxer.nextVideoSample() != nil {}
    }

    /// Takes what the selected track read before it was chosen and merges it, as `SubtitleController.refreshEmbedded` does.
    @discardableResult
    private func mergeStash(of demuxer: MediaDemuxer) throws -> SubtitlePacketStash.Snapshot {
        let stashed = try #require(demuxer.takeStashedSubtitles())
        let decoded = EmbeddedSubtitleReader.decode(stashed.snapshot)
        #expect(
            demuxer.mergeStashed(decoded, of: stashed.snapshot, selection: stashed.selection, span: stashed.span))
        return stashed.snapshot
    }

    @Test("A track chosen after playback read it has its cues and script at once, and needs no window read")
    func textTrackChosenLater() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        readToEnd(demuxer)
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        #expect(demuxer.getLiveSubtitleDocument().cues.isEmpty, "Nothing until the stash is merged")
        #expect(demuxer.subtitleWindow(around: 3) == 0...Double.infinity, "Playback reads on from the end")

        try mergeStash(of: demuxer)
        let document = demuxer.getLiveSubtitleDocument()
        #expect(document.cues.map(\.text) == ["Hello"])
        #expect(document.assScript?.events.count == 2, "Both events, the drawing too")
        #expect(demuxer.subtitleWindow(around: 3) == nil)
        #expect(demuxer.takeStashedSubtitles() == nil, "Taken once")
    }

    @Test("A seek starts a new stretch: what it skipped stays for a window read")
    func seekSplitsStretches() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.seek(to: 3, exact: false)
        readToEnd(demuxer)
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)

        let snapshot = try mergeStash(of: demuxer)
        #expect(snapshot.stretches.map(\.range) == [3...Double.infinity], "Nothing was read before the seek")
        // The one keyframe is at 0: playback read "Hello" on the way to 3 s, before the stretch; a window gets it.
        #expect(demuxer.getLiveSubtitleDocument().cues.isEmpty)
        #expect(demuxer.subtitleWindow(around: 3) == 0...3, "From the preroll up to the stretch read")
        #expect(demuxer.subtitleWindow(around: 5) == 0...3, "A cue from before 3 s may still be on screen")
    }

    @Test("PGS sets read before the track was chosen end where the stream clears or replaces them")
    func bitmapTrackChosenLater() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        readToEnd(demuxer)
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        try mergeStash(of: demuxer)

        let cues = demuxer.getLiveSubtitleDocument().imageCues.sorted { $0.startTime < $1.startTime }
        try #require(cues.count == 2, "Cues: \(cues.map { ($0.startTime, $0.endTime) })")
        #expect(abs(cues[0].startTime) < 0.01 && abs(cues[0].endTime - 1.5) < 0.01)
        #expect(abs(cues[1].startTime - 2.5) < 0.01)
    }

    @Test("The file's own index tells where a track's packets are, read with no packet: Matroska Cues, MP4 samples")
    func indexedStarts() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV),
            let transportStream = SyntheticTestMediaFactory.ensureMedia(preset: .dvbSubtitlesTS)
        else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        #expect(demuxer.needsSubtitleIndex)
        #expect(demuxer.indexedSubtitleStarts(of: track.streamIndex, in: 0...10) == nil, "Not read yet")
        let index = try #require(EmbeddedSubtitleReader.readIndex(url: path, headers: [:]))
        demuxer.storeSubtitleIndex(index)
        #expect(!demuxer.needsSubtitleIndex)
        let starts = try #require(demuxer.indexedSubtitleStarts(of: track.streamIndex, in: 0...10))
        #expect(starts.map { ($0 * 10).rounded() / 10 } == [0, 3], "The two events")
        #expect(demuxer.indexedSubtitleStarts(of: track.streamIndex, in: 0.5...2.5) == [])

        if let movie = SyntheticTestMediaFactory.ensureMedia(preset: .captionsC608MOV) {
            let demuxer = try #require(MediaDemuxer(url: movie))
            let captions = try #require(demuxer.subtitleTracks.first { !$0.captionsInVideo })
            let index = try #require(EmbeddedSubtitleReader.readIndex(url: movie, headers: [:]))
            #expect(index[captions.streamIndex]?.isEmpty == false, "An MP4 sample table lists the caption samples")
        }
        if let fragmented = SyntheticTestMediaFactory.ensureMedia(preset: .captionsC608FragmentedMOV) {
            // FFmpeg reads every fragment of a seekable file without a complete `sidx` at opening: the captions are
            // listed to the last. An index that stops short of the end (a CMAF `sidx`, a source that can't seek) is
            // none at all.
            let index = try #require(EmbeddedSubtitleReader.readIndex(url: fragmented, headers: [:]))
            #expect((index.values.first?.max() ?? 0) > 4, "\(index)")
        }

        // MPEG-TS has no index of its own: FFmpeg's lists what its timestamp search read.
        let unindexed = try #require(MediaDemuxer(url: transportStream))
        let dvb = try #require(unindexed.subtitleTracks.first)
        #expect(!unindexed.needsSubtitleIndex)
        #expect(EmbeddedSubtitleReader.readIndex(url: transportStream, headers: [:]) == nil)
        unindexed.seek(to: 3, exact: false)
        #expect(unindexed.indexedSubtitleStarts(of: dvb.streamIndex, in: 0...10) == nil)
    }

    @Test("A range the lists hold inside the window is read again, not left as a gap before the time")
    func windowAroundIsland() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .assSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.selectSubtitleTrack(trackId: try #require(demuxer.subtitleTracks.first).id)
        demuxer.seek(to: 5, exact: false)
        let selection = demuxer.liveSubtitleSelection
        #expect(demuxer.mergeLiveSubtitles(.init(), covering: 2...3, selection: selection.id, span: selection.span))
        #expect(demuxer.subtitleWindow(around: 5) == 0...5)
        #expect(demuxer.mergeLiveSubtitles(.init(), covering: 3...5, selection: selection.id, span: selection.span))
        #expect(demuxer.subtitleWindow(around: 5) == 0...2, "Held up to the end: the window stops before it")
    }

    @Test("A clear playback read before the track was chosen ends the set a later window brings")
    func stashedClearEndsWindowSet() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .pgsSubtitlesMKV) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let track = try #require(demuxer.subtitleTracks.first)
        demuxer.selectSubtitleTrack(trackId: track.id)
        let selection = demuxer.liveSubtitleSelection

        let ctx = avformat_alloc_context()!
        defer { avformat_free_context(ctx) }
        let stream = try #require(avformat_new_stream(ctx, nil))
        let parameters = try #require(SubtitlePacketStash.StreamParameters(of: stream))
        let snapshot = SubtitlePacketStash.Snapshot(
            parameters: parameters, stretches: [.init(range: 3...5, packets: [], isCurrent: true)])
        var stashed = EmbeddedSubtitleReader.Packets()
        stashed.bitmapOutputs = [.init(truncatePreviousAt: 4)]
        #expect(demuxer.mergeStashed([stashed], of: snapshot, selection: selection.id, span: selection.span))

        let shown = SubtitleImageCue(
            id: SubtitleImageCue.makeID(), startTime: 2.5, endTime: 7.5, canvasWidth: 320, canvasHeight: 240,
            regions: [], endIsEstimated: true)
        var window = EmbeddedSubtitleReader.Packets()
        window.bitmapOutputs = [.init(truncatePreviousAt: 2.5, cue: shown)]
        #expect(demuxer.mergeLiveSubtitles(window, covering: 0...3, selection: selection.id, span: selection.span))
        #expect(demuxer.getLiveSubtitleDocument().imageCues.map(\.endTime) == [4])
    }

    @Test("A window read past its byte limit, counted in bytes read after its seek, gives nothing")
    func windowByteLimit() throws {
        // The limit counts the bytes of every stream, so any stream will do: the sound of a 2 MB film.
        for preset in [SyntheticTestMediaFactory.Preset.chaptersMKV, .chaptersMP4] {
            guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
            let demuxer = try #require(MediaDemuxer(url: path))
            let streamIndex = demuxer.audioStreamIndex
            try #require(streamIndex >= 0)
            let read = { (range: ClosedRange<Double>, limit: Int64?) in
                EmbeddedSubtitleReader.readSubtitles(
                    url: path, headers: [:], streamIndex: streamIndex, in: range, byteLimit: limit)
            }
            #expect(read(10...15, nil) != nil, "\(preset)")
            #expect(read(10...15, 64 << 10) == nil, "\(preset): five seconds of the film are more")
            // Half a second halfway into the file: an MP4 seek only picks the sample, so the position moves 1 MB.
            #expect(read(10...10.5, 512 << 10) != nil, "\(preset)")
        }
    }
    @Test("Picture streams keep the newest packets within the limit, and cover the timeline past the latest dropped")
    func bitmapLimit() throws {
        let ctx = avformat_alloc_context()!
        defer { avformat_free_context(ctx) }
        for codec in [AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_SUBRIP] {
            let stream = try #require(avformat_new_stream(ctx, nil))
            stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            stream.pointee.codecpar.pointee.codec_id = codec
            stream.pointee.time_base = AVRational(num: 1, den: 1000)
        }

        var stash = SubtitlePacketStash()
        let size = 1 << 20
        let count = SubtitlePacketStash.bitmapByteLimit / size + 10
        for second in 0..<count {
            for streamIndex in 0..<2 {
                var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
                defer { av_packet_free(&packet) }
                let pkt = try #require(packet)
                try #require(av_new_packet(pkt, Int32(streamIndex == 0 ? size : 16)) == 0)
                pkt.pointee.stream_index = Int32(streamIndex)
                pkt.pointee.pts = Int64(second) * 1000
                pkt.pointee.pos = Int64(second * 2 + streamIndex) * Int64(size)
                stash.add(pkt, in: ctx)
            }
        }

        let readAhead = Double(count)
        let pictures = try #require(stash.snapshot(of: 0, in: ctx, readAhead: readAhead))
        #expect(pictures.stretches.map(\.range) == [(9.0).nextUp...readAhead], "Past the latest dropped")
        #expect(pictures.stretches.first?.packets.count == count - 10)

        // A seek stepping back reads a dropped packet again: below what the stretch covers, it isn't kept, and takes
        // none of the newer packets' room.
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        try #require(av_new_packet(pkt, Int32(size)) == 0)
        pkt.pointee.stream_index = 0
        pkt.pointee.pts = 0
        // No position (FFmpeg doesn't know it), so not taken for a packet already kept.
        pkt.pointee.pos = -1
        stash.add(pkt, in: ctx)
        let again = try #require(stash.snapshot(of: 0, in: ctx, readAhead: readAhead).flatMap(\.stretches.first))
        #expect(again.packets.count == count - 10)
        #expect(again.range == (9.0).nextUp...readAhead)
        let text = try #require(stash.snapshot(of: 1, in: ctx, readAhead: readAhead))
        #expect(text.stretches.map(\.range) == [0...readAhead], "Text is kept whole")
        #expect(text.stretches.first?.packets.count == count)
    }
}
