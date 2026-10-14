import AVFoundation
import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

@Suite("Playback Stress & Reliability Tests", .serialized)
struct PlaybackStressTests {

    private static func findTestMedia() -> String? {
        return SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264)
    }

    @MainActor
    private static func makeEngine() -> PlayerEngine {
        let config = PlayerConfiguration(resumePlayback: false)
        return PlayerEngine.makeForTesting(configuration: config)
    }

    // MARK: - 1. Rapid Scrubbing Chaos Test
    @Test("Rapid scrub chaos test does not hang or deadlock the engine")
    @MainActor
    func testRapidScrubbingBurst() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        #expect(engine.duration > 0.0)

        let duration = engine.duration
        let maxSeek = min(duration - 2.0, 120.0)
        guard maxSeek > 5.0 else {
            engine.stop()
            return
        }

        // Fire 15 rapid random seek calls with burst intervals between 10ms and 50ms
        var target: Double = 0.0
        for _ in 0..<15 {
            target = Double.random(in: 1.0...maxSeek)
            engine.seek(to: target)
            try? await Task.sleep(nanoseconds: UInt64.random(in: 10_000_000...50_000_000))
        }

        // Final settling seek
        let finalTarget = 15.0
        engine.seek(to: finalTarget)

        // Wait for asynchronous seek pipeline to settle
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2.0s

        print("[Test] Settled currentTime:", engine.currentTime, "expected:", finalTarget)
        #expect(engine.isLoaded == true)
        #expect(abs(engine.currentTime - finalTarget) <= 3.0)

        // Ensure engine is responsive and can resume playing cleanly after scrub burst
        engine.play()
        #expect(engine.isPlaying == true)
        #expect(engine.playbackState == .playing)

        try? await Task.sleep(nanoseconds: 200_000_000)
        engine.pause()
        #expect(engine.isPlaying == false)

        engine.stop()
    }

    // MARK: - 1b. Rapid Relative Seeks During Active Playback
    @Test("Rapid sequential relative seeks during active playback maintain playing state without pausing")
    @MainActor
    func testRapidRelativeSeeksDuringActivePlayback() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        #expect(engine.duration > 20.0)

        engine.play()
        #expect(engine.isPlaying == true)
        #expect(engine.playbackState == .playing)

        // Simulate user repeatedly hitting forward (+5s) in rapid succession
        let initialTime = engine.currentTime
        engine.seekRelative(by: 5.0)
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        engine.seekRelative(by: 5.0)
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        engine.seekRelative(by: 5.0)

        // Wait for the asynchronous seek pipeline to finish and settle
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2.0s

        #expect(engine.isPlaying == true, "Engine must resume playing after rapid forward seeks")
        #expect(engine.playbackState == .playing, "Playback state must remain .playing")
        #expect(engine.currentTime >= initialTime + 10.0, "Current time must have advanced by cumulative seek steps")

        engine.stop()
    }

    // MARK: - 1c. Rapid Backward Relative Seeks During Active Playback
    @Test("Rapid sequential backward relative seeks maintain playing state and settle smoothly")
    @MainActor
    func testRapidBackwardRelativeSeeksDuringActivePlayback() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        #expect(engine.duration > 20.0)

        // Seek forward to 18 seconds first so we have room to seek backward
        engine.seek(to: 18.0)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        engine.play()
        #expect(engine.isPlaying == true)
        #expect(engine.playbackState == .playing)

        let initialTime = engine.currentTime
        // Rapid sequential backward seeks: -4s, -4s, -4s = -12s total
        engine.seekRelative(by: -4.0)
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        engine.seekRelative(by: -4.0)
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        engine.seekRelative(by: -4.0)

        // Wait for asynchronous chase seek pipeline to settle
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2.0s

        #expect(engine.isPlaying == true, "Engine must resume playing after rapid backward seeks")
        #expect(engine.playbackState == .playing, "Playback state must remain .playing")
        #expect(
            engine.currentTime <= initialTime - 8.0, "Current time must have moved backward by cumulative seek steps")

        engine.stop()
    }

    // MARK: - 1d. Rapid Chase Seek Burst While In-Flight Does Not Deadlock
    @Test("Rapid chase seek burst while demuxer seek is in flight settles cleanly and resumes playback")
    @MainActor
    func testRapidChaseSeekBurstWhileInFlightDoesNotDeadlock() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        #expect(engine.duration > 20.0)

        engine.play()
        #expect(engine.isPlaying == true)
        #expect(engine.playbackState == .playing)

        // Wait for playback and feeders to start
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Trigger first seek
        engine.seekRelative(by: 5.0)

        // Wait past the 75ms debounce window so demuxer seek starts on background seekQueue and isSeeking becomes true
        try? await Task.sleep(nanoseconds: 90_000_000)  // 90ms

        // Trigger second seek while first demuxer seek is actively in-flight
        engine.seekRelative(by: 5.0)

        // Wait for chase seek sequence to fully settle
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2.0s

        #expect(engine.isPlaying == true, "Engine must resume playback after in-flight chase seek")
        #expect(engine.playbackState == .playing, "Playback state must be .playing")

        // Record time and verify that the clock and playback are actively advancing (no freeze)
        let timeAfterSeek = engine.currentTime
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        #expect(engine.currentTime > timeAfterSeek, "Playback clock must continue advancing after chase seek settles")

        // Verify pause and play responsiveness
        engine.pause()
        #expect(engine.isPlaying == false)
        #expect(engine.playbackState == .paused)

        engine.play()
        #expect(engine.isPlaying == true)
        #expect(engine.playbackState == .playing)

        engine.stop()
    }

    @Test("Continuous video decoding delivers unique changing frames without video freeze")
    func testContinuousVideoDecodingFrameVariation() {
        guard let path = Self.findTestMedia() else { return }
        guard let demuxer = MediaDemuxer(url: path), demuxer.hasVideo else { return }

        let decoder = VTVideoDecoder()
        let hashesLock = OSAllocatedUnfairLock(initialState: [UInt64]())

        decoder.setOutputHandler { frame in
            guard !frame.doNotDisplay else { return }
            let h = PixelBufferAnalyzer.computeSamplingHash(of: frame.pixelBuffer, sampleStep: 32)
            hashesLock.withLock { list in
                list.append(h)
            }
        }

        // Decode 35 non-preroll frames from demuxer
        var decodedSamples = 0
        while decodedSamples < 40 {
            guard let sample = demuxer.nextVideoSample() else { break }
            decoder.decode(sampleBuffer: sample)
            decodedSamples += 1
        }
        decoder.flush()

        let hashes = hashesLock.withLock { $0 }
        #expect(hashes.count >= 10, "Decoder must successfully decode at least 10 valid video frames")

        // In active video, distinct frames must exhibit variety (not 100% duplicates)
        let uniqueHashes = Set(hashes)
        #expect(
            uniqueHashes.count > 1, "Decoded stream must produce distinct visual frames rather than a frozen duplicate")
    }

    // MARK: - 3. Rapid Concurrent Play/Pause/Seek Race Conditions
    @Test("Rapid concurrent playback controls maintain state invariants")
    @MainActor
    func testConcurrentPlaybackControlsRace() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        for i in 0..<10 {
            if i % 2 == 0 {
                engine.play()
            } else {
                engine.pause()
            }
            engine.seek(to: Double(i * 3))
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
        }

        try? await Task.sleep(nanoseconds: 400_000_000)
        engine.pause()
        #expect(engine.isPlaying == false)
        #expect(engine.playbackState == .paused)

        engine.stop()
        #expect(engine.isLoaded == false)
        #expect(engine.playbackState == .idle)
    }

    // MARK: - 4. Rapid Audio Track Switching Under Load
    @Test("Audio track switching under active playback does not hang engine")
    @MainActor
    func testAudioTrackSwitchingUnderPlayback() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        let tracks = engine.audioTracks
        guard tracks.count > 1 else {
            engine.stop()
            return
        }

        engine.play()
        #expect(engine.isPlaying == true)

        // Switch tracks rapidly back and forth
        for _ in 0..<4 {
            for track in tracks {
                engine.selectAudioTrack(id: track.id)
                #expect(engine.selectedAudioTrackId == track.id)
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            }
        }

        #expect(engine.isPlaying == true)
        engine.pause()
        #expect(engine.isPlaying == false)
        engine.stop()
    }
}

extension PlaybackStressTests {
    // MARK: - 5. Exotic Audio Codecs (AC3 fltp / DTS / FLAC s16) Switching
    @Test("Switching between AC3, DTS and 16-bit FLAC tracks under playback does not hang or crash")
    @MainActor
    func testExoticAudioCodecSwitching() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .exoticAudioTracks) else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        #expect(engine.audioTracks.count == 3)

        engine.play()
        for _ in 0..<3 {
            for track in engine.audioTracks {
                engine.selectAudioTrack(id: track.id)
                #expect(engine.selectedAudioTrackId == track.id)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        engine.seek(to: 5.0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(engine.isPlaying == true)
        engine.stop()
    }

    // MARK: - 6. Sustained Backward Key-Hold Monotonicity Test
    @Test("Holding backward seek key produces monotonic non-increasing time values without forward rollbacks")
    @MainActor
    func testSustainedBackwardSeekMonotonicity() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        #expect(engine.duration >= 50.0)

        // Start playing from 45.0 seconds and wait for initial position to be stable
        engine.seek(to: 45.0)
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1.0s to fully settle initial seek

        engine.play()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(engine.isPlaying == true, "Engine should be playing prior to seek burst")

        var seekBurstTrajectory: [Double] = [engine.currentTime]
        var allTimeUpdates: [Double] = [engine.currentTime]
        engine.onTimeUpdate = { time, _ in
            allTimeUpdates.append(time)
        }

        var renderedFramePTS: [Double] = []
        let initialPts = engine.currentFramePTS
        if initialPts >= 0 {
            renderedFramePTS.append(initialPts)
        }

        // Simulate user holding the 'Left Arrow' key while video was playing (15 repeats at irregular 30-70ms intervals)
        for _ in 1...15 {
            engine.seekRelative(by: -2.0)
            seekBurstTrajectory.append(engine.currentTime)
            allTimeUpdates.append(engine.currentTime)
            let fPts = engine.currentFramePTS
            if fPts >= 0 { renderedFramePTS.append(fPts) }

            let interval = UInt64.random(in: 30_000_000...70_000_000)
            try? await Task.sleep(nanoseconds: interval)

            seekBurstTrajectory.append(engine.currentTime)
            allTimeUpdates.append(engine.currentTime)
            let fPts2 = engine.currentFramePTS
            if fPts2 >= 0 { renderedFramePTS.append(fPts2) }
        }

        print("[SeekMonotonicityTest] Seek burst trajectory: \(seekBurstTrajectory)")
        print("[SeekMonotonicityTest] All observed time updates: \(allTimeUpdates)")
        print("[SeekMonotonicityTest] Rendered frame PTS list: \(renderedFramePTS)")

        // 1. Verify Monotonicity during the active seek burst:
        // While user holds the arrow key, time must NEVER rebound or jump forward!
        for k in 1..<allTimeUpdates.count {
            let prev = allTimeUpdates[k - 1]
            let curr = allTimeUpdates[k]
            #expect(
                curr <= prev + 0.05,
                "Violation: Time jumped forward during active backward seek burst from \(prev) to \(curr) (step \(k))")
        }

        // 2. Verify Rendered Frame PTS Monotonicity:
        // Decoded video frames displayed on screen must also not jump forward in time!
        for k in 1..<renderedFramePTS.count {
            let prev = renderedFramePTS[k - 1]
            let curr = renderedFramePTS[k]
            #expect(
                curr <= prev + 0.05,
                "Violation: Displayed video frame jumped forward during backward seek from \(prev) to \(curr) (frame step \(k))"
            )
        }

        // 3. Wait for seek burst to settle and playback to resume naturally
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(engine.isPlaying == true, "Engine should resume playback after seek burst settles")

        engine.stop()
    }

    // MARK: - 7. Keyframe-Aligned Relative Seek Test (IINA / mpv style)
    @Test("Relative seek aligns strictly to keyframe PTS without decoding intermediate P/B frames")
    @MainActor
    func testKeyframeAlignedRelativeSeek() async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .wideGOPH264) else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        // Settle at 0.0s
        engine.seek(to: 0.0, exact: true)
        _ = await engine.waitUntil { !engine.isSeeking && engine.currentFramePTS >= 0 }

        // GOP is strictly 5.0s (keyframes at 0.0, 5.0, 10.0, 15.0, etc.)
        // Seek forward by 5.0s using keyframe seek (exact: false). Polling instead of a fixed wait keeps the
        // assertions strict while tolerating slow decoding under load; a wrong landing still times out.
        engine.seekRelative(by: 5.0, exact: false)
        _ = await engine.waitUntil { abs(engine.currentFramePTS - 5.0) < 0.25 && abs(engine.currentTime - 5.0) < 0.25 }

        let pts1 = engine.currentFramePTS
        print("[KeyframeSeekTest] First keyframe seek landed at frame PTS: \(pts1), currentTime: \(engine.currentTime)")
        // Must align closely to the 5.0s keyframe
        #expect(abs(pts1 - 5.0) < 0.25, "Expected keyframe seek near 5.0s, got \(pts1)")
        #expect(abs(engine.currentTime - 5.0) < 0.25, "Expected currentTime near 5.0s, got \(engine.currentTime)")

        // Seek forward by another 5.0s using keyframe seek (exact: false)
        engine.seekRelative(by: 5.0, exact: false)
        _ = await engine.waitUntil {
            abs(engine.currentFramePTS - 10.0) < 0.25 && abs(engine.currentTime - 10.0) < 0.25
        }

        let pts2 = engine.currentFramePTS
        print(
            "[KeyframeSeekTest] Second keyframe seek landed at frame PTS: \(pts2), currentTime: \(engine.currentTime)")
        // Must align closely to the 10.0s keyframe
        #expect(abs(pts2 - 10.0) < 0.25, "Expected keyframe seek near 10.0s, got \(pts2)")
        #expect(abs(engine.currentTime - 10.0) < 0.25, "Expected currentTime near 10.0s, got \(engine.currentTime)")

        // Now seek backward by 5.0s
        engine.seekRelative(by: -5.0, exact: false)
        _ = await engine.waitUntil { abs(engine.currentFramePTS - 5.0) < 0.25 && abs(engine.currentTime - 5.0) < 0.25 }

        let pts3 = engine.currentFramePTS
        print(
            "[KeyframeSeekTest] Backward keyframe seek landed at frame PTS: \(pts3), currentTime: \(engine.currentTime)"
        )
        #expect(abs(pts3 - 5.0) < 0.25, "Expected backward keyframe seek near 5.0s, got \(pts3)")
        #expect(
            abs(engine.currentTime - 5.0) < 0.25, "Expected backward currentTime near 5.0s, got \(engine.currentTime)")

        engine.stop()
    }

    // MARK: - 11. Stale Clock Settling & Reload Regression Test
    @Test("Reloading media after active playback resets clock and does not drop initial video frames")
    @MainActor
    func testStaleClockSettlingOnReload() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        // Play until the synchronizer clock is well past 0.0s
        engine.play()
        #expect(await engine.waitForClock(toPass: 1.0), "Clock did not advance past 1.0s")

        // Reload the same media (simulating playlist track advancement or restart)
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        // Play again; the clock must restart from 0.0s, not continue from the previous run (stale clock ≥ 1.0s)
        engine.play()
        #expect(await engine.waitForClock(toPass: 0.0), "Clock did not start after reload")
        let restartedAt = engine.synchronizer.currentTime().seconds
        #expect(restartedAt < 0.3, "Clock resumed from the previous run at \(restartedAt)s")
        try? await Task.sleep(nanoseconds: 500_000_000)

        // With ClockSettlingGuard in place, the engine must NOT discard a burst of frames.
        // (At most 1-2 frames may be skipped due to display VSYNC vs media cadence quantization).
        #expect(engine.droppedFramesCount <= 2, "Stale clock caused frame drop burst: \(engine.droppedFramesCount)")
        #expect(engine.isPlaying == true)
        #expect(
            engine.currentTime >= 0.2 && engine.currentTime <= 1.5,
            "Expected currentTime progressing near 0.0s, got \(engine.currentTime)")

        engine.stop()
    }

    // MARK: - 12. Backward Seek to Beginning Under Active Playback
    @Test("Seeking to beginning from deep playback position settles cleanly without dropping frames")
    @MainActor
    func testBackwardSeekToBeginningUnderPlayback() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        // Seek forward deep into media
        engine.seek(to: 10.0, exact: true)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        engine.play()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(engine.currentTime >= 9.0)

        // Seek backward to 0.0s while playing (equivalent to ⌘← shortcut); wait until the clock runs from there
        engine.seek(to: 0.0, exact: true)
        // Right after the seek the clock still reads the old ~11s; the chase seek restarts it near 0.0s.
        _ = await engine.waitUntil {
            let clock = engine.synchronizer.currentTime().seconds
            return clock > 0.2 && clock < 9.0
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Must settle close to 0.0s and resume smoothly without frame bursts
        #expect(
            engine.droppedFramesCount <= 2,
            "Stale clock caused frame drop burst on backward seek: \(engine.droppedFramesCount)")
        #expect(
            engine.currentTime >= 0.2 && engine.currentTime <= 2.0,
            "Expected currentTime progressing near 0.0s, got \(engine.currentTime)")
        #expect(engine.isPlaying == true)

        engine.stop()
    }

    // MARK: - 13. Playback Start Preroll
    /// Samples the master clock every 20ms and reports whether it never moved backwards.
    @MainActor
    private static func isClockMonotonic(_ engine: PlayerEngine, samples: Int) async -> Bool {
        var previous = engine.synchronizer.currentTime().seconds
        var isMonotonic = true
        for _ in 0..<samples {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let now = engine.synchronizer.currentTime().seconds
            if now < previous { isMonotonic = false }
            previous = now
        }
        return isMonotonic
    }

    @Test("Starting playback right after load does not drop the leading video frames")
    @MainActor
    func testPlaybackStartPrerollDoesNotDropLeadingFrames() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        // The clock must stay anchored at 0.0 until the first decoded frame is on screen; if it ran while the
        // first frame was still decoding, the display link would discard the leading frames as late.
        engine.play()
        let isMonotonic = await Self.isClockMonotonic(engine, samples: 40)

        #expect(
            engine.pipelineDroppedFramesCount == 0,
            "Leading frames dropped at playback start: \(engine.pipelineDroppedFramesCount)")
        #expect(engine.isPlaying == true)
        #expect(isMonotonic, "Clock moved backwards after playback start")
        #expect(await engine.waitForClock(toPass: 0.0), "Clock never started after preroll")

        engine.stop()
    }

    // MARK: - 14. Pause / Resume Clock Continuity
    @Test("Resuming after pause continues playback without dropping queued frames")
    @MainActor
    func testResumeAfterPauseDoesNotDropQueuedFrames() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        engine.play()
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        for cycle in 0..<3 {
            engine.pause()
            try? await Task.sleep(nanoseconds: 600_000_000)
            let pausedClock = engine.synchronizer.currentTime().seconds
            let droppedBefore = engine.pipelineDroppedFramesCount

            engine.play()
            let isMonotonic = await Self.isClockMonotonic(engine, samples: 30)

            #expect(isMonotonic, "Cycle \(cycle): clock moved backwards after resume")
            #expect(
                await engine.waitForClock(toPass: pausedClock),
                "Cycle \(cycle): clock did not resume from \(pausedClock)s")
            // A single skipped VSYNC tick under heavy parallel test load may replace one frame; a clock leap drops 2+.
            #expect(
                engine.pipelineDroppedFramesCount - droppedBefore <= 1,
                "Cycle \(cycle): frames dropped after resume: \(engine.pipelineDroppedFramesCount - droppedBefore)")
        }

        engine.stop()
    }

    // MARK: - 15. Mid-GOP Start Position (resume from history / explicit start time)
    @Test("Starting playback mid-GOP never presents or drops reordered pre-target B-frames")
    @MainActor
    func testMidGOPStartDoesNotDropPreTargetFrames() async {
        guard let path = Self.findTestMedia() else { return }

        // 24-frame GOPs with B-frames: 5.5s lands half-way between keyframes, so after the exact seek the decoder
        // emits B-frames that present before the target although they follow a post-target frame in decode order.
        let startTime = 5.5
        let halfFrame = 0.5 / 24.0
        let engine = Self.makeEngine()
        engine.load(MediaLoadRequest(path: path, startTime: startTime))
        engine.play()

        var firstPresentedPts = -1.0
        for _ in 0..<100 where firstPresentedPts < 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            firstPresentedPts = engine.frameQueue.getLastRenderedPTS()
        }
        let isMonotonic = await Self.isClockMonotonic(engine, samples: 30)

        #expect(
            firstPresentedPts >= startTime - halfFrame,
            "Pre-target frame presented at \(firstPresentedPts)s for start \(startTime)s")
        // Leaked pre-target B-frames drop 2+ at once; tolerate one skipped VSYNC tick under parallel test load.
        #expect(
            engine.pipelineDroppedFramesCount <= 1,
            "Pre-target frames reached the queue and were dropped: \(engine.pipelineDroppedFramesCount)")
        #expect(engine.isPlaying == true)
        #expect(isMonotonic, "Clock moved backwards after mid-GOP start")
        #expect(await engine.waitForClock(toPass: startTime), "Clock did not start from \(startTime)s")

        engine.stop()
    }
}
