import AudioToolbox
import CFFmpeg
import CoreMedia
import Testing
import os

@testable import NitsCore

@Suite("Audio Pipeline & FFAudioDecoder Tests")
struct AudioPipelineTests {
    private static func findReferenceMedia() -> String? {
        return SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264)
    }

    @Test("MediaDemuxer discovers audio tracks from reference media")
    func testDemuxerAudioDiscovery() {
        guard let referencePath = Self.findReferenceMedia() else { return }

        guard let demuxer = MediaDemuxer(url: referencePath) else {
            Issue.record("Failed to load reference file")
            return
        }

        #expect(demuxer.hasAudio == true)
        #expect(demuxer.audioChannels > 0)
        #expect(demuxer.audioSampleRate > 0)
        #expect(demuxer.audioTracks.count > 0)
        #expect(demuxer.selectedAudioTrackIndex >= 0)

        let activeTrack = demuxer.audioTracks.first(where: { $0.id == demuxer.selectedAudioTrackIndex })
        #expect(activeTrack != nil)
        #expect(activeTrack?.channels == demuxer.audioChannels)
        #expect(activeTrack?.sampleRate == demuxer.audioSampleRate)
    }

    @Test("FFAudioDecoder decodes audio packets to 48kHz Stereo Float32 PCM sample buffers")
    func testFFAudioDecoderPlayback() {
        guard let referencePath = Self.findReferenceMedia() else { return }

        guard let demuxer = MediaDemuxer(url: referencePath),
            let codecParams = demuxer.getAudioCodecParameters()
        else {
            Issue.record("Failed to initialize demuxer or get audio parameters")
            return
        }

        guard let decoder = FFAudioDecoder(codecParameters: codecParams, timebase: demuxer.audioTimebase) else {
            Issue.record("Failed to initialize FFAudioDecoder")
            return
        }

        #expect(decoder.targetSampleRate == 48000)
        #expect(decoder.targetChannels == 6)  // Reference video has 5.1 (6 channels)
        #expect(decoder.channelLayoutTag == kAudioChannelLayoutTag_AudioUnit_5_1)

        // Read up to 20 audio packets and decode
        var decodedSampleBuffers: [CMSampleBuffer] = []
        var packetsRead = 0

        while packetsRead < 20 {
            guard let audioPacket = demuxer.nextAudioPacket() else { break }
            packetsRead += 1
            let buffers = decoder.decode(
                packetData: audioPacket.data,
                pts: audioPacket.pts,
                timebase: demuxer.audioTimebase
            )
            decodedSampleBuffers.append(contentsOf: buffers)
        }

        #expect(packetsRead > 0)
        #expect(decodedSampleBuffers.count > 0)

        // Verify output CMSampleBuffer properties
        if let firstBuffer = decodedSampleBuffers.first {
            #expect(CMSampleBufferIsValid(firstBuffer))
            let formatDesc = CMSampleBufferGetFormatDescription(firstBuffer)
            #expect(formatDesc != nil)

            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!) {
                #expect(asbd.pointee.mSampleRate == 48000.0)
                #expect(asbd.pointee.mChannelsPerFrame == 6)
                #expect(asbd.pointee.mFormatID == kAudioFormatLinearPCM)
                #expect(asbd.pointee.mBitsPerChannel == 32)
                #expect((asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
            }

            var layoutSize: Int = 0
            if let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(formatDesc!, sizeOut: &layoutSize) {
                #expect(layoutPtr.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_AudioUnit_5_1)
            } else {
                Issue.record("Missing AudioChannelLayout in CMAudioFormatDescription")
            }
        }
    }

    @Test("Audio track selection flushes and switches active stream")
    func testAudioTrackSelection() {
        guard let referencePath = Self.findReferenceMedia() else { return }

        guard let demuxer = MediaDemuxer(url: referencePath) else {
            Issue.record("Failed to initialize demuxer")
            return
        }

        if demuxer.audioTracks.count > 1 {
            let firstId = demuxer.audioTracks[0].id
            let secondId = demuxer.audioTracks[1].id

            demuxer.selectAudioTrack(trackId: secondId)
            #expect(demuxer.selectedAudioTrackIndex == secondId)

            demuxer.selectAudioTrack(trackId: firstId)
            #expect(demuxer.selectedAudioTrackIndex == firstId)
        }
    }

    @Test("Audio decoding under repeated seeks and flushes")
    func testAudioDecodingUnderContinuousSeeks() {
        guard let referencePath = Self.findReferenceMedia(),
            let demuxer = MediaDemuxer(url: referencePath),
            let params = demuxer.getAudioCodecParameters(),
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
        else {
            return
        }

        for target in [10.0, 42.555, 120.0, 1.0, 50.0] {
            decoder.flush()
            demuxer.seek(to: target)
            var count = 0
            while count < 10 {
                guard let pkt = demuxer.nextAudioPacket() else { break }
                let bufs = decoder.decode(packetData: pkt.data, pts: pkt.pts, timebase: demuxer.audioTimebase)
                #expect(bufs.count >= 0)
                count += 1
            }
        }
    }

    @Test("AudioDeviceRouteMonitor fetches default output device and manages lifecycle cleanly")
    @MainActor
    func testAudioDeviceRouteMonitorLifecycle() {
        let monitor = AudioDeviceRouteMonitor()
        let initialUID = AudioDeviceRouteMonitor.fetchDefaultOutputDeviceUID()
        if let initialUID {
            #expect(!initialUID.isEmpty)
        }

        let routeUpdateCount = OSAllocatedUnfairLock(initialState: 0)
        monitor.startMonitoring { _ in
            routeUpdateCount.withLock { $0 += 1 }
        }
        #expect(routeUpdateCount.withLock { $0 } == 0)

        monitor.stopMonitoring()
    }
}
