import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import NitsCore

@Suite("Decode+Convert Throughput")
struct DecodeThroughputTests {
    private func measure(preset: SyntheticTestMediaFactory.Preset, label: String, repeats: Int) {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else {
            print("THRPT \(label): no media")
            return
        }
        guard let demuxer = MediaDemuxer(url: path),
            let params = demuxer.getVideoCodecParameters(),
            let decoder = FFmpegVideoDecoder(codecParameters: params, timebase: demuxer.timebase)
        else {
            print("THRPT \(label): setup failed")
            return
        }

        let frames = LockIsolated(0)
        let dims = LockIsolated((0, 0))
        decoder.setOutputHandler { frame in
            frames.withValue { $0 += 1 }
            dims.withValue {
                $0 = (CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer))
            }
        }

        // Warm-up pass (decoder/pool allocation) — not timed.
        while let s = demuxer.nextVideoSample() { decoder.decode(sampleBuffer: s) }
        decoder.drain()
        frames.withValue { $0 = 0 }

        let start = Date()
        for _ in 0..<repeats {
            demuxer.seek(to: 0, exact: false, forward: false)
            decoder.flush()
            while let s = demuxer.nextVideoSample() { decoder.decode(sampleBuffer: s) }
            decoder.drain()
        }
        let elapsed = Date().timeIntervalSince(start)
        let n = frames.value
        let (w, h) = dims.value
        let fps = elapsed > 0 ? Double(n) / elapsed : 0
        print(
            String(
                format: "THRPT %@ %dx%d: frames=%d elapsed=%.3fs -> %.0f fps (%.3f ms/frame)",
                label, w, h, n, elapsed, fps, fps > 0 ? 1000.0 / fps : 0))
    }

    @Test("decode+convert throughput (AV1 8-bit, VP9 10-bit)")
    func throughput() {
        // Opt-in perf benchmark (prints numbers; not an assertion). Run with THROUGHPUT_BENCH=1 set.
        guard ProcessInfo.processInfo.environment["THROUGHPUT_BENCH"] != nil else { return }
        measure(preset: .av1SDR, label: "AV1-8bit", repeats: 40)
        measure(preset: .vp910BitHDR, label: "VP9-10bit", repeats: 40)
    }
}
