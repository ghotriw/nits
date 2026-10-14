import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import NitsCore

/// Detects audible artifacts (crackle/clicks) at the decoder output level:
/// timestamp gaps/overlaps between consecutive buffers, NaN/Inf samples and sample discontinuities.
@Suite("Audio Output Continuity Tests", .serialized)
struct AudioContinuityTests {

    struct Report {
        var buffers = 0
        var ptsGaps = 0
        var maxPtsErrorSamples = 0.0
        var badSamples = 0
        var clicks = 0
        var peak: Float = 0
    }

    /// Decodes up to `maxPackets` packets of the given track and analyzes the PCM output.
    static func analyze(path: String, trackId: Int, maxPackets: Int = 400) -> (Report, String)? {
        guard let demuxer = MediaDemuxer(url: path) else { return nil }
        demuxer.selectAudioTrack(trackId: trackId)
        guard let params = demuxer.getAudioCodecParameters(),
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
        else { return nil }

        var report = Report()
        var expectedPts: Double?
        var lastSample: [Float] = []
        let rate = 48000.0

        for _ in 0..<maxPackets {
            guard let pkt = demuxer.nextAudioPacket() else { break }
            for sb in decoder.decode(packetData: pkt.data, pts: pkt.pts, timebase: demuxer.audioTimebase) {
                report.buffers += 1
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                let n = CMSampleBufferGetNumSamples(sb)
                if let e = expectedPts {
                    let errSamples = abs(pts - e) * rate
                    report.maxPtsErrorSamples = max(report.maxPtsErrorSamples, errSamples)
                    if errSamples > 1.5 { report.ptsGaps += 1 }
                }
                expectedPts = pts + Double(n) / rate

                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                let channels = max(1, length / max(1, n) / 4)
                data.withUnsafeBytes { raw in
                    let f = raw.bindMemory(to: Float.self)
                    if lastSample.count != channels { lastSample = [Float](repeating: 0, count: channels) }
                    for i in 0..<n {
                        for c in 0..<channels {
                            let v = f[i * channels + c]
                            if !v.isFinite {
                                report.badSamples += 1
                                continue
                            }
                            report.peak = max(report.peak, abs(v))
                            if abs(v - lastSample[c]) > 0.5 { report.clicks += 1 }
                            lastSample[c] = v
                        }
                    }
                }
            }
        }
        let desc = String(describing: String(cString: avcodec_get_name(params.pointee.codec_id)))
        return (report, desc)
    }

    @Test("Every audio track decodes with gap-free timestamps and no clicks")
    func testSyntheticTracksContinuity() {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .exoticAudioTracks),
            let demuxer = MediaDemuxer(url: path)
        else { return }
        for track in demuxer.audioTracks {
            guard let (r, codec) = Self.analyze(path: path, trackId: track.id) else {
                Issue.record("Cannot analyze track \(track.id)")
                continue
            }
            print("[Continuity] track \(track.id) \(codec): \(r)")
            #expect(r.buffers > 0)
            #expect(r.ptsGaps == 0, "PTS gaps/overlaps in \(codec) track \(track.id): \(r)")
            #expect(r.badSamples == 0)
            #expect(r.clicks == 0, "Sample discontinuities in \(codec) track \(track.id): \(r)")
        }
    }

    @Test("Undelivered output stashed on pause is returned in order and dropped by a flush")
    func testUndeliveredOutputSurvivesPauseButNotFlush() {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .exoticAudioTracks),
            let demuxer = MediaDemuxer(url: path),
            let track = demuxer.audioTracks.first
        else { return }
        demuxer.selectAudioTrack(trackId: track.id)
        guard let params = demuxer.getAudioCodecParameters(),
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
        else {
            Issue.record("Cannot create audio decoder")
            return
        }

        var decoded: [CMSampleBuffer] = []
        while decoded.count < 4, let pkt = demuxer.nextAudioPacket() {
            decoded += decoder.decode(packetData: pkt.data, pts: pkt.pts, timebase: demuxer.audioTimebase)
        }
        #expect(decoded.count >= 4)

        // Pause: the feeder delivered the first buffer and stashes the rest for the next run.
        let generation = decoder.generation
        decoder.stashUndelivered(decoded.dropFirst(), generation: generation)
        let resumed = decoder.takeUndelivered()
        #expect(
            resumed.map(CMSampleBufferGetPresentationTimeStamp)
                == decoded.dropFirst().map(CMSampleBufferGetPresentationTimeStamp))
        #expect(decoder.takeUndelivered().isEmpty)

        // Seek: a flush drops the stash, and a run that decoded before the flush cannot re-stash afterwards.
        decoder.stashUndelivered(decoded[...], generation: generation)
        decoder.flush()
        #expect(decoder.takeUndelivered().isEmpty)
        decoder.stashUndelivered(decoded[...], generation: generation)
        #expect(decoder.takeUndelivered().isEmpty)
    }

    /// Manual diagnostic: AUDIO_DIAG_PATH=/path/to/file.mkv swift test --filter testExternalFileContinuity
    @Test("External file continuity (only when AUDIO_DIAG_PATH is set)")
    func testExternalFileContinuity() {
        guard let path = ProcessInfo.processInfo.environment["AUDIO_DIAG_PATH"],
            let demuxer = MediaDemuxer(url: path)
        else { return }
        for track in demuxer.audioTracks {
            guard let (r, codec) = Self.analyze(path: path, trackId: track.id, maxPackets: 1500) else { continue }
            print("[Continuity] track \(track.id) \(codec): \(r)")
            #expect(r.ptsGaps == 0)
            #expect(r.badSamples == 0)
        }
    }
}
