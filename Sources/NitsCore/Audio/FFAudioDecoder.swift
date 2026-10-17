import AudioToolbox
import CFFmpeg
import CoreMedia
import Foundation
import os

/// Decodes audio packets using FFmpeg libavcodec and resamples via libswresample
/// to 48kHz Multi-channel (5.1 / 7.1) or Stereo Float32 Linear PCM wrapped in CoreMedia CMSampleBuffers
/// with explicit AudioChannelLayout for Apple Spatial Audio and Dynamic Head Tracking.
public final class FFAudioDecoder: @unchecked Sendable {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var audioFormatDescription: CMAudioFormatDescription?

    public let targetSampleRate: Int32 = 48000
    public let targetChannels: Int32
    public let channelLayoutTag: AudioChannelLayoutTag
    private var packetBuffer: UnsafeMutablePointer<UInt8>? = nil
    private var packetBufferCapacity: Int = 0

    private let lock = OSAllocatedUnfairLock()

    public init?(codecParameters: UnsafePointer<AVCodecParameters>, timebase: AVRational) {
        let codecId = codecParameters.pointee.codec_id
        guard let codec = avcodec_find_decoder(codecId) else {
            AppLog.error(.audio, "Codec not found for id: \(codecId.rawValue)")
            return nil
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            AppLog.error(.audio, "Failed to allocate AVCodecContext")
            return nil
        }
        self.codecCtx = ctx

        if avcodec_parameters_to_context(ctx, codecParameters) < 0 {
            AppLog.error(.audio, "Failed to copy codec parameters to context")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        ctx.pointee.pkt_timebase = timebase

        if avcodec_open2(ctx, codec, nil) < 0 {
            AppLog.error(.audio, "Failed to open codec")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        // Determine channel count and layout for Spatial Audio:
        // - 8 channels: 7.1 Surround (L, R, C, LFE, Ls, Rs, Rls, Rrs)
        // - 6 channels: 5.1 Surround (L, R, C, LFE, Ls, Rs)
        // - <= 2 channels: Stereo (L, R) or downmixed from non-standard (3.0, 4.0, 5.0)
        let srcChannels = ctx.pointee.ch_layout.nb_channels
        if srcChannels >= 8 {
            self.targetChannels = 8
            self.channelLayoutTag = kAudioChannelLayoutTag_AudioUnit_7_1  // L R C LFE Ls Rs Rls Rrs
        } else if srcChannels >= 6 {
            self.targetChannels = 6
            self.channelLayoutTag = kAudioChannelLayoutTag_AudioUnit_5_1  // L R C LFE Ls Rs (SMPTE standard)
        } else {
            self.targetChannels = 2
            self.channelLayoutTag = kAudioChannelLayoutTag_Stereo
        }

        self.frame = av_frame_alloc()
        self.packet = av_packet_alloc()

        guard frame != nil && packet != nil else {
            teardown()
            return nil
        }

        setupFormatDescription()
    }

    private func setupFormatDescription() {
        // Standard macOS CoreAudio PCM format: 48kHz, Float32 Linear PCM.
        // For Spatial Audio, CoreAudio requires an explicit AudioChannelLayout
        // matching the multi-channel arrangement (5.1 or 7.1).
        let bytesPerFrame = UInt32(targetChannels * 4)  // 4 bytes per Float32
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(targetSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(targetChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = channelLayoutTag
        channelLayout.mChannelBitmap = []
        channelLayout.mNumberChannelDescriptions = 0

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &channelLayout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        if status == noErr {
            self.audioFormatDescription = formatDesc
            AppLog.debug(
                .audio,
                "Created CMAudioFormatDescription: \(targetChannels)ch @ 48kHz, tag: \(channelLayoutTag)"
            )
        } else {
            AppLog.error(.audio, "Failed to create CMAudioFormatDescription: \(status)")
        }
    }

    private var currentSrcChannels: Int32 = -1
    private var currentSrcFormat: Int32 = -1
    private var currentSrcRate: Int32 = -1
    /// PTS (seconds) expected for the next output buffer; keeps timestamps sample-accurate. Reset on flush.
    private var nextExpectedPts: Double?
    /// Bumped by every flush so output decoded before it can be told apart from output decoded after it.
    private var flushGeneration = 0
    /// Decoded output the feeder could not hand to the renderer before it was cancelled (pause). Its packets are
    /// already consumed from the demuxer, so it must be delivered first on the next run — dropping it leaves a gap
    /// that `nextExpectedPts` then snaps over, which is audible and shifts audio against video. Cleared on flush.
    private var undeliveredOutput: [CMSampleBuffer] = []

    /// Current flush generation; capture it before `decode(...)` and pass it to `stashUndelivered(_:generation:)`.
    public var generation: Int {
        lock.withLock { flushGeneration }
    }

    /// Keeps decoded buffers that were not enqueued, unless a flush happened since they were decoded.
    public func stashUndelivered(_ buffers: ArraySlice<CMSampleBuffer>, generation: Int) {
        guard !buffers.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard generation == flushGeneration else { return }
        undeliveredOutput.append(contentsOf: buffers)
    }

    /// Puts buffers taken back from the renderer (an audio delay change) in front of the stashed ones, unless a flush
    /// happened since `generation` was read.
    public func requeue(_ buffers: [CMSampleBuffer], generation: Int) {
        guard !buffers.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard generation == flushGeneration else { return }
        undeliveredOutput.insert(contentsOf: buffers, at: 0)
    }

    /// Returns (and forgets) the buffers stashed by an interrupted feeding run, in presentation order.
    public func takeUndelivered() -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        defer { undeliveredOutput.removeAll() }
        return undeliveredOutput
    }

    private func initSwrIfNeeded(srcFrame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let frameChannels = srcFrame.pointee.ch_layout.nb_channels
        let frameFormat = srcFrame.pointee.format
        let frameRate = srcFrame.pointee.sample_rate

        if swrCtx != nil && currentSrcChannels == frameChannels && currentSrcFormat == frameFormat
            && currentSrcRate == frameRate
        {
            return true
        }

        if swrCtx != nil {
            var p: OpaquePointer? = swrCtx
            swr_free(&p)
            self.swrCtx = nil
        }

        var inChLayout = srcFrame.pointee.ch_layout
        var outChLayout = AVChannelLayout()
        av_channel_layout_default(&outChLayout, targetChannels)

        var newSwr: OpaquePointer? = nil
        let ret = swr_alloc_set_opts2(
            &newSwr,
            &outChLayout,
            AV_SAMPLE_FMT_FLT,  // Interleaved Float32
            targetSampleRate,
            &inChLayout,
            AVSampleFormat(rawValue: srcFrame.pointee.format),
            srcFrame.pointee.sample_rate,
            0,
            nil
        )

        guard ret == 0, let validSwr = newSwr else {
            AppLog.error(.audio, "swr_alloc_set_opts2 failed: \(ret)")
            return false
        }

        if swr_init(validSwr) < 0 {
            AppLog.error(.audio, "swr_init failed")
            swr_free(&newSwr)
            return false
        }

        self.swrCtx = validSwr
        self.currentSrcChannels = frameChannels
        self.currentSrcFormat = frameFormat
        self.currentSrcRate = frameRate
        return true
    }

    /// Decodes a demuxed audio packet and returns one or more CMSampleBuffers containing Linear PCM
    public func decode(packetData: Data, pts: Int64, timebase: AVRational) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }

        guard let ctx = codecCtx, let avFrame = frame, let avPkt = packet, let formatDesc = audioFormatDescription
        else {
            return []
        }

        av_packet_unref(avPkt)
        let count = packetData.count
        let neededCapacity = count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        if packetBufferCapacity < neededCapacity {
            let newCap = max(neededCapacity, max(packetBufferCapacity * 2, 16384))
            guard let newMem = realloc(packetBuffer, newCap) else { return [] }
            packetBuffer = newMem.assumingMemoryBound(to: UInt8.self)
            packetBufferCapacity = newCap
        }
        guard let mem = packetBuffer else { return [] }
        _ = packetData.withUnsafeBytes { raw in
            memcpy(mem, raw.baseAddress!, count)
        }
        memset(mem.advanced(by: count), 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))

        avPkt.pointee.data = mem
        avPkt.pointee.size = Int32(count)
        avPkt.pointee.pts = pts
        avPkt.pointee.dts = pts

        defer {
            av_packet_unref(avPkt)
        }

        if avcodec_send_packet(ctx, avPkt) < 0 {
            return []
        }

        var sampleBuffers: [CMSampleBuffer] = []

        while avcodec_receive_frame(ctx, avFrame) == 0 {
            defer { av_frame_unref(avFrame) }

            guard initSwrIfNeeded(srcFrame: avFrame), let swr = swrCtx else {
                continue
            }

            // Estimate out sample count
            let maxOutSamples = swr_get_out_samples(swr, avFrame.pointee.nb_samples)
            let outBufferSize = Int(maxOutSamples * targetChannels * 4)  // 4 bytes per float
            guard let outData = malloc(outBufferSize) else { continue }

            var outPtr: UnsafeMutablePointer<UInt8>? = outData.assumingMemoryBound(to: UInt8.self)
            let inData = UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(avFrame.pointee.extended_data))
            let convertedSamples = swr_convert(
                swr,
                &outPtr,
                maxOutSamples,
                inData,
                avFrame.pointee.nb_samples
            )

            guard convertedSamples > 0 else {
                free(outData)
                continue
            }

            let actualByteLength = Int(convertedSamples * targetChannels * 4)

            // Wrap in CMBlockBuffer
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: outData,
                blockLength: actualByteLength,
                blockAllocator: kCFAllocatorMalloc,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: actualByteLength,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard blockStatus == kCMBlockBufferNoErr, let validBlockBuffer = blockBuffer else {
                free(outData)
                continue
            }

            // Presentation timestamp
            let framePts = avFrame.pointee.pts
            var ptsSeconds: Double
            if framePts != Int64.min && timebase.den > 0 {
                ptsSeconds = Double(framePts) * Double(timebase.num) / Double(timebase.den)
            } else {
                ptsSeconds = nextExpectedPts ?? 0
            }
            // Container timestamps are rounded to the container timebase (e.g. 1 ms in MKV), which does not
            // divide frame durations such as DTS (512 samples) or FLAC evenly. Using them verbatim yields
            // ±1 ms overlaps/gaps between consecutive buffers that the audio renderer renders as crackle.
            // Keep PTS sample-accurate: advance by the exact number of samples, re-anchor only on real jumps.
            if let expected = nextExpectedPts, abs(ptsSeconds - expected) < 0.05 {
                ptsSeconds = expected
            }
            nextExpectedPts = ptsSeconds + Double(convertedSamples) / Double(targetSampleRate)
            let cmPts = CMTime(seconds: ptsSeconds, preferredTimescale: targetSampleRate)
            // In CoreMedia for audio buffers with sampleCount > 1, the duration in CMSampleTimingInfo
            // represents the duration of a SINGLE sample (1 / sampleRate), NOT the whole buffer!
            let singleSampleDuration = CMTime(value: 1, timescale: targetSampleRate)

            var timing = CMSampleTimingInfo(
                duration: singleSampleDuration,
                presentationTimeStamp: cmPts,
                decodeTimeStamp: .invalid
            )

            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: validBlockBuffer,
                formatDescription: formatDesc,
                sampleCount: CMItemCount(convertedSamples),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )

            if status == noErr, let sb = sampleBuffer {
                sampleBuffers.append(sb)
            }
        }

        return sampleBuffers
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushGeneration += 1
        undeliveredOutput.removeAll()
        if let ctx = codecCtx {
            avcodec_flush_buffers(ctx)
            nextExpectedPts = nil
        }
        if let swr = swrCtx {
            swr_init(swr)
        }
    }

    private func teardown() {
        if let swr = swrCtx {
            var p: OpaquePointer? = swr
            swr_free(&p)
            self.swrCtx = nil
        }
        if frame != nil {
            av_frame_free(&frame)
        }
        if packet != nil {
            av_packet_free(&packet)
        }
        if codecCtx != nil {
            avcodec_free_context(&codecCtx)
        }
        if let pb = packetBuffer {
            free(pb)
            packetBuffer = nil
            packetBufferCapacity = 0
        }
    }

    deinit {
        teardown()
    }
}
