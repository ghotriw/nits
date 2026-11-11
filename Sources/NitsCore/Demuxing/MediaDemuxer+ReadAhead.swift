import CFFmpeg
import CoreMedia
import Foundation
import os

/// Read-ahead for network sources, as mpv's demuxer cache. Without it the demuxer reads only when a consumer asks,
/// and the feeders stop asking about a second and a half ahead (a full frame queue, the audio renderer's second): a
/// network stall of more than that stops playback, and a demuxer that downloads segments inside its read can't be
/// measured for throughput.
///
/// A thread of its own reads packets into the queues up to `ReadAheadLimits` ahead of the packets taken. Consumers take
/// packets under `queueLock` alone, which the thread releases during `av_read_frame`, so they never wait for the
/// network; seeks and the other users of the input take `lock` through `lockIO()`, and the thread steps aside between
/// packets. A seek clears the queues (or seeks within the packet cache) and the thread reads on from where it left the input.
extension MediaDemuxer {
    public struct ReadAheadLimits: Sendable {
        /// Seconds of media read ahead of the packets taken.
        public var seconds: Double
        /// Payload bytes queued at most: a 4K stream at 80 Mbit/s fills 192 MB in about 20 seconds.
        public var bytes: Int
        /// Payload bytes retained in backward history cache (default 64 MB).
        public var backBytes: Int

        public init(seconds: Double = 30, bytes: Int = 192 << 20, backBytes: Int = 64 << 20) {
            self.seconds = seconds
            self.bytes = bytes
            self.backBytes = backBytes
        }
    }

    struct ReadAheadControl: Sendable {
        var isStopped = false
        /// Started held (`startReadAhead(held:)`): the thread reads nothing until `releaseReadAhead()`.
        var isHeld = false
        /// Threads waiting in `lockIO()`.
        var ioWaiters = 0
    }

    /// Takes `lock`. While reading ahead, the read-ahead thread lets the caller in before its next packet (the lock is
    /// unfair: a thread that takes it again at once could keep a seek waiting).
    ///
    /// - Parameter yielding: For a caller that repositions the input next (a seek): the read the read-ahead thread is in
    ///   is interrupted if it waits (`FFmpegInterrupt.yieldIO`). A live stream's read at the edge waits for the next
    ///   segment, holding the input for as long as the stream takes (a stalled one, forever); the caller repositions what
    ///   it left. Only for such callers: the read-ahead goes on from where the interrupted read left it, in a state only
    ///   a seek puts right.
    func lockIO(yielding: Bool = false) {
        if yielding { interruptContext.yieldIO() }
        defer { if yielding { interruptContext.resumeIO() } }
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

    /// Starts reading ahead; before the consumers start, as from then on they only take from the queues. `held`, it reads
    /// nothing until `releaseReadAhead()`, while `readsAhead` already tells it does: for a start position to be sought
    /// first, rather than read from the start of the input up to it (a network request, a whole HLS segment).
    public func startReadAhead(limits: ReadAheadLimits = ReadAheadLimits(), held: Bool = false) {
        queueLock.lock()
        guard !readsAhead else {
            queueLock.unlock()
            return
        }
        readsAhead = true
        readAheadEnded = false
        readAheadHitEOF = false
        if held { readAheadControl.withLock { $0.isHeld = true } }
        var effectiveLimits = limits
        if isLive {
            effectiveLimits.backBytes = 0
        }
        readAheadLimits = effectiveLimits
        videoQueue.maxBackBytes = effectiveLimits.backBytes
        audioQueue.maxBackBytes = effectiveLimits.backBytes > 0 ? max(1 << 20, effectiveLimits.backBytes / 4) : 0
        // Only the read-ahead thread uses it, from its start on: no `lock`, which the main thread must not take.
        adaptiveBitrate.logic = AdaptiveBitrateLogic(
            config: adaptiveBitrateConfig ?? .scaled(toReadAhead: limits.seconds))
        queueLock.unlock()

        let thread = Thread { [weak self] in
            while let demuxer = self, demuxer.readAheadStep() {}
        }
        thread.name = "Nits.ReadAhead"
        thread.qualityOfService = .userInitiated
        thread.start()
        AppLog.info(.demuxer, "Reading ahead up to \(Int(limits.seconds)) s / \(limits.bytes >> 20) MB")
    }

    /// Lets a read-ahead started held (`startReadAhead(held:)`) read.
    public func releaseReadAhead() {
        readAheadControl.withLock { $0.isHeld = false }
        readAheadWake.signal()
    }

    /// Stops the read-ahead thread; what is queued can still be taken.
    func stopReadAhead() {
        readAheadControl.withLock { $0.isStopped = true }
        queueLock.lock()
        readAheadEnded = true
        readAheadHitEOF = false
        videoQueue.maxBackBytes = 0
        audioQueue.maxBackBytes = 0
        videoQueue.pruneAllHistory()
        audioQueue.pruneAllHistory()
        wakePacketWaiters()
        queueLock.unlock()
        readAheadWake.signal()
    }

    /// One turn of the read-ahead thread; false once stopped.
    private func readAheadStep() -> Bool {
        let control = readAheadControl.withLock { $0 }
        guard !control.isStopped else { return false }
        if control.isHeld {
            _ = readAheadWake.wait(timeout: .now() + .milliseconds(20))
            return true
        }
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
        pollInFlightSegments()
        guard !readAheadEnded, !isReadAheadFull else { return true }
        var pkt = AVPacket()
        let mark = readMark
        let ret = readPacket(&pkt, releasingQueueLock: true)
        // A seek waiting for the input interrupted the read (`lockIO(yielding:)`). It is not the input's end, nor an
        // error: the thread steps aside for the seek, which repositions what the read left (`lock` is still held here,
        // so the seek has not yet resumed the input). Nor is it a measure of the network, whatever it returned (a
        // packet, for MPEG-TS: the rest of the segment): its requests are cut short, and the wait it was in is no cost
        // of reading (`noteRead`), so their transfers are dropped.
        if interruptContext.isYieldingIO, !interruptContext.shouldAbort {
            _ = network?.transferMeter?.take()
            if ret < 0 { return true }
        } else {
            noteRead(from: mark)
        }
        guard ret >= 0 else {
            if ret == Self.averrorEOF {
                readAheadHitEOF = true
            } else {
                AppLog.warning(.demuxer, "Read-ahead stopped: \(Self.ffmpegErrorDescription(ret))")
            }
            readAheadEnded = true
            wakePacketWaiters()
            return true
        }
        defer { av_packet_unref(&pkt) }
        if pkt.stream_index == videoStreamIndex {
            videoQueue.append(videoPacket(from: pkt))
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

    /// Prunes audio history to align with the earliest retained video keyframe minus audio delay,
    /// or by audio time when there is no video. Behind `queueLock`.
    func pruneAudioQueueIfNeeded() {
        // No history kept (local files, live): the pops drop the packets already.
        guard audioQueue.maxBackBytes > 0 else { return }
        if hasVideo, videoStreamIndex >= 0 {
            if let videoHeadPTS = videoQueue.earliestPTS, videoHeadPTS != Int64.min,
                timebase.den > 0, audioTimebase.den > 0, audioTimebase.num > 0
            {
                let videoHeadSeconds = Double(videoHeadPTS) * Double(timebase.num) / Double(timebase.den)
                let audioPruneSeconds = videoHeadSeconds - 0.5
                let rawPrune = audioPruneSeconds * Double(audioTimebase.den) / Double(audioTimebase.num)
                if rawPrune.isFinite, rawPrune > -0x1.0p62, rawPrune < 0x1.0p62 {
                    audioQueue.pruneLinear(beforePTS: Int64(rawPrune))
                } else {
                    audioQueue.pruneLinear()
                }
            } else {
                audioQueue.pruneLinear()
            }
        } else {
            // Without video the history is held by size alone (`audioQueue.maxBackBytes`): an audio-only input is also the
            // audio of another input's picture, and a seek back as far as that one's history must stay in this one.
            audioQueue.pruneLinear()
        }
    }

    /// Behind `queueLock`.
    func wakePacketWaiters() {
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
            while let packet = takeQueuedVideo() {
                videoQueue.pruneGOPs()
                pruneAudioQueueIfNeeded()
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

extension MediaDemuxer {
    /// The next queued picture, handed to the decoder: its captions are decoded now, in the order the decoder takes the
    /// pictures (`LiveSubtitleTracker.processHandedOut`), so a tail of the queue that is cut (a download given up for
    /// a lower variant's) never reaches the caption decoder, whose state could not be undone. The pictures it still
    /// holds are flushed with the last one of an ended input. Behind `queueLock`.
    func takeQueuedVideo() -> DemuxedVideoPacket? {
        guard let packet = videoQueue.popFirst() else {
            // The consumer caught up with the read: the last picture was handed out before the input's end was known.
            // The flush is idempotent (nothing waiting, nothing held: no screens).
            if inputEnded { subtitleTracker.finishCaptions(video: true) }
            return nil
        }
        subtitleTracker.processHandedOut(packet)
        if inputEnded, videoQueue.isEmpty { subtitleTracker.finishCaptions(video: true) }
        return packet
    }

    /// Where the subtitles of a track are known up to: for captions in the pictures only the picture last handed out,
    /// not what is read ahead (they are decoded as the pictures leave the queue). `handedOut`: that picture's second
    /// (`consumedSeconds`; a seek takes it before it moves it).
    func subtitleReadAhead(inVideo: Bool, handedOut: Double? = nil) -> Double {
        let readAhead = readAheadState.withLock { $0 }
        guard inVideo, readsAhead else { return readAhead }
        return min(readAhead, handedOut ?? consumedSeconds)
    }
}

extension MediaDemuxer {
    /// Whether the subtitle track `id` is closed captions in the video's pictures.
    func isCaptionsInVideo(_ id: Int?) -> Bool {
        id.flatMap { id in subtitleTracks.first { $0.id == id } }?.captionsInVideo == true
    }
}
