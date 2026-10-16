import AVFoundation
import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

@Suite("Playback Stress & Reliability Tests", .serialized, .realtimePlayback)
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
        #expect(await engine.waitForSeekToSettle(), "Scrub burst never settled")

        #expect(engine.isLoaded == true)
        #expect(abs(engine.currentTime - finalTarget) <= 3.0, "Settled at \(engine.currentTime)s")

        // Ensure engine is responsive and can resume playing cleanly after scrub burst
        engine.play()
        #expect(engine.isPlaying == true)
        #expect(engine.playbackState == .playing)
        #expect(await engine.waitForPlayback(), "Playback did not run after the scrub burst")

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
        #expect(await engine.waitForPlayback(), "Playback did not resume after rapid forward seeks")

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
        #expect(await engine.waitForSeekToSettle())

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
        #expect(await engine.waitForPlayback(), "Playback did not resume after rapid backward seeks")

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

        #expect(await engine.waitForPlayback(), "Playback did not start")

        // The demuxer seek runs on seekQueue and reports back on the main actor, so it is still in flight when the
        // second seek arrives in the same main-actor turn.
        engine.seekRelative(by: 5.0)
        #expect(engine.isSeeking)
        engine.seekRelative(by: 5.0)

        #expect(await engine.waitForPlayback(), "Playback did not resume after the in-flight chase seek")
        #expect(engine.isPlaying == true, "Engine must resume playback after in-flight chase seek")
        #expect(engine.playbackState == .playing, "Playback state must be .playing")

        // Verify that the clock and playback keep advancing (no freeze)
        let timeAfterSeek = engine.currentTime
        #expect(
            await engine.waitUntil { engine.currentTime > timeAfterSeek + 0.2 },
            "Playback clock must continue advancing after chase seek settles")

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

        #expect(await engine.waitForSeekToSettle(), "Seeks never settled after the control race")
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
        #expect(await engine.waitForPlayback(), "Playback did not resume after switching codecs and seeking")
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

        // Start playing from 45.0 seconds
        engine.seek(to: 45.0)
        #expect(await engine.waitForSeekToSettle())
        engine.play()
        #expect(await engine.waitForPlayback(), "Engine should be playing prior to seek burst")

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

        // 3. Playback must resume once the burst settles
        #expect(await engine.waitForPlayback(), "Engine should resume playback after seek burst settles")

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
        #expect(await engine.waitForClock(toPass: 0.5))

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

        // Seek deep into the media; load autoplays, so playback resumes from there.
        engine.seek(to: 10.0, exact: true)
        #expect(await engine.waitUntil { !engine.isSeeking && engine.pendingSeekTime == nil && engine.isPlaying })
        #expect(await engine.waitForClock(toPass: 10.5), "Clock did not run from the seek target")

        // Seek backward to 0.0s while playing (equivalent to ⌘← shortcut). The seek resets the drop counter.
        engine.seek(to: 0.0, exact: true)
        #expect(await engine.waitUntil { !engine.isSeeking && engine.pendingSeekTime == nil && engine.isPlaying })
        // From the moment playback resumes the clock must read the new position. A stale ~11s reading (the
        // synchronizer keeps it until the audio device restarts) makes the display link drop every frame from 0s.
        var staleReadings: [Double] = []
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let clock = engine.synchronizer.currentTime().seconds
            if clock > 2.0 { staleReadings.append(clock) }
            if clock > 0.5 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(staleReadings.isEmpty, "Clock read the pre-seek position after resuming: \(staleReadings)")

        // A stale clock drops every frame queued from 0s (the queue holds up to 60); a few skipped VSYNC ticks under
        // parallel test load don't.
        #expect(
            engine.droppedFramesCount <= 4,
            "Stale clock caused frame drop burst on backward seek: \(engine.droppedFramesCount)")
        #expect(
            engine.currentTime >= 0.2 && engine.currentTime <= 2.0,
            "Expected currentTime progressing near 0.0s, got \(engine.currentTime)")
        #expect(engine.isPlaying == true)

        engine.stop()
    }

    @Test("Starting the clock at a new position reads that position immediately, not the paused one")
    @MainActor
    func testClockStartIsImmediatelyAtTarget() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        engine.play()
        #expect(await engine.waitForClock(toPass: 1.0), "Clock did not advance past 1.0s")

        // What a backward seek while playing does: pause the clock where it is, then restart it at the target.
        engine.synchronizer.setRate(0, time: engine.synchronizer.currentTime())
        engine.startSynchronizerClock(at: .zero, rate: 1.0)
        let clock = engine.synchronizer.currentTime().seconds
        #expect(clock < 0.5, "Clock still reads the paused position \(clock)s after restarting at 0s")

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
        #expect(await engine.waitForPlayback(advancingBy: 1.0))

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

    @Test("play() while already playing leaves the running clock alone")
    @MainActor
    func testPlayWhilePlayingDoesNotRestartClock() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = Self.makeEngine()
        engine.load(path: path)
        #expect(await engine.waitForPlayback(advancingBy: 0.5))

        // Hosts re-issue play() on stale state (remote commands, PiP). Restarting the clock would move it back to
        // the last periodic time update and hold it for the output latency; the timebase applies that a moment
        // later, so compare readings across calls, not around one.
        let wallStart = ContinuousClock.now
        let clockStart = engine.synchronizer.currentTime().seconds
        var readings = [clockStart]
        for _ in 0..<10 {
            engine.play()
            #expect(engine.isPrerolling == false)
            try? await Task.sleep(for: .milliseconds(40))
            readings.append(engine.synchronizer.currentTime().seconds)
        }
        let elapsed = (ContinuousClock.now - wallStart).components
        let wallElapsed = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let clockElapsed = readings[readings.count - 1] - clockStart
        #expect(zip(readings, readings.dropFirst()).allSatisfy { $1 >= $0 }, "Clock moved back: \(readings)")
        #expect(
            clockElapsed > wallElapsed * 0.8,
            "Clock advanced \(clockElapsed)s in \(wallElapsed)s of repeated play() calls")

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

        _ = await engine.waitUntil { engine.frameQueue.getLastRenderedPTS() >= 0 }
        let firstPresentedPts = engine.frameQueue.getLastRenderedPTS()
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

    // MARK: - 16. Seek Immediately After Load
    /// A host bridge loads and positions in one go, before the engine's post-load autoplay kicks in. The
    /// autoplay used to start the feeders anyway, racing the seek preview for demuxer packets (the seek
    /// landed on a keyframe) and dropping the play intent (playback stayed stopped at the target).
    @Test(
        "An exact seek issued right after load lands on its target and then autoplays from it",
        arguments: [
            // Keyframes every 5s: a seek that loses packets lands on 5.0s or 10.0s.
            (SyntheticTestMediaFactory.Preset.wideGOPH264, 7.5),
            // Single keyframe at 0 (hardware VP9 where available): a racing seek lands on 0.
            (.vp910BitSDRMP4, 2.0),
        ]
    )
    @MainActor
    func testExactSeekRightAfterLoad(preset: SyntheticTestMediaFactory.Preset, target: Double) async {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        let halfFrame = 0.5 / 24.0

        for startTime in [nil, 1.0] as [Double?] {
            let engine = Self.makeEngine()
            await engine.loadAsync(MediaLoadRequest(path: path, startTime: startTime))
            // The seek's first time update is where it settled; `currentTime` read afterwards has already moved on
            // with the resumed playback by however long the main actor was busy.
            let landings = LockIsolated<[Double]>([])
            engine.onTimeUpdate = { time, _ in landings.withValue { $0.append(time) } }
            engine.seek(to: target, exact: true)
            #expect(await engine.waitUntil { !engine.isSeeking && engine.pendingSeekTime == nil })

            let landing = landings.value.first ?? -1
            #expect(
                abs(landing - target) < halfFrame,
                "Seek right after load (start \(String(describing: startTime))) landed at \(landing)s")
            #expect(await engine.waitForClock(toPass: target + 0.2), "Playback did not continue from \(target)s")
            #expect(engine.isPlaying == true)
            engine.stop()
        }
    }
}
