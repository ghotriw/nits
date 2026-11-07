import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Measurement (skipped unless asked for, see README.md): how long a seek takes on a real ladder, split into the demuxer's (the network) and the
/// preview decode. `bytes` and `latency` are what the input transferred and spent opening requests meanwhile.
@Suite("Ladder seek measurement")
struct LadderSeekMeasurement {
    @Test(
        "Seeks on a real ladder",
        .timeLimit(.minutes(10)),
        .enabled(if: ProcessInfo.processInfo.environment["NITS_MEASURE_URL"] != nil))
    func measure() throws {
        let url = try #require(ProcessInfo.processInfo.environment["NITS_MEASURE_URL"])
        let iterations = Int(ProcessInfo.processInfo.environment["NITS_MEASURE_N"] ?? "") ?? 6
        let openStart = ContinuousClock.now
        let demuxer = try #require(MediaDemuxer(url: url))
        print(
            "MEASURE url=\(url) variants=\(demuxer.variants.count) codec=\(demuxer.codec) open=\(ContinuousClock.now - openStart)"
        )
        let decoder = try #require(VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer))
        let frameQueue = FrameQueue()
        demuxer.startReadAhead(limits: .init())

        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        /// Reads from `from` and takes the packets up to `to`, as playback does, then waits for the read-ahead to fill:
        /// what a cache would hold is behind `to`, and a seek back to `to - 10` is within it.
        func settle(from: Double = 5, to seconds: Double = 25) {
            demuxer.seek(to: from, exact: true)
            let takeDeadline = ContinuousClock.now + .seconds(60)
            while demuxer.consumedSeconds < seconds && ContinuousClock.now < takeDeadline {
                if demuxer.nextVideoSample() == nil { Thread.sleep(forTimeInterval: 0.01) }
            }
            while let packet = demuxer.nextAudioPacket(),
                Double(packet.pts) * Double(demuxer.audioTimebase.num)
                    / Double(demuxer.audioTimebase.den) < seconds
            {}
            let deadline = ContinuousClock.now + .seconds(40)
            while demuxer.readAheadSeconds < seconds + 25 && !demuxer.readAheadEnded && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        func timed(_ label: String, _ iteration: Int, to target: Double, exact: Bool, forward: Bool) {
            decoder.flush()
            frameQueue.clear(resetDroppedFrames: true)
            let bytes0 = demuxer.ioBytes.total
            let open0 = demuxer.ioBytes.openSeconds
            let t0 = ContinuousClock.now
            demuxer.seek(to: target, exact: exact, forward: forward)
            let t1 = ContinuousClock.now
            let frame = SeekPreview.decode(
                demuxer: demuxer, decoder: decoder, frameQueue: frameQueue, seconds: target, exact: exact,
                isCurrent: { true })
            let t2 = ContinuousClock.now
            print(
                "MEASURE \(label) i=\(iteration) seek=\(String(format: "%.0f", ms(t1 - t0))) ms "
                    + "decode=\(String(format: "%.0f", ms(t2 - t1))) ms total=\(String(format: "%.0f", ms(t2 - t0))) ms "
                    + "bytes=\(demuxer.ioBytes.total - bytes0) latency=\(String(format: "%.0f", (demuxer.ioBytes.openSeconds - open0) * 1000)) ms "
                    + "frame=\(frame.map { String(format: "%.2f", $0.pts) } ?? "none") variant=\(demuxer.selectedVariantId.map(String.init) ?? "-")"
            )
        }

        for i in 0..<iterations {
            settle()
            timed("back10-exact", i, to: 15, exact: true, forward: false)
            settle()
            timed("fwd7-exact", i, to: 32, exact: true, forward: false)
            settle()
            timed("back10-keyframe", i, to: 15, exact: false, forward: false)
            settle()
            timed("fwd7-keyframe", i, to: 32, exact: false, forward: true)
        }
        demuxer.stopReadAhead()
    }
}

/// Measurement (skipped unless asked for, see README.md): playback in real time with adaptive bitrate on, seeks back at intervals; how many a cache serves
/// and how many cross a variant splice. `NITS_MEASURE_URL`, `NITS_MEASURE_ABR_SECONDS` (default 150).
@Suite("Ladder ABR seek measurement")
struct LadderABRSeekMeasurement {
    @Test(
        "Seeks back during adaptive playback",
        .timeLimit(.minutes(15)),
        .enabled(if: ProcessInfo.processInfo.environment["NITS_MEASURE_ABR"] != nil))
    func measure() throws {
        let url = try #require(ProcessInfo.processInfo.environment["NITS_MEASURE_URL"])
        let total = Double(ProcessInfo.processInfo.environment["NITS_MEASURE_ABR_SECONDS"] ?? "") ?? 150
        let demuxer = try #require(MediaDemuxer(url: url))
        let wallStart = ContinuousClock.now
        let changes = OSAllocatedUnfairLock(
            initialState: [(playhead: Double, seconds: Double, bandwidth: Int, wall: Double)]())
        let head = OSAllocatedUnfairLock(initialState: 0.0)
        demuxer.onVariantChanged = { change in
            let wall = Double((ContinuousClock.now - wallStart).components.seconds)
            changes.withLock { $0.append((head.withLock { $0 }, change.seconds, change.variant.bandwidth, wall)) }
        }
        print("MEASURE-ABR url=\(url) variants=\(demuxer.variants.count) auto=\(demuxer.isAdaptiveBitrateEnabled)")
        demuxer.startReadAhead(limits: .init())

        var playhead = 0.0
        var pendingVideo: CMSampleBuffer?
        var pendingAudio: MediaDemuxer.DemuxedAudioPacket?
        var last = ContinuousClock.now
        let seekEvery = Double(ProcessInfo.processInfo.environment["NITS_MEASURE_ABR_SEEK_EVERY"] ?? "") ?? 20
        var nextSeek = 25.0
        var seekIndex = 0
        var stalled = 0.0
        func audioSeconds(_ packet: MediaDemuxer.DemuxedAudioPacket) -> Double {
            Double(packet.pts) * Double(demuxer.audioTimebase.num) / Double(demuxer.audioTimebase.den)
        }
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var served = 0
        var slow = 0
        while playhead < total && (ContinuousClock.now - wallStart) < .seconds(Int(total) * 3) {
            let now = ContinuousClock.now
            let dt = ms(now - last) / 1000
            last = now
            // The playhead advances unless the picture is not there (a stall).
            if pendingVideo == nil { pendingVideo = demuxer.nextVideoSample(waitingForReadAhead: false) }
            var advanced = false
            if let sample = pendingVideo {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if pts <= playhead + dt {
                    pendingVideo = nil
                    advanced = true
                } else {
                    advanced = true
                }
            }
            if advanced { playhead += dt } else { stalled += dt }
            do {
                let value = playhead
                head.withLock { $0 = value }
            }
            while true {
                if pendingAudio == nil { pendingAudio = demuxer.nextAudioPacket() }
                guard let packet = pendingAudio, audioSeconds(packet) <= playhead + 0.5 else { break }
                pendingAudio = nil
            }
            if playhead >= nextSeek {
                let back = seekIndex % 2 == 0 ? 4.0 : 9.0
                let exact = seekIndex % 4 >= 2
                let target = playhead - back
                let cursor = demuxer.consumedSeconds
                let spliceBetween = changes.withLock {
                    $0.filter { $0.seconds > target - 0.5 && $0.seconds <= cursor + 0.5 }.count
                }
                let bytes0 = demuxer.ioBytes.total
                let t0 = ContinuousClock.now
                let outcome = demuxer.seekReportingCache(to: target, exact: exact, forward: false)
                let took = ms(ContinuousClock.now - t0)
                if outcome.fromCache { served += 1 } else { slow += 1 }
                print(
                    "MEASURE-ABR seek#\(seekIndex) wall=\((ContinuousClock.now - wallStart).components.seconds) playhead=\(String(format: "%.1f", playhead)) back=\(back) exact=\(exact) "
                        + "fromCache=\(outcome.fromCache) ms=\(String(format: "%.0f", took)) "
                        + "bytes=\(demuxer.ioBytes.total - bytes0) splicesBetween=\(spliceBetween) "
                        + "variant=\(demuxer.selectedVariantId.map(String.init) ?? "-") "
                        + "readAhead=\(String(format: "%.1f", demuxer.readAheadSeconds - demuxer.consumedSeconds))")
                pendingVideo = nil
                pendingAudio = nil
                playhead = target
                do {
                    let value = playhead
                    head.withLock { $0 = value }
                }
                nextSeek = playhead + seekEvery
                seekIndex += 1
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
        demuxer.stopReadAhead()
        for change in changes.withLock({ $0 }) {
            print(
                "MEASURE-ABR change wall=\(Int(change.wall)) playhead=\(String(format: "%.1f", change.playhead)) "
                    + "media=\(String(format: "%.1f", change.seconds)) bandwidth=\(change.bandwidth / 1000) kbit/s")
        }
        print(
            "MEASURE-ABR summary seeks=\(seekIndex) fromCache=\(served) slow=\(slow) "
                + "stalled=\(String(format: "%.1f", stalled)) s changes=\(changes.withLock { $0.count })")
    }
}
