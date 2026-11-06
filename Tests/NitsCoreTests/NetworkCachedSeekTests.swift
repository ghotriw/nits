import CoreMedia
import Foundation
import Testing

@testable import NitsCore

@Suite("Network Cached Seek Tests", .serialized, .hostDependent)
struct NetworkCachedSeekTests {
    private static func parseRangeStart(_ rangeHeader: String?) -> Int64? {
        guard let rangeHeader, rangeHeader.hasPrefix("bytes=") else { return nil }
        let spec = rangeHeader.dropFirst("bytes=".count)
        guard let dashIdx = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[..<dashIdx])
    }

    @Test("Seeking backward within cached read-ahead window requires 0 re-downloads")
    func testBackwardInCacheSeek() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))

        // Start read-ahead with 15s forward limit and 20MB back buffer
        demuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))

        // Advance playback cursor to ~10s
        while demuxer.consumedSeconds < 10.0 {
            guard demuxer.nextVideoSample() != nil else { break }
        }

        // Wait until read-ahead reaches limit (10s + 15s = ~25s) and settles
        let deadline = ContinuousClock.now + .seconds(10)
        while demuxer.readAheadSeconds < 24.0 && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(demuxer.readAheadSeconds >= 24.0)

        // Record requests before seek
        let requestsBefore = server.requests
        let maxRequestedOffsetBefore = requestsBefore.compactMap { Self.parseRangeStart($0.range) }.max() ?? 0

        // Seek backward to 5.0 seconds
        let seekSucceeded = demuxer.seekWithinCache(to: 5.0, exact: true)
        #expect(seekSucceeded == true)

        // Read sample immediately after seek
        let sample = try #require(demuxer.nextVideoSample())
        let samplePTS =
            Double(CMSampleBufferGetPresentationTimeStamp(sample).value) * Double(demuxer.timebase.num)
            / Double(demuxer.timebase.den)
        #expect((4.0...5.1).contains(samplePTS), "Sample landed at \(samplePTS)s")

        // Verify that NO new requests were issued for offsets < maxRequestedOffsetBefore
        let requestsAfter = server.requests
        let newRequests = requestsAfter.dropFirst(requestsBefore.count)
        for req in newRequests {
            if let start = Self.parseRangeStart(req.range) {
                #expect(
                    start >= maxRequestedOffsetBefore,
                    "Expected request in forward frontier, got: \(start) < \(maxRequestedOffsetBefore)")
            }
        }
    }

    @Test("Seeking forward within cached read-ahead window satisfies seek from RAM")
    func testForwardInCacheSeek() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))

        demuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))

        // Wait until read-ahead loads up to 15s from beginning
        let deadline = ContinuousClock.now + .seconds(10)
        while demuxer.readAheadSeconds < 14.0 && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(demuxer.readAheadSeconds >= 14.0)

        // Fast-forward seek within the loaded 14s buffer to 8.0s (forward keyframe seek)
        let seekSucceeded = demuxer.seekWithinCache(to: 8.0, exact: false, forward: true)
        #expect(seekSucceeded == true)

        let sample = try #require(demuxer.nextVideoSample())
        let samplePTS =
            Double(CMSampleBufferGetPresentationTimeStamp(sample).value) * Double(demuxer.timebase.num)
            / Double(demuxer.timebase.den)
        #expect(samplePTS >= 8.0, "Sample PTS \(samplePTS)s should be >= 8.0s")
    }

    @Test("Cache miss falls back to slow path and clears stale history")
    func testCacheMissFallbackAndReset() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))

        demuxer.startReadAhead(limits: .init(seconds: 10, bytes: 20 << 20, backBytes: 10 << 20))

        // Read ahead initially reaches ~10s
        let deadline = ContinuousClock.now + .seconds(10)
        while demuxer.readAheadSeconds < 9.0 && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Seek to 28.0s (beyond the 10s buffer) -> in-cache seek must fail
        let fastSeekSucceeded = demuxer.seekWithinCache(to: 28.0)
        #expect(fastSeekSucceeded == false)

        // Slow-path fallback
        let slowSeekSucceeded = demuxer.seek(to: 28.0)
        #expect(slowSeekSucceeded == true)

        // History must be cleared after slow-path seek
        demuxer.readingDescription { d in
            #expect(d.videoQueue.backBytes == 0)
        }
    }

    @Test("Text subtitles are preserved during in-cache seek")
    func testTextSubtitlesPreservedDuringInCacheSeek() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))

        // Select first subtitle track (SRT)
        demuxer.selectSubtitleTrack(trackId: demuxer.subtitleTracks.first?.id)
        #expect(demuxer.selectionOutdatesCache == false, "A file has no rendition to read apart")

        demuxer.startReadAhead(limits: .init(seconds: 3, bytes: 50 << 20, backBytes: 20 << 20))

        // Read packets
        while demuxer.consumedSeconds < 1.5 {
            guard demuxer.nextVideoSample() != nil else { break }
        }
        Thread.sleep(forTimeInterval: 0.1)

        let docBefore = demuxer.getLiveSubtitleDocument()
        #expect(!docBefore.cues.isEmpty, "Subtitle cues should be present before seek")

        // In-cache seek backward
        let seekSucceeded = demuxer.seekWithinCache(to: 0.5, exact: true)
        #expect(seekSucceeded == true)

        let docAfter = demuxer.getLiveSubtitleDocument()
        #expect(docAfter.cues == docBefore.cues, "Subtitle cues must not be duplicated or lost")
    }

    @Test("External separate audio demuxer satisfies in-cache seek from RAM without network re-download")
    func testExternalAudioInCacheSeek() throws {
        guard let videoPath = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264),
            let audioPath = SyntheticTestMediaFactory.ensureMedia(preset: .flashClickAudio)
        else { return }
        let videoURL = URL(fileURLWithPath: videoPath)
        let audioURL = URL(fileURLWithPath: audioPath)
        let server = try TestHTTPServer(root: videoURL.deletingLastPathComponent())
        defer { server.stop() }

        let videoDemuxer = try #require(MediaDemuxer(url: server.url(videoURL.lastPathComponent)))
        let audioDemuxer = try #require(MediaDemuxer(url: server.url(audioURL.lastPathComponent)))

        // Video demuxer: deselect its audio so it acts as video-only (like YouTube video stream)
        videoDemuxer.selectAudioTrack(trackId: nil)
        // Audio demuxer: select its first audio track
        audioDemuxer.selectAudioTrack(trackId: audioDemuxer.audioTracks.first?.id)

        videoDemuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))
        audioDemuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))

        // Advance both past 10 seconds waiting cooperatively for read-ahead
        let videoAdvanceDeadline = ContinuousClock.now + .seconds(5)
        while videoDemuxer.consumedSeconds < 10.0 && ContinuousClock.now < videoAdvanceDeadline {
            if videoDemuxer.nextVideoSample() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let audioAdvanceDeadline = ContinuousClock.now + .seconds(5)
        while audioDemuxer.consumedSeconds < 10.0 && ContinuousClock.now < audioAdvanceDeadline {
            if audioDemuxer.nextAudioPacket() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        // Wait for read ahead
        let deadline = ContinuousClock.now + .seconds(10)
        while (videoDemuxer.readAheadSeconds < 24.0 || audioDemuxer.readAheadSeconds < 24.0)
            && ContinuousClock.now < deadline
        {
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Record requests
        let requestsBefore = server.requests
        let maxVideoOffset =
            requestsBefore.filter { $0.path.contains(videoURL.lastPathComponent) }.compactMap {
                Self.parseRangeStart($0.range)
            }.max() ?? 0
        let maxAudioOffset =
            requestsBefore.filter { $0.path.contains(audioURL.lastPathComponent) }.compactMap {
                Self.parseRangeStart($0.range)
            }.max() ?? 0

        // In-cache seek backward to 5.0 seconds
        let videoSeekSucceeded = videoDemuxer.seekWithinCache(to: 5.0, exact: true)
        #expect(videoSeekSucceeded == true)

        let audioSeekSucceeded = audioDemuxer.seekWithinCache(to: 5.0, exact: true)
        #expect(audioSeekSucceeded == true)

        // Read sample from video demuxer
        let sample = try #require(videoDemuxer.nextVideoSample())
        let samplePTS =
            Double(CMSampleBufferGetPresentationTimeStamp(sample).value) * Double(videoDemuxer.timebase.num)
            / Double(videoDemuxer.timebase.den)
        #expect((4.0...5.1).contains(samplePTS))

        // Read audio packet from audio demuxer
        let audioPkt = try #require(audioDemuxer.nextAudioPacket())
        let audioPTS =
            Double(audioPkt.pts) * Double(audioDemuxer.audioTimebase.num) / Double(audioDemuxer.audioTimebase.den)
        #expect((4.0...5.5).contains(audioPTS))

        // Verify no re-downloaded bytes behind frontier
        let requestsAfter = server.requests
        let newRequests = requestsAfter.dropFirst(requestsBefore.count)
        for req in newRequests {
            if req.path.contains(videoURL.lastPathComponent), let start = Self.parseRangeStart(req.range) {
                #expect(start >= maxVideoOffset)
            }
            if req.path.contains(audioURL.lastPathComponent), let start = Self.parseRangeStart(req.range) {
                #expect(start >= maxAudioOffset)
            }
        }
    }

    @Test("Non-exact keyframe seek aligns audio with landed video keyframe PTS rather than target seconds")
    func testNonExactKeyframeSeekAlignsAudioWithKeyframe() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))
        demuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))

        // Advance playback cursor to ~10s reading both video and audio
        while demuxer.consumedSeconds < 10.0 {
            guard demuxer.nextVideoSample() != nil else { break }
            _ = demuxer.nextAudioPacket()
        }

        // Wait until read-ahead reaches >= 20s
        let deadline = ContinuousClock.now + .seconds(10)
        while demuxer.readAheadSeconds < 20.0 && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Non-exact seek to 7.8s (keyframe interval is ~1-2s in synth media)
        let seekSucceeded = demuxer.seekWithinCache(to: 7.8, exact: false)
        #expect(seekSucceeded == true)

        let sample = try #require(demuxer.nextVideoSample())
        let videoPTS =
            Double(CMSampleBufferGetPresentationTimeStamp(sample).value) * Double(demuxer.timebase.num)
            / Double(demuxer.timebase.den)

        let audioPkt = try #require(demuxer.nextAudioPacket())
        let audioPTS =
            Double(audioPkt.pts) * Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)

        // Audio PTS must match video keyframe PTS (within one packet ~0.1s), NOT target 7.8s!
        #expect(
            abs(audioPTS - videoPTS) < 0.25,
            "Audio PTS (\(audioPTS)) should align with video keyframe PTS (\(videoPTS)), not 7.8s")
    }

    @Test("Seek before buffer start after slow seek misses cache and does not falsely claim hit")
    func testSeekBeforeBufferStartAfterSlowSeekMissesCache() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))
        demuxer.startReadAhead(limits: .init(seconds: 10, bytes: 50 << 20, backBytes: 10 << 20))

        // Slow seek to 15.0s (buffer is emptied and begins at 15.0s)
        demuxer.seek(to: 15.0)

        // Advance to 18.0s
        while demuxer.consumedSeconds < 18.0 {
            guard demuxer.nextVideoSample() != nil else { break }
        }

        // Seek backward to 5.0s (which is NOT in the buffer: buffer starts at >= 15.0s)
        let inCacheSucceeded = demuxer.seekWithinCache(to: 5.0, exact: true)
        #expect(inCacheSucceeded == false, "Seeking to 5.0s must miss cache when buffer only has >= 15.0s")
    }

    @Test("A subtitle rendition selected after the read makes the next seek a slow one, once")
    func testOutdatedSelectionForcesSlowSeekOnce() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))
        demuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))

        let deadline = ContinuousClock.now + .seconds(5)
        while demuxer.consumedSeconds < 10.0 && ContinuousClock.now < deadline {
            if demuxer.nextVideoSample() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let readAheadDeadline = ContinuousClock.now + .seconds(10)
        while demuxer.readAheadSeconds < 22.0 && ContinuousClock.now < readAheadDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(demuxer.readAheadSeconds >= 22.0)

        // Turning subtitles off asks nothing of the packets read.
        demuxer.selectSubtitleTrack(trackId: nil)
        #expect(demuxer.selectionOutdatesCache == false)

        // What `selectSubtitleTrack` sets for an HLS rendition (this file has none).
        demuxer.selectionOutdatesCache = true
        let requestsBefore = server.requests.count
        #expect(demuxer.seekReportingCache(to: 5.0, exact: true).fromCache == false)
        #expect(server.requests.count > requestsBefore, "The input is read again")
        #expect(demuxer.selectionOutdatesCache == false, "Only a seek that reads the input takes it back")
    }

    @Test("Multi-variant streams bypass in-cache seek and allocate 0 backBytes")
    func testMultiVariantStreamBypassesInCacheSeek() throws {
        guard let master = SyntheticTestMediaFactory.ensureMedia(preset: .hlsLadder) else { return }
        let fileURL = URL(fileURLWithPath: master)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))
        #expect(demuxer.variants.count > 1)

        demuxer.startReadAhead(limits: .init(seconds: 4, bytes: 20 << 20, backBytes: 10 << 20))
        #expect(demuxer.readAheadLimits.backBytes == 0, "Multi-variant streams must disable backBytes to save RAM")

        // Advance a bit
        let deadline = ContinuousClock.now + .seconds(5)
        while demuxer.consumedSeconds < 2.0 && ContinuousClock.now < deadline {
            if demuxer.nextVideoSample() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        // Even if requested position is within cached range, seekWithinCache must return false
        let fastSeekSucceeded = demuxer.seekWithinCache(to: 0.5, exact: true)
        #expect(fastSeekSucceeded == false, "Multi-variant streams must not perform in-cache seeks")

        // An HLS rendition selected after the read is read again by the engine: the cache is refused for it.
        demuxer.selectSubtitleTrack(trackId: demuxer.subtitleTracks.first?.id ?? 0)
        #expect(demuxer.selectionOutdatesCache == true)

        // Regular seek should succeed via slow path
        let slowSeekSucceeded = demuxer.seek(to: 0.5)
        #expect(slowSeekSucceeded == true)
        #expect(demuxer.seekReportingCache(to: 0.5).fromCache == false)
    }

    /// A copy of `path` cut to `fraction` of its bytes in a directory of its own: the container still tells the full
    /// duration, and the input ends early with a clean EOF.
    private static func truncatedCopy(of path: String, fraction: Double) throws -> (directory: URL, name: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NitsTruncated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: source)
        try data.prefix(Int(Double(data.count) * fraction)).write(to: directory.appendingPathComponent("cut.mkv"))
        return (directory, "cut.mkv")
    }

    @Test("An EOF before the container's duration is not trusted: a seek in the cache reads again")
    func testEOFBeforeDurationReadsAgain() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let cut = try Self.truncatedCopy(of: path, fraction: 0.4)
        defer { try? FileManager.default.removeItem(at: cut.directory) }
        let server = try TestHTTPServer(root: cut.directory)
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(cut.name)))
        try #require(demuxer.durationSeconds > 10, "The header must still tell the full duration")
        demuxer.startReadAhead(limits: .init(seconds: 600, bytes: 100 << 20, backBytes: 64 << 20))

        let deadline = ContinuousClock.now + .seconds(10)
        while !demuxer.readAheadEnded && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try #require(demuxer.readAheadEnded)
        try #require(demuxer.readAheadHitEOF, "FFmpeg must report the cut as EOF: that is the case under test")
        #expect(demuxer.cachedFrontierSeconds < demuxer.durationSeconds - 1, "The file was cut short")
        let requestsBefore = server.requests.count

        #expect(demuxer.seekReportingCache(to: 1.0).fromCache == false)
        #expect(server.requests.count > requestsBefore, "The slow seek reads the input again")
    }

    @Test("A real EOF keeps serving seeks from the cache")
    func testRealEOFServesSeeksFromCache() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))
        demuxer.startReadAhead(limits: .init(seconds: 600, bytes: 100 << 20, backBytes: 64 << 20))

        let deadline = ContinuousClock.now + .seconds(10)
        while !demuxer.readAheadEnded && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try #require(demuxer.readAheadEnded)
        try #require(demuxer.readAheadHitEOF, "The whole file was read")

        let requestsBefore = server.requests.count
        #expect(demuxer.seekReportingCache(to: 1.0).fromCache == true)
        #expect(demuxer.readAheadEnded, "The end stays: it is the media's")
        #expect(server.requests.count == requestsBefore)
    }

    @Test("An audio-only input keeps its history by size, not by 15 seconds: a seek 19 s back is served from RAM")
    func testAudioOnlyHistoryReachesFarBack() throws {
        guard let audioPath = SyntheticTestMediaFactory.ensureMedia(preset: .flashClickAudio) else { return }
        let audioURL = URL(fileURLWithPath: audioPath)
        let server = try TestHTTPServer(root: audioURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(audioURL.lastPathComponent)))
        demuxer.selectAudioTrack(trackId: demuxer.audioTracks.first?.id)
        demuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))

        let deadline = ContinuousClock.now + .seconds(10)
        while demuxer.consumedSeconds < 22.0 && ContinuousClock.now < deadline {
            if demuxer.nextAudioPacket() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        try #require(demuxer.consumedSeconds >= 22.0)

        let requestsBefore = server.requests.count
        #expect(demuxer.seekReportingCache(to: 3.0, exact: true).fromCache == true)
        #expect(server.requests.count == requestsBefore)
    }

    @Test("An audio track selected while reading: a seek back to what the old track had is a slow one")
    func testAudioTrackChangeMissesCache() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))
        try #require(demuxer.audioTracks.count >= 2)
        demuxer.startReadAhead(limits: .init(seconds: 15, bytes: 50 << 20, backBytes: 20 << 20))

        let deadline = ContinuousClock.now + .seconds(10)
        while demuxer.consumedSeconds < 10.0 && ContinuousClock.now < deadline {
            if demuxer.nextVideoSample() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let readAheadDeadline = ContinuousClock.now + .seconds(10)
        while demuxer.readAheadSeconds < 22.0 && ContinuousClock.now < readAheadDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(demuxer.readAheadSeconds >= 22.0)

        let other = try #require(demuxer.audioTracks.first { $0.id != demuxer.selectedAudioTrackIndex })
        demuxer.selectAudioTrack(trackId: other.id)

        // The new track was not read before the switch: 5 s is video the cache holds and audio it does not.
        let requestsBefore = server.requests.count
        #expect(demuxer.seekReportingCache(to: 5.0, exact: true).fromCache == false)
        #expect(server.requests.count > requestsBefore, "The input is read again")
    }

    @Test("An ended read-ahead that was not an EOF is not trusted, even at the duration")
    func testReadErrorAtDurationIsNotTrusted() throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264) else { return }
        let fileURL = URL(fileURLWithPath: path)
        let server = try TestHTTPServer(root: fileURL.deletingLastPathComponent())
        defer { server.stop() }

        let demuxer = try #require(MediaDemuxer(url: server.url(fileURL.lastPathComponent)))
        demuxer.startReadAhead(limits: .init(seconds: 600, bytes: 100 << 20, backBytes: 64 << 20))

        let deadline = ContinuousClock.now + .seconds(10)
        while !demuxer.readAheadEnded && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try #require(demuxer.readAheadEnded)
        try #require(demuxer.readAheadHitEOF, "The whole file was read")

        // What a read error in the last second leaves: ended, the cache at the duration, but not at an EOF. The thread
        // has stopped, so nothing races the flag.
        demuxer.readAheadHitEOF = false
        #expect(demuxer.seekWithinCache(to: 1.0) == false)
    }
}
