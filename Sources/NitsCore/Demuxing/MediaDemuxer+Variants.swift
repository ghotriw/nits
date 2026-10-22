import CFFmpeg
import CoreMedia
import Foundation

/// HLS variants. FFmpeg's HLS demuxer exposes each `EXT-X-STREAM-INF` as a program (its `BANDWIDTH` as
/// `variant_bitrate`) and downloads the segments of every playlist with a stream not discarded.
///
/// A switch is spliced without a seek. The new variant is enabled beside the old one; FFmpeg catches its playlist up
/// with the read position (`AVSEEK_FLAG_ANY`, so mid-GOP), and its pictures are dropped up to its first keyframe, at
/// T. From T on pictures come from the new variant (the old one's are dropped), with a format description of its own;
/// queued packets keep the one they were read with. Audio of the new variant is held until the old one reaches T, then
/// takes over from T, and the old variant is discarded: FFmpeg stops it at the end of the segment it is reading.
extension MediaDemuxer {
    struct VariantStreams {
        let video: Int?
        let audio: [Int]
        /// Subtitle renditions (`EXT-X-MEDIA` of type `SUBTITLES`): the subtitle streams other variants have too.
        let subtitles: [Int]
        let all: [Int]
    }

    struct VariantSelection: Sendable {
        var selected: Int?
        /// Asked for by `selectVariant(id:)` or adaptive bitrate, taken by the next read.
        var requested: Int?
        /// Adaptive bitrate chooses (`isAdaptiveBitrateEnabled`).
        var isAutomatic = true
    }

    struct VariantSwitch {
        let target: StreamVariant
        let streams: VariantStreams
        let previous: VariantStreams
        /// The new variant's stream for the selected audio track (same position among its audio streams); the old
        /// stream for a rendition both share, -1 without audio. Follows a track selected during the switch
        /// (`followSelectedAudioTrack`).
        var audioStream: Int

        /// The new variant's stream for the old variant's audio stream `index`.
        func audioStream(replacing index: Int) -> Int {
            guard let position = previous.audio.firstIndex(of: index), streams.audio.indices.contains(position) else {
                return -1
            }
            return streams.audio[position]
        }
        /// The new variant's first keyframe (video time base), once read.
        var spliceTime: Int64?
        /// Decode timestamp of the latest picture read of the old variant (video time base): the new variant's
        /// keyframe presents at or after it (variants share keyframe times). Not its presentation time, which B-frames put ahead of the decode order
        /// FFmpeg interleaves the variants in.
        var previousVideoTime: Int64
        /// New audio from the splice on, read before the old audio reached it.
        var heldAudio: [DemuxedAudioPacket] = []
    }

    /// Switches to variant `id` without a seek; see the type's description. Takes effect from the next read, and
    /// for the pictures at the new variant's first keyframe (`onVariantChanged`). Variants that aren't
    /// `isSwitchable` are ignored. Turns adaptive bitrate off. Doesn't wait for the I/O lock.
    public func selectVariant(id: Int) {
        guard variants.contains(where: { $0.id == id && $0.isSwitchable }) else { return }
        variantSelection.withLock { selection in
            selection.requested = id
            selection.isAutomatic = false
        }
    }

    /// Reads only the streams playback uses: the video, the audio track and the subtitle track selected, of the
    /// variant read (and, during a switch, of the one switched to). FFmpeg's HLS demuxer downloads every playlist with
    /// a stream not discarded: without this every audio rendition (languages, codecs) would be downloaded beside the
    /// one heard, and FFmpeg discards every subtitle rendition itself on opening, so none could be selected.
    /// Behind `lock` and `queueLock`; selection on the main thread only asks for it (`streamSelectionChanged`).
    func applyStreamSelection(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard let selected = selectedVariantId, let current = variantStreams[selected] else { return }
        let subtitle = selectedSubtitleTrackId.flatMap { id in
            subtitleTracks.first { $0.id == id && $0.closedCaptionField == nil }?.streamIndex
        }
        var involved = [current]
        var enabled = Set([current.video, audioStreamIndex, subtitle].compactMap { $0 })
        if let pending = variantSwitch {
            involved += [pending.streams, pending.previous]
            enabled.formUnion([pending.streams.video, pending.previous.video].compactMap { $0 })
            if pending.audioStream >= 0 { enabled.insert(pending.audioStream) }
        }
        for index in Set(involved.flatMap(\.all)) {
            ctx.pointee.streams[index]?.pointee.discard = enabled.contains(index) ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// Applies a track selection made since the last read. Behind `lock` and `queueLock`.
    func applyChangedStreamSelection(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard streamSelectionChanged else { return }
        streamSelectionChanged = false
        applyStreamSelection(in: ctx)
    }

    /// Reports the variant read now as playing from `seconds` on (after a seek). Behind `lock`.
    func reportVariant(at seconds: Double) {
        guard let selected = selectedVariantId, let current = variants.first(where: { $0.id == selected }) else {
            return
        }
        onVariantChanged?(variantChange(current, at: seconds))
    }

    /// `variant`'s pictures as read now, from `seconds` on. Behind `lock`.
    func variantChange(_ variant: StreamVariant, at seconds: Double) -> VariantChange {
        let dimensions = formatDescription.map(CMVideoFormatDescriptionGetDimensions)
        return VariantChange(
            variant: variant, seconds: seconds, width: dimensions.map { Int($0.width) } ?? width,
            height: dimensions.map { Int($0.height) } ?? height, sampleAspectRatio: sampleAspectRatio,
            frameDuration: nominalFrameDuration)
    }

    // MARK: - Discovery

    /// Lists the variants of an HLS master playlist and selects the one with the highest bandwidth. Returns the
    /// indexes of the streams to read (the selected program's, and any stream outside every program), or nil when
    /// the input has no variants. FFmpeg puts the `EXT-X-MEDIA` renditions a variant refers to in its program.
    func discoverVariants(in formatCtx: UnsafeMutablePointer<AVFormatContext>) -> Set<Int>? {
        guard formatCtx.pointee.nb_programs > 1, let programs = formatCtx.pointee.programs else { return nil }
        var found: [(id: Int, bandwidth: Int, streams: VariantStreams)] = []
        for position in 0..<Int(formatCtx.pointee.nb_programs) {
            guard let program = programs[position],
                let entry = av_dict_get(program.pointee.metadata, "variant_bitrate", nil, 0),
                let bandwidth = Int(String(cString: entry.pointee.value)), bandwidth > 0
            else { return nil }
            let all = (0..<Int(program.pointee.nb_stream_indexes)).map { Int(program.pointee.stream_index[$0]) }
            let ofType = { (type: AVMediaType) in
                all.filter { formatCtx.pointee.streams[$0]?.pointee.codecpar.pointee.codec_type == type }
            }
            let video = ofType(AVMEDIA_TYPE_VIDEO).first
            found.append(
                (
                    Int(program.pointee.id), bandwidth,
                    VariantStreams(
                        video: video, audio: ofType(AVMEDIA_TYPE_AUDIO), subtitles: ofType(AVMEDIA_TYPE_SUBTITLE),
                        all: all)
                ))
        }
        // Subtitle renditions are the subtitle streams of variants with different videos (a group they refer to). The
        // others are in a video's own playlist and go with it: Apple's examples have one in each, in as many variants
        // as there are audio groups.
        var videosWith: [Int: Set<Int>] = [:]
        for variant in found {
            for index in variant.streams.subtitles {
                videosWith[index, default: []].insert(variant.streams.video ?? -1)
            }
        }
        found = found.map { variant in
            let streams = variant.streams
            return (
                variant.id, variant.bandwidth,
                VariantStreams(
                    video: streams.video, audio: streams.audio,
                    subtitles: streams.subtitles.filter { (videosWith[$0]?.count ?? 0) > 1 }, all: streams.all)
            )
        }
        guard let selected = found.max(by: { $0.bandwidth < $1.bandwidth }) else { return nil }

        variants = found.map { variant in
            let video = variant.streams.video.flatMap { formatCtx.pointee.streams[$0]?.pointee.codecpar }
            return StreamVariant(
                id: variant.id, bandwidth: variant.bandwidth,
                width: Int(video?.pointee.width ?? 0), height: Int(video?.pointee.height ?? 0),
                isSwitchable: Self.canSwitch(from: selected.streams, to: variant.streams, in: formatCtx))
        }.sorted { $0.bandwidth > $1.bandwidth }
        variantStreams = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.streams) })
        variantSelection.withLock { $0.selected = selected.id }
        AppLog.info(
            .demuxer,
            "HLS: \(found.count) variants (\(variants.filter(\.isSwitchable).count) switchable), playing "
                + "\(selected.bandwidth / 1000) kbit/s")

        let inPrograms = Set(found.flatMap(\.streams.all))
        let outsidePrograms = (0..<Int(formatCtx.pointee.nb_streams)).filter { !inPrograms.contains($0) }
        return Set(selected.streams.all).union(outsidePrograms)
    }

    /// Whether `b` plays through the decoders made for `a`: the same video codec, time base, scan (progressive or
    /// interlaced), pixel format, colour and Dolby Vision signalling, and audio streams that are the same renditions or
    /// decode alike.
    /// Parameter sets may differ: VideoToolbox gets a session per format description, FFmpeg takes them mid-stream.
    static func canSwitch(
        from a: VariantStreams, to b: VariantStreams, in formatCtx: UnsafeMutablePointer<AVFormatContext>
    ) -> Bool {
        let parameters = { (index: Int) in formatCtx.pointee.streams[index]?.pointee.codecpar }
        guard let aVideo = a.video.flatMap(parameters), let bVideo = b.video.flatMap(parameters) else { return false }
        // The decoders convert timestamps with the time base they were made with.
        let timebase = { (index: Int?) in index.flatMap { formatCtx.pointee.streams[$0]?.pointee.time_base } }
        guard let aBase = timebase(a.video), let bBase = timebase(b.video), av_cmp_q(aBase, bBase) == 0 else {
            return false
        }
        let hasDolbyVision = { (codecpar: UnsafeMutablePointer<AVCodecParameters>) in
            av_packet_side_data_get(
                codecpar.pointee.coded_side_data, codecpar.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF) != nil
        }
        // Interlaced video is decoded elsewhere (interlaced H.264 by FFmpeg, not VideoToolbox) and paced at the field
        // rate; the pixel format carries the bit depth the decoders and the renderer were set up for.
        guard aVideo.pointee.codec_id == bVideo.pointee.codec_id,
            aVideo.pointee.field_order == bVideo.pointee.field_order,
            aVideo.pointee.format == bVideo.pointee.format,
            aVideo.pointee.color_primaries == bVideo.pointee.color_primaries,
            aVideo.pointee.color_trc == bVideo.pointee.color_trc,
            aVideo.pointee.color_space == bVideo.pointee.color_space,
            hasDolbyVision(aVideo) == hasDolbyVision(bVideo),
            a.audio.count == b.audio.count,
            // Subtitle tracks follow no switch: the variants share their renditions (one group), or don't switch.
            a.subtitles == b.subtitles
        else { return false }
        return zip(a.audio, b.audio).allSatisfy { aIndex, bIndex in
            guard aIndex != bIndex else { return true }
            guard let aAudio = parameters(aIndex), let bAudio = parameters(bIndex) else { return false }
            let extradata = { (codecpar: UnsafeMutablePointer<AVCodecParameters>) in
                codecpar.pointee.extradata.map { Data(bytes: $0, count: Int(codecpar.pointee.extradata_size)) }
            }
            return aAudio.pointee.codec_id == bAudio.pointee.codec_id
                && aAudio.pointee.sample_rate == bAudio.pointee.sample_rate
                && aAudio.pointee.ch_layout.nb_channels == bAudio.pointee.ch_layout.nb_channels
                && extradata(aAudio) == extradata(bAudio)
        }
    }

    // MARK: - Splicing (behind `lock`)

    /// Starts the switch `selectVariant(id:)` asked for. One under way is given up before its splice; past it, its
    /// audio takes over at once.
    func beginRequestedVariantSwitch(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        followSelectedAudioTrack()
        guard
            let requested = variantSelection.withLock({ selection -> Int? in
                defer { selection.requested = nil }
                return selection.requested
            })
        else { return }
        if let pending = variantSwitch {
            if pending.spliceTime == nil {
                cancelVariantSwitch(in: ctx, reporting: false)
            } else {
                spliceVariantAudio(in: ctx, releasingHeld: true)
            }
        }
        guard let selected = selectedVariantId, requested != selected,
            let target = variants.first(where: { $0.id == requested }),
            let streams = variantStreams[requested], let previous = variantStreams[selected]
        else { return }

        var newSwitch = VariantSwitch(
            target: target, streams: streams, previous: previous, audioStream: -1,
            previousVideoTime: lastVideoReadTime)
        newSwitch.audioStream = newSwitch.audioStream(replacing: audioStreamIndex)
        variantSwitch = newSwitch
        // Its video and the rendition of the audio track selected; the other renditions stay off.
        applyStreamSelection(in: ctx)
        AppLog.info(.demuxer, "HLS: switching to \(target.width)x\(target.height) at \(target.bandwidth / 1000) kbit/s")
    }

    /// An audio track selected during a switch (`selectAudioTrack`, under `queueLock` alone) is spliced to in place of
    /// the one selected when it began; what was held of that one is dropped.
    private func followSelectedAudioTrack() {
        guard let pending = variantSwitch else { return }
        let audioStream = pending.audioStream(replacing: audioStreamIndex)
        guard audioStream != pending.audioStream else { return }
        variantSwitch?.audioStream = audioStream
        variantSwitch?.heldAudio = []
    }

    /// Whether a packet read during a switch is handed on; see the type's description.
    func admitDuringVariantSwitch(_ pkt: inout AVPacket, in ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        // A track may have been selected during the read, which runs with `queueLock` released.
        followSelectedAudioTrack()
        guard let pending = variantSwitch else { return true }
        let index = Int(pkt.stream_index)
        let time = pkt.pts != Int64.min ? pkt.pts : pkt.dts
        let audioSplices = pending.audioStream >= 0 && pending.audioStream != audioStreamIndex

        guard let spliceTime = pending.spliceTime else {
            if index == pending.streams.video {
                // A variant read before hands out the packet it held when it was discarded first, from back then
                // (FFmpeg's catch-up seek skips only what it reads after).
                guard pkt.flags & AV_PKT_FLAG_KEY != 0, time != Int64.min, time >= pending.previousVideoTime else {
                    return false
                }
                return spliceVariantVideo(at: time, keyframe: pkt, in: ctx)
            }
            let decodeTime = pkt.dts != Int64.min ? pkt.dts : pkt.pts
            if index == pending.previous.video, decodeTime != Int64.min {
                variantSwitch?.previousVideoTime = max(pending.previousVideoTime, decodeTime)
            }
            if audioSplices, index == pending.audioStream {
                variantSwitch?.heldAudio.append(DemuxedAudioPacket(pkt))
                // No keyframe in this much: the new playlist isn't coming.
                if pending.heldAudio.count > 5000 { cancelVariantSwitch(in: ctx) }
                return false
            }
            // The new variant's other streams start with it.
            return !pending.streams.all.contains(index) || pending.previous.all.contains(index)
        }

        if index == pending.previous.video { return false }
        guard audioSplices, index == audioStreamIndex || index == pending.audioStream, time != Int64.min,
            let stream = ctx.pointee.streams[index]
        else {
            return true
        }
        let audioTimebase = stream.pointee.time_base
        let audioSpliceTime = av_rescale_q(spliceTime, timebase, audioTimebase)
        if index == audioStreamIndex {
            guard time >= audioSpliceTime else { return true }
            spliceVariantAudio(in: ctx, releasingHeld: true)
            return false
        }
        if time >= audioSpliceTime {
            variantSwitch?.heldAudio.append(DemuxedAudioPacket(pkt))
            // The old audio ended before the splice (its playlist was stopped): the new one takes over a second on.
            if time - audioSpliceTime > av_rescale_q(1, AVRational(num: 1, den: 1), audioTimebase) {
                spliceVariantAudio(in: ctx, releasingHeld: true)
            }
        }
        return false
    }

    /// Pictures come from the new variant from `time` on. `keyframe` gives the parameter sets when the stream's
    /// extradata has none (MPEG-TS repeats them in band); without either the switch is given up.
    @discardableResult
    func spliceVariantVideo(at time: Int64, keyframe: AVPacket?, in ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool
    {
        guard let pending = variantSwitch, let videoIndex = pending.streams.video,
            let stream = ctx.pointee.streams[videoIndex], let codecpar = stream.pointee.codecpar
        else { return false }
        // H.264 and HEVC descriptions are built from parameter sets, in the stream's extradata or (MPEG-TS) in band;
        // the others' (AV1, VP9) from the stream's configuration record (`av1C`, `vpcC`) alone.
        let parsed: (sets: VideoFormatDescriptionBuilder.ParameterSets, isAnnexB: Bool)?
        if codec.requiresParameterSets {
            let isComplete = { (sets: VideoFormatDescriptionBuilder.ParameterSets) in
                sets.sps != nil && sets.pps != nil && (self.codec != .hevc || sets.vps != nil)
            }
            let fromExtradata = codecpar.pointee.extradata.flatMap {
                VideoFormatDescriptionBuilder.parameterSets(
                    fromExtradata: Data(bytes: $0, count: Int(codecpar.pointee.extradata_size)), codec: codec)
            }
            let fromKeyframe = keyframe.flatMap { pkt in
                pkt.data.flatMap {
                    VideoFormatDescriptionBuilder.parameterSets(
                        fromExtradata: Data(bytes: $0, count: Int(pkt.size)), codec: codec)
                }
            }
            parsed = [fromExtradata, fromKeyframe].compactMap { $0 }.first { isComplete($0.sets) }
        } else {
            parsed = (VideoFormatDescriptionBuilder.ParameterSets(), isAnnexBStream)
        }
        guard let parsed, let previousVideo = pending.previous.video,
            let previousStream = ctx.pointee.streams[previousVideo]
        else {
            AppLog.warning(.demuxer, "HLS: no parameter sets for the new variant; staying")
            cancelVariantSwitch(in: ctx)
            return false
        }

        configureVideoStream(stream, index: videoIndex, codec: codec, in: ctx)
        let wasAnnexB = isAnnexBStream
        isAnnexBStream = parsed.isAnnexB
        guard let description = makeVideoFormatDescription(parameterSets: parsed.sets, codecParameters: codecpar)
        else {
            AppLog.warning(.demuxer, "HLS: no format description for the new variant; staying")
            configureVideoStream(previousStream, index: previousVideo, codec: codec, in: ctx)
            isAnnexBStream = wasAnnexB
            cancelVariantSwitch(in: ctx)
            return false
        }
        formatDescription = description
        variantSwitch?.spliceTime = time
        variantSelection.withLock { $0.selected = pending.target.id }
        AppLog.info(.demuxer, "HLS: pictures from \(pending.target.width)x\(pending.target.height) at pts \(time)")
        onVariantChanged?(variantChange(pending.target, at: Double(time) * Double(timebase.num) / Double(timebase.den)))
        if pending.audioStream < 0 || pending.audioStream == audioStreamIndex {
            finishVariantSwitch(in: ctx)
        }
        return true
    }

    /// Audio comes from the new variant: the tracks point at its streams, and the held packets are queued (when
    /// `releasingHeld`; a seek drops them).
    func spliceVariantAudio(in ctx: UnsafeMutablePointer<AVFormatContext>, releasingHeld: Bool) {
        guard let pending = variantSwitch else { return }
        if pending.audioStream >= 0, let stream = ctx.pointee.streams[pending.audioStream] {
            audioStreamIndex = pending.audioStream
            audioTimebase = stream.pointee.time_base
            if !hasVideo { timebase = audioTimebase }
            audioTracks = audioTracks.map { track in
                guard let position = pending.previous.audio.firstIndex(of: track.streamIndex) else { return track }
                return AudioTrack(
                    id: track.id, streamIndex: pending.streams.audio[position], title: track.title,
                    language: track.language, codecName: track.codecName, channels: track.channels,
                    sampleRate: track.sampleRate, isDefault: track.isDefault, describesVideo: track.describesVideo)
            }
            if releasingHeld, let spliceTime = pending.spliceTime {
                let audioSpliceTime = av_rescale_q(spliceTime, timebase, audioTimebase)
                for packet in pending.heldAudio where packet.pts >= audioSpliceTime {
                    audioQueue.append(packet)
                }
            }
        }
        finishVariantSwitch(in: ctx)
    }

    /// Completes a switch before a seek to `seconds`, which reads from the new variant at once.
    func completeVariantSwitchBeforeSeek(in ctx: UnsafeMutablePointer<AVFormatContext>, at seconds: Double) {
        beginRequestedVariantSwitch(in: ctx)
        guard let pending = variantSwitch else { return }
        if pending.spliceTime == nil {
            let time = timebase.num > 0 ? Int64(seconds * Double(timebase.den) / Double(timebase.num)) : 0
            guard spliceVariantVideo(at: time, keyframe: nil, in: ctx) else { return }
        }
        spliceVariantAudio(in: ctx, releasingHeld: false)
    }

    /// At the end of the input a switch either never reached its keyframe, or its audio takes over now.
    func endVariantSwitchAtEOF(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard let pending = variantSwitch else { return }
        if pending.spliceTime == nil {
            cancelVariantSwitch(in: ctx)
        } else {
            spliceVariantAudio(in: ctx, releasingHeld: true)
        }
    }

    private func finishVariantSwitch(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard let pending = variantSwitch else { return }
        for index in pending.previous.all where !pending.streams.all.contains(index) {
            ctx.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }
        variantSwitch = nil
    }

    /// - Parameter reporting: Report the variant still playing (`onVariantChanged`), unless another was asked for.
    private func cancelVariantSwitch(in ctx: UnsafeMutablePointer<AVFormatContext>, reporting: Bool = true) {
        guard let pending = variantSwitch else { return }
        for index in pending.streams.all where !pending.previous.all.contains(index) {
            ctx.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }
        variantSwitch = nil
        // The variant asked for never played: report the one still read, from where reading is.
        if reporting {
            reportVariant(at: readAheadState.withLock { $0 })
        }
    }
}
