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

@Suite("HLS variant playback", .serialized, .realtimePlayback, .timeLimit(.minutes(1)))
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
        #expect(engine.pipelineDroppedFramesCount == 0)
    }
}
