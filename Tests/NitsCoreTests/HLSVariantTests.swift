import CFFmpeg
import CoreMedia
import Foundation
import Testing
import VideoToolbox
import os

@testable import NitsCore

@Suite("HLS Variants")
struct HLSVariantTests {
    @Test("A master playlist plays its highest-bandwidth variant and discards the others' streams")
    func selectsHighestVariant() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))

        #expect(demuxer.variants.count == 2)
        let selected = try #require(demuxer.variants.first { $0.id == demuxer.selectedVariantId })
        #expect(selected.bandwidth == demuxer.variants.map(\.bandwidth).max())
        #expect(selected.width == 640 && selected.height == 360)
        #expect(demuxer.width == 640)
        // The other variant's audio is the same rendition again, not a second track.
        #expect(demuxer.audioTracks.count == 1)

        let formatCtx = try #require(demuxer.formatCtx)
        let read = Set([demuxer.videoStreamIndex, demuxer.audioStreamIndex])
        for index in 0..<Int(formatCtx.pointee.nb_streams) {
            let discard = try #require(formatCtx.pointee.streams[index]).pointee.discard
            #expect((discard == AVDISCARD_ALL) == !read.contains(index), "stream \(index)")
        }

        var samples = 0
        while let sample = demuxer.nextVideoSample() {
            #expect(CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width == 640)
            samples += 1
        }
        #expect(samples == 180)
    }

    /// HLS can't seek by byte, so rewinding to the first byte as MPEG-TS does left reads where the opening scan
    /// stopped, a third of a second in.
    @Test("Playback and a seek to the start begin at the first frame")
    func startsAtFirstFrame() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let first = try #require(demuxer.nextVideoSample())
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(first).seconds - demuxer.videoStartTime) < 0.001)

        demuxer.seek(to: 4)
        demuxer.seek(to: 0)
        let afterSeek = try #require(demuxer.nextVideoSample())
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(afterSeek).seconds - demuxer.videoStartTime) < 0.001)
    }

    @Test("A switch splices at the new variant's first keyframe: every frame once, audio without gap or overlap")
    func splicesAtKeyframe() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        #expect(low.width == 320 && low.isSwitchable)
        let changes = OSAllocatedUnfairLock(initialState: [Int]())
        demuxer.onVariantChanged = { change in changes.withLock { $0.append(change.variant.id) } }

        var pictures: [(pts: Double, width: Int32, isSync: Bool)] = []
        while let sample = demuxer.nextVideoSample() {
            let width = CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width
            let attachments =
                CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary]
            let isSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
            pictures.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, width ?? 0, isSync))
            if pictures.count == 30 { demuxer.selectVariant(id: low.id) }
        }
        var audio: [MediaDemuxer.DemuxedAudioPacket] = []
        while let packet = demuxer.nextAudioPacket() { audio.append(packet) }

        #expect(changes.withLock { $0 } == [low.id])
        #expect(demuxer.selectedVariantId == low.id)
        let splice = try #require(pictures.firstIndex { $0.width == 320 })
        #expect(splice >= 30 && pictures[splice].isSync)
        #expect(
            pictures[..<splice].allSatisfy { $0.width == 640 } && pictures[splice...].allSatisfy { $0.width == 320 })
        // Frame times in presentation order: all 180, none twice.
        let frames = pictures.map { Int((($0.pts - demuxer.videoStartTime) * 30).rounded()) }.sorted()
        #expect(frames == Array(0..<180))

        let starts = audio.map(\.pts)
        #expect(zip(audio, starts.dropFirst()).allSatisfy { $0.pts + $0.duration == $1 })
        #expect(audio.count > 270)
    }

    /// A ladder keeps what it read like any input: a seek back inside one variant's stretch is served from it, one that
    /// would land before a switch's splice (in the variant left) is a slow seek, which reads the variant now selected.
    @Test("A seek back in a ladder's cache is served inside a variant's stretch, not across a splice")
    func cachedSeekStopsAtSplice() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        demuxer.startReadAhead(limits: .init(seconds: 1, bytes: 50 << 20, backBytes: 20 << 20))

        var pictures: [(pts: Double, width: Int32)] = []
        while let sample = demuxer.nextVideoSample() {
            let width = CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width
            pictures.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, width ?? 0))
            if pictures.count == 20 { demuxer.selectVariant(id: low.id) }
            if pictures.count == 170 { break }
        }
        let splice = try #require(pictures.first { $0.width == 320 }?.pts, "The switch didn't splice")
        let start = demuxer.videoStartTime
        #expect(splice - start > 0.9 && splice - start < 4, "Spliced at \(splice - start) s")

        // Across the splice: the picture would come from the variant left.
        #expect(demuxer.seekWithinCache(to: start + 0.2, exact: false, forward: false) == false)
        // Inside the stretch of the variant now read.
        #expect(demuxer.seekWithinCache(to: splice + 0.7, exact: false, forward: false) == true)
        let sample = try #require(demuxer.nextVideoSample())
        #expect(CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width == 320)
    }

    /// Waits for the read-ahead to splice to variant `id` and finish the switch (the muxed audio splices after the
    /// picture: `variantSwitch` stays until then, and refuses a cached seek on its own). The read-ahead reads only with
    /// room in its queue, so a picture is taken per turn to make some: at most 40, which with the 20 before keeps the
    /// cursor within 2 s, ahead of the splice unless the reading falls behind by that much (`cachedSeekBeforeSplice`
    /// then fails plainly).
    private static func waitForSplice(of id: Int, in demuxer: MediaDemuxer) -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        var taken = 0
        func switchEnded() -> Bool {
            demuxer.queueLock.lock()
            defer { demuxer.queueLock.unlock() }
            return demuxer.selectedVariantId == id && demuxer.variantSwitch == nil
        }
        while !switchEnded() && ContinuousClock.now < deadline {
            if taken < 40, demuxer.nextVideoSample() != nil { taken += 1 }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return switchEnded()
    }

    /// The usual case after an adaptive switch: reading is past the splice, playback not yet, and a seek back inside the
    /// variant played is served by the cache, in that variant's format.
    @Test("A seek back in a ladder with the splice ahead of the cursor is served in the variant being played")
    func cachedSeekBeforeSplice() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        demuxer.startReadAhead(limits: .init(seconds: 3, bytes: 50 << 20, backBytes: 20 << 20))
        var count = 0
        while count < 20, demuxer.nextVideoSample() != nil { count += 1 }
        // Adaptive bitrate asks as this does; `selectVariant(id:)` is the user's choice (below).
        demuxer.variantSelection.withLock { $0.requested = low.id }
        try #require(Self.waitForSplice(of: low.id, in: demuxer), "The switch didn't splice")
        #expect(demuxer.seekWithinCache(to: demuxer.videoStartTime + 0.2, exact: true) == true)
        let sample = try #require(demuxer.nextVideoSample())
        #expect(CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width == 640)
    }

    /// A variant chosen by hand shows from the seek the engine makes at once: packets of the one left would not.
    @Test("A seek back after a variant chosen by hand is a slow one until the picture is of that variant")
    func cachedSeekRefusedForChoiceByHand() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        demuxer.startReadAhead(limits: .init(seconds: 3, bytes: 50 << 20, backBytes: 20 << 20))
        var count = 0
        while count < 20, demuxer.nextVideoSample() != nil { count += 1 }
        demuxer.selectVariant(id: low.id)
        #expect(demuxer.seekWithinCache(to: demuxer.videoStartTime + 0.2, exact: true) == false, "Asked for")
        try #require(Self.waitForSplice(of: low.id, in: demuxer), "The switch didn't splice")
        #expect(
            demuxer.seekWithinCache(to: demuxer.videoStartTime + 0.2, exact: true) == false,
            "Spliced ahead of the cursor: the packets are of the variant left")
    }

    @Test("A seek back in a ladder before any switch is served from the cache")
    func cachedSeekInOneVariant() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        demuxer.startReadAhead(limits: .init(seconds: 3, bytes: 50 << 20, backBytes: 20 << 20))
        var count = 0
        while count < 90, demuxer.nextVideoSample() != nil { count += 1 }
        #expect(demuxer.seekWithinCache(to: demuxer.videoStartTime + 0.5, exact: true) == true)
        let sample = try #require(demuxer.nextVideoSample())
        #expect(CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width == 640)
    }

    @Test("A seek completes a switch: it reads the new variant from the target on")
    func seekCompletesSwitch() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        _ = demuxer.nextVideoSample()
        demuxer.selectVariant(id: low.id)
        demuxer.seek(to: 3)
        #expect(demuxer.selectedVariantId == low.id)
        let sample = try #require(demuxer.nextVideoSample())
        #expect(CMSampleBufferGetFormatDescription(sample).map(CMVideoFormatDescriptionGetDimensions)?.width == 320)
        let audio = try #require(demuxer.nextAudioPacket())
        #expect(demuxer.audioTracks.first?.streamIndex == demuxer.audioStreamIndex)
        #expect(Double(audio.pts) / 90_000 > 2.5)
    }

    @Test("A switch made while no audio track is selected points the tracks at the new variant's streams")
    func switchWithoutAudioFollowsTracks() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        let track = try #require(demuxer.audioTracks.first)
        let highStream = track.streamIndex

        demuxer.selectAudioTrack(trackId: nil)
        _ = demuxer.nextVideoSample()
        demuxer.selectVariant(id: low.id)
        demuxer.seek(to: 3)
        try #require(demuxer.selectedVariantId == low.id)
        #expect(demuxer.audioTracks.first?.streamIndex != highStream, "The track still names the old variant's stream")

        demuxer.selectAudioTrack(trackId: track.id)
        let audio = try #require(demuxer.nextAudioPacket(), "The track's stream is the discarded one")
        #expect(Double(audio.pts) / 90_000 > 2.5)
    }

    /// Fragmented MP4 has a variant's parameter sets only in its `avcC`: the software decoder, made with the first
    /// variant's, takes the new ones from the samples' format description. AV1 has no parameter sets: the splice
    /// builds its description from the new variant's `av1C`, and dav1d reads the sequence header of each keyframe.
    @Test(
        "The software decoder follows a switch between variants, parameter sets in band or out (H.264, AV1)",
        arguments: [SyntheticTestMediaFactory.Preset.hlsVariantsFMP4, .hlsVariants, .hlsVariantsAV1])
    func softwareDecoderFollowsSwitch(preset: SyntheticTestMediaFactory.Preset) throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        let parameters = try #require(demuxer.getVideoCodecParameters())
        let decoder = try #require(
            FFmpegVideoDecoder(
                codecParameters: parameters, timebase: demuxer.timebase, formatDescription: demuxer.formatDescription))
        let widths = OSAllocatedUnfairLock(initialState: [Int]())
        decoder.setOutputHandler { frame in
            widths.withLock { $0.append(CVPixelBufferGetWidth(frame.pixelBuffer)) }
        }

        var samples = 0
        while let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            samples += 1
            if samples == 30 { demuxer.selectVariant(id: low.id) }
        }
        decoder.drain()
        let decoded = widths.withLock { $0 }
        #expect(decoded.count == 180)
        let firstLow = try #require(decoded.firstIndex(of: 320))
        #expect(decoded[..<firstLow].allSatisfy { $0 == 640 } && decoded[firstLow...].allSatisfy { $0 == 320 })
    }

    @Test("VideoToolbox follows a switch between AV1 variants", .hostDependent)
    func hardwareDecoderFollowsAV1Switch() throws {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariantsAV1)
        else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        let low = try #require(demuxer.variants.last)
        let decoder = VTVideoDecoder()
        let widths = OSAllocatedUnfairLock(initialState: [Int]())
        decoder.setOutputHandler { frame in
            widths.withLock { $0.append(CVPixelBufferGetWidth(frame.pixelBuffer)) }
        }
        var samples = 0
        while let sample = demuxer.nextVideoSample() {
            decoder.decode(sampleBuffer: sample)
            samples += 1
            if samples == 30 { demuxer.selectVariant(id: low.id) }
        }
        decoder.drain()
        let decoded = widths.withLock { $0 }
        #expect(decoded.count == 180)
        #expect(decoded.first == 640 && decoded.last == 320)
    }

    @Test("A single file has no variants")
    func singleFileHasNoVariants() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        let demuxer = try #require(MediaDemuxer(url: path))
        #expect(demuxer.variants.isEmpty)
        #expect(demuxer.selectedVariantId == nil)
    }
}

@Suite("HLS variant playback", .serialized, .realtimePlayback, .backstopTimeLimit)
@MainActor
struct HLSVariantPlaybackTests {
    @Test("A saved HLS manifest plays; an empty playlist opens nothing and reports no error")
    func manifestPlaysEmptyPlaylistDoesNot() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("nits-empty-\(UUID().uuidString).m3u")
        try Data("#EXTM3U\n".utf8).write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        engine.stop()
        engine.load(path: empty.path)
        await engine.waitForPendingLoad()
        #expect(!engine.isLoading)
        #expect(engine.loadError == nil)
        #expect(!engine.isLoaded)
    }

    @Test("Switching variants while playing changes the picture without a stall (or a seek, read on demand)")
    func switchesWhilePlaying() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .hlsVariants) else { return }
        let engine = PlayerEngine.makeForTesting()
        defer { engine.stop() }
        engine.load(path: path)
        try #require(await engine.waitForPlayback())
        #expect(engine.media.video.width == 640)
        let low = try #require(engine.variants.last)
        var seeks = 0
        engine.onSeekingChanged = { if $0 { seeks += 1 } }

        engine.selectVariant(id: low.id)
        #expect(engine.selectedVariantId == low.id)
        #expect(await engine.waitUntil(timeout: .seconds(4)) { engine.media.video.width == 320 })
        let switchedAt = engine.currentTime
        #expect(await engine.waitUntil(timeout: .seconds(3)) { engine.currentTime > switchedAt + 1 })
        // Read ahead, the switch seeks to the current frame (`PlayerEngine.selectVariant(id:)`).
        #expect(seeks == (PlayerEngine.readsAheadLocalFiles ? 1 : 0))
        #expect(!engine.isBuffering)
        // Read on demand, none. Read ahead, the seek resumes on the host clock and hands it over to the audio's: a frame
        // may come late then (seen, one, with the synthetic stream on macOS 27).
        #expect(engine.pipelineDroppedFramesCount <= (PlayerEngine.readsAheadLocalFiles ? 1 : 0))
    }
}
