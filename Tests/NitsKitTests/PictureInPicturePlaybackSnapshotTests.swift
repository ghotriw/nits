import CoreMedia
import Foundation
import Testing

@testable import NitsKit

@Suite("Picture in Picture Playback Snapshot Tests")
struct PictureInPicturePlaybackSnapshotTests {
    private let hostNow: CFTimeInterval = 10_000

    @Test("Time range puts the current position at host-now on PiP's rate-1 clock")
    func testTimeRangeAtNormalRate() {
        let snapshot = PictureInPicturePlaybackSnapshot(
            mediaTime: 120, hostTime: hostNow - 2, duration: 600, isPlaying: true, rate: 1.0)
        let range = snapshot.timeRange(at: hostNow)

        // 2 s of playback since the snapshot: position 122 s.
        #expect(abs(range.start.seconds - (hostNow - 122)) < 1e-6)
        #expect(abs(range.duration.seconds - 600) < 1e-6)
    }

    @Test("A paused snapshot does not advance")
    func testPausedSnapshotHoldsPosition() {
        let snapshot = PictureInPicturePlaybackSnapshot(
            mediaTime: 120, hostTime: hostNow - 5, duration: 600, isPlaying: false, rate: 1.0)
        #expect(snapshot.mediaTime(at: hostNow) == 120)
        #expect(abs(snapshot.timeRange(at: hostNow).start.seconds - (hostNow - 120)) < 1e-6)
    }

    @Test("At other rates the range is in wall-clock seconds, keeping progress and remaining time")
    func testTimeRangeScalesWithRate() {
        let snapshot = PictureInPicturePlaybackSnapshot(
            mediaTime: 300, hostTime: hostNow, duration: 600, isPlaying: true, rate: 2.0)
        let range = snapshot.timeRange(at: hostNow)

        let elapsed = hostNow - range.start.seconds
        #expect(abs(elapsed - 150) < 1e-6)
        #expect(abs(range.duration.seconds - 300) < 1e-6)
        // Halfway through the media is halfway through the range.
        #expect(abs(elapsed / range.duration.seconds - 0.5) < 1e-9)
    }

    @Test("Unknown duration is reported as a live (unbounded) range")
    func testUnknownDurationIsLive() {
        let snapshot = PictureInPicturePlaybackSnapshot(mediaTime: 42, hostTime: hostNow, duration: 0)
        let range = snapshot.timeRange(at: hostNow)
        #expect(range.start == .negativeInfinity)
        #expect(range.duration == .positiveInfinity)
    }

    @Test("Steady playback does not ask PiP to re-read its state")
    func testSteadyPlaybackNeedsNoReport() {
        let previous = PictureInPicturePlaybackSnapshot(
            mediaTime: 100, hostTime: hostNow - 0.05, duration: 600, isPlaying: true)
        let next = PictureInPicturePlaybackSnapshot(
            mediaTime: 100.05, hostTime: hostNow, duration: 600, isPlaying: true)
        #expect(!next.needsReport(after: previous, at: hostNow))
    }

    @Test("Pause, rate change, duration change and seeks ask PiP to re-read its state")
    func testChangesNeedReport() {
        let previous = PictureInPicturePlaybackSnapshot(
            mediaTime: 100, hostTime: hostNow, duration: 600, isPlaying: true)

        var paused = previous
        paused.isPlaying = false
        #expect(paused.needsReport(after: previous, at: hostNow))

        var faster = previous
        faster.rate = 1.5
        #expect(faster.needsReport(after: previous, at: hostNow))

        var longer = previous
        longer.duration = 700
        #expect(longer.needsReport(after: previous, at: hostNow))

        var seeked = previous
        seeked.mediaTime = 130
        #expect(seeked.needsReport(after: previous, at: hostNow))
    }
}
