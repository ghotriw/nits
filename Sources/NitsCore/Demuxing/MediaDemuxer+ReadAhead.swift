import CFFmpeg
import CoreMedia
import Foundation
import os

/// Read-ahead for network sources, as mpv's demuxer cache. Without it the demuxer reads only when a consumer asks,
/// and the feeders stop asking about a second and a half ahead (a full frame queue, the audio renderer's second): a
/// network stall of more than that stops playback, and FFmpeg's HLS demuxer, which downloads segments inside
/// `av_read_frame`, can't be measured for throughput.
///
/// A thread of its own reads packets into the queues up to `ReadAheadLimits` ahead of the packets taken. Consumers take
/// packets under `queueLock` alone, which the thread releases during `av_read_frame`, so they never wait for the
/// network; seeks and the other users of the input take `lock` through `lockIO()`, and the thread steps aside between
/// packets. A seek clears the queues and the thread reads on from where it left the input.
extension MediaDemuxer {
    public struct ReadAheadLimits: Sendable {
        /// Seconds of media read ahead of the packets taken.
        public var seconds: Double
        /// Payload bytes queued at most: a 4K stream at 80 Mbit/s fills 192 MB in about 20 seconds.
        public var bytes: Int

        public init(seconds: Double = 30, bytes: Int = 192 << 20) {
            self.seconds = seconds
            self.bytes = bytes
        }
    }

    struct ReadAheadControl: Sendable {
        var isStopped = false
        /// Threads waiting in `lockIO()`.
        var ioWaiters = 0
    }

    /// Takes `lock`. While reading ahead, the read-ahead thread lets the caller in before its next packet (the lock is
    /// unfair: a thread that takes it again at once could keep a seek waiting).
    func lockIO() {
        readAheadControl.withLock { $0.ioWaiters += 1 }
        lock.lock()
        readAheadControl.withLock { $0.ioWaiters -= 1 }
    }

    /// Runs a blocking FFmpeg call (a read, a seek) with `queueLock` released, which the caller holds: track selection
    /// and consumers don't wait for the network behind it. `body` must not touch what `queueLock` guards; the caller
    /// takes the streams it needs before.
    func withoutQueueLock<T>(_ body: () -> T) -> T {
        queueLock.unlock()
        defer { queueLock.lock() }
        return body()
    }

    /// Starts reading ahead; before the consumers start, as from then on they only take from the queues.
    public func startReadAhead(limits: ReadAheadLimits = ReadAheadLimits()) {
        queueLock.lock()
        guard !readsAhead else {
            queueLock.unlock()
            return
        }
        readsAhead = true
        readAheadLimits = limits
        // Only the read-ahead thread uses it, from its start on: no `lock`, which the main thread must not take.
        adaptiveBitrate = AdaptiveBitrateLogic(config: adaptiveBitrateConfig ?? .scaled(toReadAhead: limits.seconds))
        queueLock.unlock()

        let thread = Thread { [weak self] in
            while let demuxer = self, demuxer.readAheadStep() {}
        }
        thread.name = "Nits.ReadAhead"
        thread.qualityOfService = .userInitiated
        thread.start()
        AppLog.info(.demuxer, "Reading ahead up to \(Int(limits.seconds)) s / \(limits.bytes >> 20) MB")
    }

    /// Stops the read-ahead thread; what is queued can still be taken.
    func stopReadAhead() {
        readAheadControl.withLock { $0.isStopped = true }
        queueLock.lock()
        readAheadEnded = true
        wakePacketWaiters()
        queueLock.unlock()
        readAheadWake.signal()
    }

    /// One turn of the read-ahead thread; false once stopped.
    private func readAheadStep() -> Bool {
        let control = readAheadControl.withLock { $0 }
        guard !control.isStopped else { return false }
        if control.ioWaiters > 0 {
            _ = readAheadWake.wait(timeout: .now() + .milliseconds(1))
            return true
        }
        lock.lock()
        queueLock.lock()
        let isIdle = readOnePacketAhead()
        queueLock.unlock()
        lock.unlock()
        if isIdle {
            _ = readAheadWake.wait(timeout: .now() + .milliseconds(20))
        }
        return true
    }

    /// Reads a packet into its queue unless the limits are reached or the input ended; true when nothing was read.
    /// Behind `lock` and `queueLock`.
    private func readOnePacketAhead() -> Bool {
        adaptBitrateIfDue()
        guard let ctx = formatCtx, !readAheadEnded, !isReadAheadFull else {
            noteReadAheadIdle()
            return true
        }
        var pkt = AVPacket()
        let mark = readMark
        let ret = readPacket(ctx, &pkt, releasingQueueLock: true)
        noteRead(from: mark)
        guard ret >= 0 else {
            if ret != Self.averrorEOF {
                AppLog.warning(.demuxer, "Read-ahead stopped: \(Self.ffmpegErrorDescription(ret))")
            }
            readAheadEnded = true
            wakePacketWaiters()
            return true
        }
        defer { av_packet_unref(&pkt) }
        if pkt.stream_index == videoStreamIndex {
            subtitleTracker.processVideoPacket(&pkt)
            videoQueue.append(DemuxedVideoPacket(pkt, format: videoFormat))
        } else if pkt.stream_index == audioStreamIndex {
            audioQueue.append(DemuxedAudioPacket(pkt))
        }
        wakePacketWaiters()
        return false
    }

    /// Behind `queueLock`. A stream with nothing queued is read for up to the byte limit, as in mpv: `consumedSeconds`
    /// follows the video, so video that ends (or starts) more than the limit before (after) the audio would otherwise
    /// stop reading for good, with the audio queue run dry and no end of input.
    private var isReadAheadFull: Bool {
        // Nothing to read for: an added audio file while another track plays. Its reads would never count towards
        // the limit (`recordReadAhead` measures the streams read), and the whole input would be read for nothing.
        if videoStreamIndex < 0 && audioStreamIndex < 0 { return true }
        if videoQueue.byteCount + audioQueue.byteCount >= readAheadLimits.bytes { return true }
        if (hasVideo && videoQueue.isEmpty) || (audioStreamIndex >= 0 && audioQueue.isEmpty) { return false }
        return readAheadState.withLock { $0 } - consumedSeconds >= readAheadLimits.seconds
    }

    /// Behind `queueLock`.
    private func wakePacketWaiters() {
        for _ in 0..<packetWaiters {
            packetArrival.signal()
        }
    }

    /// The next queued video sample while reading ahead (`.some(nil)` when there is none), or `.none` when not
    /// reading ahead. `waiting` waits up to the I/O timeout for the read-ahead thread to queue one.
    func nextReadAheadVideoSample(waiting: Bool) -> CMSampleBuffer?? {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard readsAhead else { return .none }
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            while let packet = videoQueue.popFirst() {
                let time = packet.pts != Int64.min ? packet.pts : packet.dts
                if time != Int64.min, timebase.den > 0 {
                    consumedSeconds = Double(time) * Double(timebase.num) / Double(timebase.den)
                }
                if let sample = createVideoSample(from: packet) { return .some(sample) }
            }
            guard waiting, !readAheadEnded, ContinuousClock.now < deadline, !interruptContext.shouldAbort else {
                return .some(nil)
            }
            packetWaiters += 1
            queueLock.unlock()
            _ = packetArrival.wait(timeout: .now() + .milliseconds(100))
            queueLock.lock()
            packetWaiters -= 1
        }
    }
}
