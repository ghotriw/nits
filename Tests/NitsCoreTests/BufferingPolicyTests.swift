import Testing

@testable import NitsCore

@Suite("Buffering thresholds")
struct BufferingPolicyTests {
    private typealias Levels = BufferingPolicy.Levels

    private static let muxed = Levels(audioAhead: 1, queuedFrames: 35, hasAudio: true, hasVideo: true)
    private static let separate = Levels(
        audioAhead: 1, queuedFrames: 35, hasAudio: true, hasVideo: true, isAudioSeparate: true)
    private static let videoOnly = Levels(queuedFrames: 35, hasVideo: true, frameDuration: 0.04)

    private func with(_ levels: Levels, _ change: (inout Levels) -> Void) -> Levels {
        var levels = levels
        change(&levels)
        return levels
    }

    @Test("One demuxer: starved only when audio runs dry and the frame queue is low too")
    func muxedStarvation() {
        #expect(!BufferingPolicy.isStarved(Self.muxed, rate: 1))
        let dry = with(Self.muxed) { $0.audioAhead = 0.1 }
        // A track ending before the video, or a decoder briefly behind: not a shortage.
        #expect(!BufferingPolicy.isStarved(dry, rate: 1))
        #expect(!BufferingPolicy.isStarved(with(Self.muxed) { $0.queuedFrames = 10 }, rate: 1))
        #expect(BufferingPolicy.isStarved(with(dry) { $0.queuedFrames = 19 }, rate: 1))
        #expect(!BufferingPolicy.isStarved(with(dry) { $0.queuedFrames = 20 }, rate: 1))
    }

    @Test("Audio amounts are seconds of playback: the watermark scales with the rate")
    func audioScalesWithRate() {
        let audioOnly = Levels(audioAhead: 0.3, hasAudio: true)
        #expect(!BufferingPolicy.isStarved(audioOnly, rate: 1))
        #expect(BufferingPolicy.isStarved(audioOnly, rate: 4))
        let held = Levels(audioAhead: 1, hasAudio: true)
        #expect(BufferingPolicy.isReadyToResume(held, rate: 1, audioSettled: false))
        #expect(!BufferingPolicy.isReadyToResume(held, rate: 4, audioSettled: false))
    }

    @Test("Audio on an input of its own: either stream running out starves, ended audio does not")
    func separateStarvation() {
        let dryAudio = with(Self.separate) { $0.audioAhead = 0.1 }
        #expect(BufferingPolicy.isStarved(dryAudio, rate: 1))
        #expect(!BufferingPolicy.isStarved(with(dryAudio) { $0.isAudioEOF = true }, rate: 1))
        let lowFrames = with(Self.separate) { $0.queuedFrames = 10 }
        #expect(!BufferingPolicy.isStarved(lowFrames, rate: 1))
        #expect(BufferingPolicy.isStarved(with(lowFrames) { $0.isVideoReadAheadDry = true }, rate: 1))
    }

    @Test("Without audio: starved once the queue is empty and the clock is two frames past the last one")
    func videoOnlyStarvation() {
        let empty = with(Self.videoOnly) { $0.queuedFrames = 0 }
        #expect(!BufferingPolicy.isStarved(with(empty) { $0.secondsPastLastFrame = 0.08 }, rate: 1))
        #expect(BufferingPolicy.isStarved(with(empty) { $0.secondsPastLastFrame = 0.09 }, rate: 1))
        #expect(!BufferingPolicy.isStarved(with(Self.videoOnly) { $0.secondsPastLastFrame = 1 }, rate: 1))
        #expect(!BufferingPolicy.isStarved(Levels(), rate: 1))
    }

    @Test("One demuxer: resumes with enough of both, or with what there is once audio stops coming")
    func muxedResume() {
        #expect(BufferingPolicy.isReadyToResume(Self.muxed, rate: 1, audioSettled: false))
        #expect(
            !BufferingPolicy.isReadyToResume(with(Self.muxed) { $0.queuedFrames = 29 }, rate: 1, audioSettled: true))
        let short = with(Self.muxed) { $0.audioAhead = 0.2 }
        #expect(!BufferingPolicy.isReadyToResume(short, rate: 1, audioSettled: false))
        #expect(BufferingPolicy.isReadyToResume(short, rate: 1, audioSettled: true))
        // Audio stuck behind the demuxer's full video packet queue: the picture being ready is enough.
        #expect(BufferingPolicy.isReadyToResume(with(Self.muxed) { $0.audioAhead = 0 }, rate: 1, audioSettled: true))
        let audioOnly = Levels(hasAudio: true)
        #expect(!BufferingPolicy.isReadyToResume(audioOnly, rate: 1, audioSettled: true))
    }

    @Test("Audio on an input of its own: settled audio under the watermark is short, not all there is")
    func separateResume() {
        let short = with(Self.separate) { $0.audioAhead = 0.1 }
        #expect(!BufferingPolicy.isReadyToResume(short, rate: 1, audioSettled: true))
        #expect(BufferingPolicy.isReadyToResume(with(short) { $0.audioAhead = 0.2 }, rate: 1, audioSettled: true))
        #expect(BufferingPolicy.isReadyToResume(with(short) { $0.isAudioEOF = true }, rate: 1, audioSettled: false))
    }

    @Test("Without audio: resumes once enough frames are queued")
    func videoOnlyResume() {
        #expect(BufferingPolicy.isReadyToResume(Self.videoOnly, rate: 1, audioSettled: false))
        let low = with(Self.videoOnly) { $0.queuedFrames = 29 }
        #expect(!BufferingPolicy.isReadyToResume(low, rate: 1, audioSettled: false))
    }
}
