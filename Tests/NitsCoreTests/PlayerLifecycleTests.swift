import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// Lifecycle and repeated recreation stress tests inspired by libmpv's `libmpv_lifetime.c`.
/// Verifies that repeatedly creating, loading, playing, stopping, and destroying player instances:
/// 1. Completely deallocates without ARC retention cycles or memory leaks.
/// 2. Cleanly cancels async tasks (feeding loops, display links, observers) without crashes.
/// 3. Safely handles rapid reload without explicit stop calls.
/// 4. Handles immediate deallocation while playback is running.
@Suite("Player Lifecycle & Repeated Recreation Tests", .serialized)
struct PlayerLifecycleTests {

    private static func findTestMedia() -> String? {
        SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264)
    }

    private static func currentResidentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    // Helper class to capture weak reference across local scope boundaries
    final class RefBox<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    // MARK: - 1. Zero-leak ARC Deallocation Test
    @Test("PlayerEngine instance completely deallocates when released (no retain cycles)")
    @MainActor
    func testEngineARCDeallocation() {
        let box = RefBox<PlayerEngine>(nil)

        autoreleasepool {
            let engine = PlayerEngine.makeForTesting()
            box.value = engine
            #expect(box.value != nil)
            #expect(engine.isLoaded == false)
        }

        #expect(box.value == nil, "PlayerEngine must be completely deallocated when out of scope")
    }

    @Test("PlayerEngine with loaded media completely deallocates when released")
    @MainActor
    func testEngineLoadedARCDeallocation() async {
        guard let path = Self.findTestMedia() else { return }
        let box = RefBox<PlayerEngine>(nil)

        autoreleasepool {
            let engine = PlayerEngine.makeForTesting()
            box.value = engine
            engine.load(path: path)
            #expect(engine.isLoaded == true)
            engine.stop()
        }

        // Allow any scheduled main-thread callbacks (e.g. from feedQueue) to flush
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(box.value == nil, "Loaded PlayerEngine must cleanly deallocate after stop()")
    }

    // MARK: - 2. Rapid Sequential Create -> Load -> Play -> Deinit Loop
    @MainActor
    private func runSinglePlayCycle(path: String, box: RefBox<PlayerEngine>) async {
        let engine = PlayerEngine.makeForTesting()
        box.value = engine
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        engine.play()
        #expect(engine.isPlaying == true)

        // Let the audio/video pipelines spin briefly (20ms)
        try? await Task.sleep(nanoseconds: 20_000_000)

        engine.stop()
    }

    @MainActor
    private func assertEventuallyDeallocated<T: AnyObject>(
        _ box: RefBox<T>,
        message: Comment,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while box.value != nil && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(box.value == nil, message)
    }

    @Test("Rapid sequential create, load, play and destroy loop runs without leaks or deadlocks")
    @MainActor
    func testRapidSequentialRecreationLoop() async {
        guard let path = Self.findTestMedia() else { return }

        let iterations = 15
        let initialMemory = Self.currentResidentMemory()

        for i in 0..<iterations {
            let box = RefBox<PlayerEngine>(nil)
            await runSinglePlayCycle(path: path, box: box)
            await assertEventuallyDeallocated(box, message: "Iteration \(i): Engine must be released without leaks")
        }

        let finalMemory = Self.currentResidentMemory()
        if initialMemory > 0 && finalMemory > initialMemory {
            let growthMB = Double(finalMemory - initialMemory) / (1024.0 * 1024.0)
            // Allow reasonable runtime overhead, but flag catastrophic growth (> 80 MB across 15 cycles)
            #expect(growthMB < 80.0, "Resident memory growth (\(growthMB) MB) exceeded acceptable threshold")
        }
    }

    // MARK: - 3. Immediate Deinit While Actively Playing (Stress Test)
    @MainActor
    private func runAbandonedPlaybackCycle(path: String, box: RefBox<PlayerEngine>) async {
        let engine = PlayerEngine.makeForTesting()
        box.value = engine
        engine.load(path: path)
        engine.play()

        // Intentionally do NOT call engine.stop() before exiting scope;
        // deinit should safely teardown observers, display link, and tasks.
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    @Test("Engine deinit while active playing cleanly cancels feeding tasks without crashing")
    @MainActor
    func testImmediateDeinitWhilePlaying() async {
        guard let path = Self.findTestMedia() else { return }

        for i in 0..<10 {
            let box = RefBox<PlayerEngine>(nil)
            await runAbandonedPlaybackCycle(path: path, box: box)
            await assertEventuallyDeallocated(
                box, message: "Cycle \(i): Engine must deallocate even when abandoned during active playback")
        }
    }

    // MARK: - 4. Rapid In-Place File Reloading (libmpv style)
    @Test("Rapid consecutive load() calls on same engine without stop() cleanly switch media")
    @MainActor
    func testRapidConsecutiveLoadWithoutStop() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = PlayerEngine.makeForTesting()

        for _ in 0..<10 {
            engine.load(path: path)
            #expect(engine.isLoaded == true)
            engine.play()
            try? await Task.sleep(nanoseconds: 15_000_000)
        }

        #expect(engine.isPlaying == true)
        engine.stop()
        #expect(engine.isLoaded == false)
    }

    // MARK: - 5. Low-Level MediaDemuxer Rapid Lifecycle
    @Test("Rapid Demuxer opening, packet reading and destruction")
    func testMediaDemuxerRapidRecreation() {
        guard let path = Self.findTestMedia() else { return }

        for _ in 0..<20 {
            let box = RefBox<MediaDemuxer>(nil)
            autoreleasepool {
                let demuxer = MediaDemuxer(url: path)
                box.value = demuxer
                #expect(demuxer != nil)
                #expect(demuxer?.hasVideo == true)

                // Read a few packets
                for _ in 0..<5 {
                    _ = demuxer?.nextVideoSample()
                    _ = demuxer?.nextAudioPacket()
                }
            }
            #expect(box.value == nil, "Demuxer must cleanly free AVFormatContext and resources")
        }
    }
}
