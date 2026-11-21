import AVFoundation
import Foundation
import Testing

@testable import NitsCore

/// The app in the background plays the audio on: the engine treats the media as audio only (no video feeder, no decoder
/// session, no frames), and the picture comes back with the host.
@Suite("Background playback", .serialized, .realtimePlayback, .hostDependent, .backstopTimeLimit)
@MainActor
struct BackgroundPlaybackTests {
    private static func load(
        preset: SyntheticTestMediaFactory.Preset = .multiTrackH264, configuration: PlayerConfiguration? = nil
    ) async -> PlayerEngine? {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return nil }
        let engine = PlayerEngine.makeForTesting(
            configuration: configuration ?? PlayerConfiguration(resumePlayback: false))
        engine.load(path: path)
        guard await engine.waitForPlayback(advancingBy: 0.5) else {
            engine.stop()
            return nil
        }
        return engine
    }

    @Test("Playing with the picture dropped starts no video feeder and queues no frames")
    func playingWithPictureDroppedStartsNoVideoFeeder() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.pause()
        engine.setPictureDropped(true)
        engine.frameQueue.clear()

        engine.play()
        let from = engine.playbackClock.currentTime().seconds
        #expect(await engine.waitForPlayback(advancingBy: 1.5, timeout: .seconds(6)))
        #expect(engine.playbackClock.currentTime().seconds > from + 1.5, "The audio's clock runs")
        #expect(engine.videoFeedingTask == nil, "No video is fed")
        #expect(engine.frameQueue.count == 0, "No frame is decoded")
    }
}

// MARK: - Entering the background

extension BackgroundPlaybackTests {
    /// No picture work runs: what the system would kill in the background.
    private static func expectNoPictureWork(_ engine: PlayerEngine, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(engine.videoFeedingTask == nil, "No video is fed", sourceLocation: sourceLocation)
        #expect(engine.frameQueue.count == 0, "No frame is queued", sourceLocation: sourceLocation)
        #expect(engine.displayLink == nil, "No display link", sourceLocation: sourceLocation)
    }

    @Test("Playing goes on in the background with the picture dropped")
    func playingGoesOnInTheBackground() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        let from = engine.playbackClock.currentTime().seconds

        engine.hostDidEnterBackground()
        #expect(engine.isPlaying)
        #expect(!engine.hasPicture)
        #expect(await engine.waitUntil(timeout: .seconds(6)) { engine.playbackClock.currentTime().seconds > from + 3 })
        #expect(engine.isPlaying)
        Self.expectNoPictureWork(engine)
    }

    @Test("The audio does not starve in the background past the read-ahead limit and the video queue's")
    func audioDoesNotStarveInTheBackground() async throws {
        var limits = MediaDemuxer.ReadAheadLimits()
        limits.seconds = 3
        guard
            let engine = await Self.load(
                configuration: PlayerConfiguration(resumePlayback: false, readAheadLimits: limits))
        else { return }
        defer { engine.stop() }

        engine.hostDidEnterBackground()
        var last = engine.playbackClock.currentTime().seconds
        var stalledSince = ContinuousClock.now
        let deadline = ContinuousClock.now + .seconds(11)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let now = engine.playbackClock.currentTime().seconds
            if now > last + 0.05 { stalledSince = .now }
            last = max(last, now)
            #expect(ContinuousClock.now - stalledSince < .seconds(1), "The audio stalled at \(now) s")
            if ContinuousClock.now - stalledSince >= .seconds(1) { break }
        }
        #expect(engine.isPlaying)
    }

    @Test("Play from the background after a pause on the way in is audio only")
    func playFromBackgroundAfterPauseIsAudioOnly() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.pause()
        engine.hostDidEnterBackground()
        #expect(!engine.isPlaying)

        engine.play()
        let from = engine.playbackClock.currentTime().seconds
        #expect(
            await engine.waitUntil(timeout: .seconds(6)) { engine.playbackClock.currentTime().seconds > from + 1.5 })
        #expect(engine.isPlaying)
        Self.expectNoPictureWork(engine)
    }

    @Test("Media without audio pauses in the background, and play there does nothing")
    func mediaWithoutAudioPauses() async throws {
        guard let engine = await Self.load(preset: .videoOnlyH264) else { return }
        defer { engine.stop() }

        engine.hostDidEnterBackground()
        #expect(!engine.isPlaying)
        engine.play()
        #expect(!engine.isPlaying)
        #expect(engine.videoFeedingTask == nil)
    }

    @Test("An interruption that ends in the background resumes audio only")
    func interruptionEndInBackgroundIsAudioOnly() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.hostDidEnterBackground()

        engine.handleAudioInterruption(began: true, shouldResume: false)
        #expect(!engine.isPlaying)
        engine.handleAudioInterruption(began: false, shouldResume: true)
        let from = engine.playbackClock.currentTime().seconds
        #expect(
            await engine.waitUntil(timeout: .seconds(6)) {
                engine.isPlaying && engine.playbackClock.currentTime().seconds > from + 1
            })
        Self.expectNoPictureWork(engine)
    }

    @Test("A seek in the background lands the audio and decodes no frame")
    func seekInBackgroundDecodesNoFrame() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.hostDidEnterBackground()

        engine.seek(to: 12.0)
        #expect(await engine.waitForSeekToSettle(timeout: .seconds(6)))
        #expect(await engine.waitUntil(timeout: .seconds(6)) { engine.playbackClock.currentTime().seconds > 12.5 })
        #expect(engine.playbackClock.currentTime().seconds < 16)
        Self.expectNoPictureWork(engine)
    }

    @Test("Repeat-one at the end in the background starts over audio only")
    func repeatOneInBackgroundKeepsPlaying() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.playlist.repeatMode = .one
        engine.hostDidEnterBackground()
        engine.seek(to: max(1, engine.media.duration - 1.5))
        #expect(await engine.waitForSeekToSettle(timeout: .seconds(6)))

        // The end comes in about a second and the media starts over.
        #expect(
            await engine.waitUntil(timeout: .seconds(10)) {
                engine.isPlaying && engine.playbackClock.currentTime().seconds < 10
            })
        #expect(engine.playbackState == .playing)
        Self.expectNoPictureWork(engine)
    }

    @Test("A load in the background of media with audio plays on as audio only")
    func loadInBackgroundStartsAudioOnly() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return }
        engine.hostDidEnterBackground()

        engine.load(path: path)
        #expect(await engine.waitUntil(timeout: .seconds(6)) { engine.isLoaded && !engine.isLoading })
        let from = engine.playbackClock.currentTime().seconds
        #expect(
            await engine.waitUntil(timeout: .seconds(6)) {
                engine.isPlaying && engine.playbackClock.currentTime().seconds > from + 1
            })
        #expect(!engine.hasPicture)
        Self.expectNoPictureWork(engine)
    }

    @Test("A load in the background of media without audio ends paused")
    func loadInBackgroundWithoutAudioEndsPaused() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .videoOnlyH264) else { return }
        engine.hostDidEnterBackground()

        engine.load(path: path)
        #expect(await engine.waitUntil(timeout: .seconds(6)) { engine.isLoaded && !engine.isLoading })
        #expect(!engine.isPlaying)
        #expect(engine.playbackState == .paused)
    }
}

// MARK: - Coming back

extension BackgroundPlaybackTests {
    @Test("Back from the background while playing, the picture is where the sound is and playing goes on")
    func returnWhilePlayingShowsPictureAndKeepsPlaying() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.hostDidEnterBackground()
        try await Task.sleep(for: .seconds(3))
        let before = engine.playbackClock.currentTime().seconds

        engine.hostWillEnterForeground()
        #expect(engine.hasPicture)
        #expect(await engine.waitForSeekToSettle(timeout: .seconds(8)))
        #expect(await engine.waitForPlayback(advancingBy: 1.0, timeout: .seconds(8)))
        #expect(engine.isPlaying)
        let clock = engine.playbackClock.currentTime().seconds
        #expect(clock > before + 0.5, "Playing went on from where the sound was (\(before) → \(clock) s)")
        #expect(
            await engine.waitUntil(timeout: .seconds(4)) {
                abs(engine.frameQueue.getLastRenderedPTS() - engine.playbackClock.currentTime().seconds) < 1.0
            },
            "The picture is where the sound is")
        if let session = engine.decoder as? VTVideoDecoder {
            #expect(session.hasActiveSession, "The next decode made a fresh session")
        }
    }

    @Test("Back from the background paused, the picture is where it was dropped and playing waits for the user")
    func returnPausedStaysPaused() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        _ = await engine.waitForPlayback(advancingBy: 1.0)
        engine.pause()
        let stood = engine.currentTime
        engine.hostDidEnterBackground()
        try await Task.sleep(for: .seconds(1))

        engine.hostWillEnterForeground()
        #expect(engine.hasPicture)
        #expect(await engine.waitForSeekToSettle(timeout: .seconds(8)))
        #expect(!engine.isPlaying)
        #expect(abs(engine.frameQueue.getLastRenderedPTS() - stood) <= 0.2)
    }

    @Test("An item loaded in the background shows its picture on return")
    func returnForItemLoadedInBackground() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .flashClick) else { return }
        engine.hostDidEnterBackground()
        engine.load(path: path)
        #expect(await engine.waitUntil(timeout: .seconds(6)) { engine.isLoaded && !engine.isLoading })
        let from = engine.playbackClock.currentTime().seconds
        #expect(await engine.waitUntil(timeout: .seconds(6)) { engine.playbackClock.currentTime().seconds > from + 1 })

        engine.hostWillEnterForeground()
        #expect(engine.hasPicture)
        #expect(await engine.waitForSeekToSettle(timeout: .seconds(8)))
        #expect(await engine.waitForPlayback(advancingBy: 1.0, timeout: .seconds(8)))
        #expect(
            await engine.waitUntil(timeout: .seconds(4)) {
                abs(engine.frameQueue.getLastRenderedPTS() - engine.playbackClock.currentTime().seconds) < 1.0
            },
            "The picture of the item loaded in the background is where its sound is")
    }

    @Test("Changing the audio track in the background does not bring the video back")
    func audioTrackChangeInBackgroundKeepsPictureDropped() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.hostDidEnterBackground()
        let other = try #require(engine.audioTracks.first { $0.id != engine.selectedAudioTrackId })
        // Far enough past the last picture shown, which stands where it was dropped.
        try await Task.sleep(for: .seconds(3))
        let before = engine.playbackClock.currentTime().seconds

        engine.selectAudioTrack(id: other.id)
        #expect(await engine.waitUntil(timeout: .seconds(8)) { !engine.isSeeking && engine.pendingSeekTime == nil })
        let from = engine.playbackClock.currentTime().seconds
        #expect(from >= before - 0.5, "The switch re-read from the stale picture: \(before) → \(from) s")
        #expect(
            await engine.waitUntil(timeout: .seconds(8)) { engine.playbackClock.currentTime().seconds > from + 1.5 })
        #expect(!engine.hasPicture)
        Self.expectNoPictureWork(engine)
        let queued = engine.demuxer?.queueLock.withLockUnchecked { engine.demuxer?.videoQueue.count } ?? -1
        #expect(queued == 0)
    }
}

/// Where the picture comes back to (`PlayerEngine.returnTarget`): pure, so the cases need no media.
@Suite("Position on return from the background")
struct ReturnTargetTests {
    private func target(
        isPlaying: Bool = false, clock: Double = 0, wasAudioOnly: Bool = true, seekTarget: Double? = nil,
        currentTime: Double = 0, snapshot: BackgroundSnapshot, isLive: Bool = false
    ) -> (position: Double, toLiveEdge: Bool) {
        PlayerEngine.returnTarget(
            isPlaying: isPlaying, clock: clock, wasAudioOnly: wasAudioOnly, seekTarget: seekTarget,
            currentTime: currentTime, snapshot: snapshot, isLive: isLive)
    }

    @Test("Playing, it returns to where the sound is, a live stream too")
    func playingReturnsToTheClock() {
        let snapshot = BackgroundSnapshot(position: 10, atLiveEdge: true)
        #expect(target(isPlaying: true, clock: 42, snapshot: snapshot, isLive: true) == (42, false))
    }

    @Test("Paused with the sound's position moved in the background, it returns to the new position")
    func pausedAfterAMoveReturnsThere() {
        let snapshot = BackgroundSnapshot(position: 10, atLiveEdge: false)
        #expect(target(seekTarget: 30, currentTime: 12, snapshot: snapshot) == (30, false))
        #expect(target(currentTime: 55, snapshot: snapshot) == (55, false))
    }

    @Test("A live stream paused at its edge, and not moved, returns to its edge")
    func livePausedAtTheEdgeReturnsToIt() {
        let snapshot = BackgroundSnapshot(position: 100, atLiveEdge: true)
        #expect(target(currentTime: 100, snapshot: snapshot, isLive: true) == (100, true))
        #expect(target(wasAudioOnly: false, snapshot: snapshot, isLive: true) == (100, true))
    }

    @Test("A live stream paused at its edge and moved since is not pulled back to the edge")
    func liveMovedIsNotPulledToTheEdge() {
        let snapshot = BackgroundSnapshot(position: 100, atLiveEdge: true)
        #expect(target(currentTime: 60, snapshot: snapshot, isLive: true) == (60, false))
    }

    @Test("A picture that was never dropped returns to where it stood")
    func undroppedReturnsToTheSnapshot() {
        let snapshot = BackgroundSnapshot(position: 7.5, atLiveEdge: false)
        #expect(target(wasAudioOnly: false, currentTime: 9, snapshot: snapshot) == (7.5, false))
    }
}

// MARK: - From the code review

extension BackgroundPlaybackTests {
    @Test("Audio-only media that plays on in the background is not sought on return")
    func audioOnlyReturnDoesNotSeek() async throws {
        guard let engine = await Self.load(preset: .audioOnlyFLAC) else { return }
        defer { engine.stop() }
        engine.hostDidEnterBackground()
        #expect(engine.isPlaying)
        try await Task.sleep(for: .seconds(1))

        let seekBefore = engine.seekGeneration.current
        engine.hostWillEnterForeground()
        #expect(engine.seekGeneration.current == seekBefore, "Nothing was dropped: no seek, no renderer flush")
        #expect(engine.isPlaying)
    }

    @Test("Play in the background while a seek is in flight ends up audio only and settles")
    func playInBackgroundDuringASeekSettles() async throws {
        guard let engine = await Self.load() else { return }
        defer { engine.stop() }
        engine.seek(to: 20.0)
        engine.hostDidEnterBackground()
        engine.play()

        #expect(
            await engine.waitUntil(timeout: .seconds(8)) {
                !engine.isSeeking && engine.pendingSeekTime == nil && engine.isPlaying
            }, "The seek settled and playing went on")
        let from = engine.playbackClock.currentTime().seconds
        #expect(await engine.waitUntil(timeout: .seconds(6)) { engine.playbackClock.currentTime().seconds > from + 1 })
        #expect(!engine.hasPicture)
        Self.expectNoPictureWork(engine)
    }
}
