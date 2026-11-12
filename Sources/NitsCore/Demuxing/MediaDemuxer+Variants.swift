import CFFmpeg
import CoreMedia
import Foundation

/// Variants of an adaptive stream. `HLSInput` lists each `EXT-X-STREAM-INF` as a candidate with streams of its own, and
/// downloads the segments of every playlist with a stream not discarded.
///
/// A switch is spliced without a seek. The new variant is enabled beside the old one; the input catches its playlist up
/// with the read position (`HLSLane.catchUp`, the segment after the picture's), and its pictures are dropped up to its
/// first keyframe, at T. From T on pictures come from the new variant (the old one's are dropped), with a format
/// description of its own; queued packets keep the one they were read with. Audio of the new variant is held until the
/// old one reaches T, then takes over from T, and the old variant is discarded: the input stops it at the end of the
/// segment it is reading.
extension MediaDemuxer {
    struct VariantStreams {
        let video: Int?
        let audio: [Int]
        /// Subtitle renditions (`EXT-X-MEDIA` of type `SUBTITLES`): the subtitle streams other variants have too.
        let subtitles: [Int]
        let all: [Int]
    }

    /// What the variants are of, for the log: "DASH", or "HLS".
    var streamingName: String {
        input.streamingName
    }

    struct VariantSelection: Sendable {
        var selected: Int?
        /// Asked for by `selectVariant(id:)` or adaptive bitrate, taken by the next read.
        var requested: Int?
        /// Adaptive bitrate chooses (`isAdaptiveBitrateEnabled`).
        var isAutomatic = true
        /// Variants whose first read found other streams than described, or ones that don't switch
        /// (`verifyVariantSwitchTarget`): neither asked for nor chosen again.
        var rejected: Set<Int> = []
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
        /// DASH: the new variant's first keyframe, found while the old variant has yet to hand over the pictures that
        /// decode before it (`holdsNewVariantForOld`); the splice waits for them.
        var candidate: SpliceCandidate?
        /// The new variant's pictures from `candidate` on, in the order they were read.
        var heldVideo: [HeldVideoPacket] = []
        /// DASH: the old variant's pictures delayed while the keyframe is looked for (`admitVideoWaitingForOld`).
        var heldOld: [HeldVideoPacket] = []
        /// The target was described by its own read when the switch began, or has been since and switches
        /// (`verifyVariantSwitchTarget`).
        var isTargetVerified = false
        /// The old variant's download of the segment the new one joins was given up (`MediaDemuxer+Abandonment`): its streams
        /// are not read while the switch is under way, and are again if it is given up.
        var abandoned: PendingAbandon?
        var isPreviousAbandoned: Bool { abandoned != nil }
    }

    /// Switches to variant `id` without a seek; see the type's description. Takes effect from the next read, and
    /// for the pictures at the new variant's first keyframe (`onVariantChanged`). Variants that aren't
    /// `isSwitchable` are ignored. Turns adaptive bitrate off. Doesn't wait for the I/O lock.
    public func selectVariant(id: Int) {
        guard variants.contains(where: { $0.id == id && $0.isSwitchable }) else { return }
        variantSelection.withLock { selection in
            guard !selection.rejected.contains(id) else { return }
            selection.requested = id
            selection.isAutomatic = false
        }
    }

    /// Reads only the streams playback uses: the video, the audio track and the subtitle track selected, of the
    /// variant read (and, during a switch, of the one switched to). The input downloads every playlist with a stream
    /// not discarded: without this every audio rendition (languages, codecs) would be downloaded beside the one heard,
    /// and every subtitle rendition with it.
    /// Behind `lock` and `queueLock`; selection on the main thread only asks for it (`streamSelectionChanged`).
    func applyStreamSelection() {
        guard let selected = selectedVariantId, let current = variantStreams[selected] else { return }
        let subtitles = selectedSubtitleStreamIndices
        var involved = [current]
        var enabled = Set([current.video, audioStreamIndex].compactMap { $0 })
        enabled.formUnion(subtitles)
        if let pending = variantSwitch {
            involved += [pending.streams, pending.previous]
            enabled.formUnion([pending.streams.video, pending.previous.video].compactMap { $0 })
            if pending.audioStream >= 0 { enabled.insert(pending.audioStream) }
        }
        if let pending = variantSwitch, pending.isPreviousAbandoned {
            // What only the old variant has (its picture, the sound muxed into it) is not read: its download was given up.
            // The renditions both have stay.
            enabled.subtract(Set(pending.previous.all).subtracting(pending.streams.all))
        }
        for index in Set(involved.flatMap(\.all)) {
            input.setReading(enabled.contains(index), stream: index)
        }
    }

    /// Applies a track selection made since the last read. Behind `lock` and `queueLock`.
    func applyChangedStreamSelection() {
        guard streamSelectionChanged else { return }
        streamSelectionChanged = false
        applyStreamSelection()
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

    /// Lists the variants the input groups its streams in (`DemuxerInput.variantCandidates()`) and selects the top of
    /// its ladder (`adoptVariants`). Returns the indexes of the streams to read (the selected variant's, and any stream
    /// outside every variant), or nil when the input has no variants. Behind `lock` (opening).
    func discoverVariants() -> Set<Int>? {
        guard let found = input.variantCandidates() else { return nil }
        return adoptVariants(found, linkRate: input.openingLinkRate)
    }

    /// Takes `found` as the variants of the input, the top of the ladder selected (or the rung a known link carries); see
    /// `discoverVariants`. `linkRate` is what the input measured of the link while it opened, when it tells
    /// (`DemuxerInput.openingLinkRate`): playback starts on the variant it carries, not the best, whose first segment
    /// would take a minute (2 Mbit/s against 39: 62 to 70 s stalled of 120).
    private func adoptVariants(_ found: [VariantCandidate], linkRate: Double? = nil) -> Set<Int>? {
        guard let best = found.max(by: { $0.bandwidth < $1.bandwidth }) else { return nil }
        // Playback starts on a rung of the ladder: a variant without pictures (sound only) or one the adaptive bitrate
        // cannot switch from (another codec, kept outside the ladder) would be played to the end. The ladder is a group
        // of variants that play through one set of decoders (`canSwitch`, false without pictures): the best's when it
        // has another rung (an HDR ladder above a longer SDR one), else the largest. The best alone is the odd one (one
        // HEVC rendition above a ladder of H.264). Without pictures in any, every variant is a rung (sound only).
        let group = { (variant: VariantCandidate) in
            found.filter { self.canSwitch(from: variant.streams, to: $0.streams) }
        }
        let bestGroup = group(best)
        // Of groups as large, the one whose top is better, not the one listed first.
        let rank = { (group: [VariantCandidate]) in
            (group.count, group.map(\.bandwidth).max() ?? 0)
        }
        let largest = found.map(group).max { rank($0) < rank($1) } ?? []
        let ladder =
            if bestGroup.count > 1 {
                bestGroup
            } else if largest.count > 1 {
                largest
            } else if !bestGroup.isEmpty {
                // No ladder: the best, alone in its decoders as every other.
                bestGroup
            } else if !largest.isEmpty {
                // The best without pictures: one with them.
                largest
            } else {
                found
            }
        // Its top, unless the link's rate is known: a DASH ladder is read side by side while it opens, and an HLS
        // master's opening may prove the link slow. Then the rung it carries, not the top (its first segment,
        // megabytes, downloaded before a switch could splice).
        // Only a variant described by its own read starts: the decoders are made from its streams before any is read
        // (`DemuxerInput.variantDescription`; the input describes the rung a slow link starts on).
        let startable = ladder.filter { input.variantDescription(id: $0.id) == .described }
        let rungs = startable.isEmpty ? ladder : startable
        var start = rungs.max { $0.bandwidth < $1.bandwidth } ?? best
        if let linkRate {
            let share = AdaptiveBitrateLogic.Config().safety
            let fitting = rungs.filter { Double($0.bandwidth) <= linkRate * share }.max { $0.bandwidth < $1.bandwidth }
            start = fitting ?? rungs.min { $0.bandwidth < $1.bandwidth } ?? best
        }

        let selected = start
        variants = found.map { variant in
            let video = variant.streams.video.flatMap { input.stream($0)?.pointee.codecpar }
            return StreamVariant(
                id: variant.id, bandwidth: variant.bandwidth,
                width: Int(video?.pointee.width ?? 0), height: Int(video?.pointee.height ?? 0),
                isSwitchable: canSwitch(from: selected.streams, to: variant.streams))
        }.sorted { $0.bandwidth > $1.bandwidth }
        variantStreams = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.streams) })
        variantSelection.withLock { $0.selected = selected.id }
        AppLog.info(
            .demuxer,
            "\(streamingName): \(found.count) variants (\(variants.filter(\.isSwitchable).count) switchable), playing "
                + "\(selected.bandwidth / 1000) kbit/s" + (linkRate.map { ", link \(Int($0 / 1000)) kbit/s" } ?? ""))

        let inVariants = Set(found.flatMap(\.streams.all))
        let outsideVariants = (0..<input.streamCount).filter { !inVariants.contains($0) }
        return Set(selected.streams.all).union(outsideVariants)
    }

    /// Whether `b` plays through the decoders made for `a`: the same video codec, time base, scan (progressive or
    /// interlaced), pixel format, colour and Dolby Vision signalling, and audio streams that are the same renditions or
    /// decode alike.
    /// Parameter sets may differ: VideoToolbox gets a session per format description, FFmpeg takes them mid-stream.
    func canSwitch(from a: VariantStreams, to b: VariantStreams) -> Bool {
        let parameters = { (index: Int) in self.input.stream(index)?.pointee.codecpar }
        guard let aVideo = a.video.flatMap(parameters), let bVideo = b.video.flatMap(parameters) else { return false }
        // The decoders convert timestamps with the time base they were made with.
        let timebase = { (index: Int?) in index.flatMap { self.input.stream($0)?.pointee.time_base } }
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
            // Queued audio keeps no time base of its own (the demuxer's `audioTimebase` is the current stream's), so
            // streams that differ in it (MPEG-TS and fragmented MP4 renditions) do not switch.
            guard let aBase = timebase(aIndex), let bBase = timebase(bIndex), av_cmp_q(aBase, bBase) == 0 else {
                return false
            }
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
    func beginRequestedVariantSwitch() {
        followSelectedAudioTrack()
        // A download given up for a lower variant's of the same segment (`requestAbandon`) is switched to first; a variant
        // asked for besides stays asked for, and its turn is the next read's (it replaces this switch if unspliced).
        let abandonment = adaptiveBitrate.pendingAbandon
        adaptiveBitrate.pendingAbandon = nil
        let requested: Int
        if let abandonment {
            requested = abandonment.target
        } else if let asked = variantSelection.withLock({ selection -> Int? in
            defer { selection.requested = nil }
            return selection.requested
        }) {
            requested = asked
        } else {
            return
        }
        if let pending = variantSwitch {
            if pending.spliceTime == nil {
                cancelVariantSwitch(reporting: false)
            } else {
                spliceVariantAudio(releasingHeld: true)
            }
        }
        guard let selected = selectedVariantId, requested != selected,
            !variantSelection.withLock({ $0.rejected.contains(requested) }),
            let target = variants.first(where: { $0.id == requested }),
            let streams = variantStreams[requested], let previous = variantStreams[selected]
        else {
            // The old download was given up for a switch that does not come: it is read again.
            if let abandonment { restartAbandonedDownload(abandonment) }
            return
        }

        var newSwitch = VariantSwitch(
            target: target, streams: streams, previous: previous, audioStream: -1,
            previousVideoTime: lastVideoReadTime)
        newSwitch.audioStream = newSwitch.audioStream(replacing: audioStreamIndex)
        // A variant described by its own read switches as `isSwitchable` said; one described as another is checked once
        // its read describes it (`verifyVariantSwitchTarget`).
        newSwitch.isTargetVerified = input.variantDescription(id: requested) == .described
        if let abandonment {
            // The new variant reads the segment from its start, and the old one's streams are not read meanwhile.
            newSwitch.abandoned = abandonment
            input.joinNext(atSequence: abandonment.sequence)
        }
        variantSwitch = newSwitch
        // Its video and the rendition of the audio track selected; the other renditions stay off.
        applyStreamSelection()
        input.joinNext(atSequence: nil)
        AppLog.info(
            .demuxer,
            "\(streamingName): switching to \(target.width)x\(target.height) at \(target.bandwidth / 1000) kbit/s"
                + (abandonment.map {
                    ", segment \($0.sequence) read from its start (the download of variant \($0.from) given up)"
                } ?? ""))
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
    func admitDuringVariantSwitch(_ pkt: inout AVPacket) -> Bool {
        // A track may have been selected during the read, which runs with `queueLock` released.
        followSelectedAudioTrack()
        guard let pending = variantSwitch else { return true }
        let index = Int(pkt.stream_index)
        let time = pkt.pts != Int64.min ? pkt.pts : pkt.dts
        let audioSplices = pending.audioStream >= 0 && pending.audioStream != audioStreamIndex

        guard let spliceTime = pending.spliceTime else {
            // FFmpeg's DASH demuxer reads the variants by presentation time: see `MediaDemuxer+VariantHold.swift`.
            if holdsNewVariantForOld(), isVideoOfSwitch(index, pending) {
                return admitVideoWaitingForOld(&pkt)
            }
            if index == pending.streams.video {
                // A variant read before hands out the packet it held when it was discarded first, from back then
                // (FFmpeg's catch-up seek skips only what it reads after).
                guard pkt.flags & AV_PKT_FLAG_KEY != 0, time != Int64.min else { return false }
                let keyframe = pkt.data.map { Data(bytes: $0, count: Int(pkt.size)) }
                // The old variant's download was given up: it has queued pictures (and muxed sound) past this keyframe, which
                // are cut from the keyframe of the very time (`spliceAbandoned`), and its sound is not read on.
                if pending.isPreviousAbandoned {
                    return spliceAbandoned(at: time, keyframe: keyframe, pending: pending)
                }
                guard time >= pending.previousVideoTime else { return false }
                return spliceVariantVideo(at: time, keyframe: keyframe)
            }
            let decodeTime = pkt.dts != Int64.min ? pkt.dts : pkt.pts
            if index == pending.previous.video, decodeTime != Int64.min {
                variantSwitch?.previousVideoTime = max(pending.previousVideoTime, decodeTime)
            }
            if audioSplices, index == pending.audioStream {
                variantSwitch?.heldAudio.append(DemuxedAudioPacket(pkt))
                // No keyframe in this much: the new playlist isn't coming.
                if pending.heldAudio.count > 5000 { cancelVariantSwitch() }
                return false
            }
            // The new variant's other streams start with it.
            return !pending.streams.all.contains(index) || pending.previous.all.contains(index)
        }

        if index == pending.previous.video { return false }
        guard audioSplices, index == audioStreamIndex || index == pending.audioStream, time != Int64.min,
            let stream = input.stream(index)
        else {
            return true
        }
        let audioTimebase = stream.pointee.time_base
        let audioSpliceTime = av_rescale_q(spliceTime, timebase, audioTimebase)
        if index == audioStreamIndex {
            guard time >= audioSpliceTime else { return true }
            spliceVariantAudio(releasingHeld: true)
            return false
        }
        if time >= audioSpliceTime {
            variantSwitch?.heldAudio.append(DemuxedAudioPacket(pkt))
            // The old audio ended before the splice (its playlist was stopped): the new one takes over a second on.
            if time - audioSpliceTime > av_rescale_q(1, AVRational(num: 1, den: 1), audioTimebase) {
                spliceVariantAudio(releasingHeld: true)
            }
        }
        return false
    }

    /// Pictures come from the new variant from `time` on. `keyframe` gives the parameter sets when the stream's
    /// extradata has none (MPEG-TS repeats them in band); without either the switch is given up.
    @discardableResult
    func spliceVariantVideo(at time: Int64, keyframe: Data?) -> Bool {
        guard let pending = variantSwitch, let videoIndex = pending.streams.video,
            let stream = input.stream(videoIndex), let codecpar = stream.pointee.codecpar
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
            let fromKeyframe = keyframe.flatMap {
                VideoFormatDescriptionBuilder.parameterSets(fromExtradata: $0, codec: codec)
            }
            parsed = [fromExtradata, fromKeyframe].compactMap { $0 }.first { isComplete($0.sets) }
        } else {
            parsed = (VideoFormatDescriptionBuilder.ParameterSets(), isAnnexBStream)
        }
        guard let parsed, let previousVideo = pending.previous.video,
            let previousStream = input.stream(previousVideo)
        else {
            AppLog.warning(.demuxer, "\(streamingName): no parameter sets for the new variant; staying")
            cancelVariantSwitch()
            return false
        }

        configureVideoStream(stream, index: videoIndex, codec: codec)
        let wasAnnexB = isAnnexBStream
        isAnnexBStream = parsed.isAnnexB
        guard let description = makeVideoFormatDescription(parameterSets: parsed.sets, codecParameters: codecpar)
        else {
            AppLog.warning(.demuxer, "\(streamingName): no format description for the new variant; staying")
            configureVideoStream(previousStream, index: previousVideo, codec: codec)
            isAnnexBStream = wasAnnexB
            cancelVariantSwitch()
            return false
        }
        formatDescription = description
        variantGeneration &+= 1
        variantSwitch?.spliceTime = time
        variantSelection.withLock { $0.selected = pending.target.id }
        AppLog.info(
            .demuxer, "\(streamingName): pictures from \(pending.target.width)x\(pending.target.height) at pts \(time)")
        onVariantChanged?(variantChange(pending.target, at: Double(time) * Double(timebase.num) / Double(timebase.den)))
        if pending.audioStream < 0 || pending.audioStream == audioStreamIndex {
            finishVariantSwitch()
        }
        return true
    }

    /// Audio comes from the new variant: the tracks point at its streams, and the held packets are queued (when
    /// `releasingHeld`; a seek drops them).
    func spliceVariantAudio(releasingHeld: Bool) {
        guard let pending = variantSwitch else { return }
        if pending.audioStream >= 0, let stream = input.stream(pending.audioStream) {
            audioStreamIndex = pending.audioStream
            audioTimebase = stream.pointee.time_base
            if !hasVideo { timebase = audioTimebase }
            if releasingHeld, let spliceTime = pending.spliceTime {
                let audioSpliceTime = av_rescale_q(spliceTime, timebase, audioTimebase)
                for packet in pending.heldAudio where packet.pts >= audioSpliceTime {
                    audioQueue.append(packet)
                }
            }
        }
        finishVariantSwitch()
    }

    /// The variant a switch goes to, once the input has described it by its own read (`DemuxerInput.variantDescription`):
    /// one whose streams are not those described, or don't switch with the variant played (`canSwitch`, which held for
    /// the description), is given up for good. Returns the streams of a switch given up so: a packet of them read now is
    /// dropped. Behind `lock` and `queueLock`.
    func verifyVariantSwitchTarget() -> [Int] {
        guard let pending = variantSwitch, !pending.isTargetVerified, pending.spliceTime == nil else { return [] }
        let description = input.variantDescription(id: pending.target.id)
        if description == .pending { return [] }
        if description == .described, canSwitch(from: pending.previous, to: pending.streams) {
            variantSwitch?.isTargetVerified = true
            return []
        }
        AppLog.warning(
            .demuxer,
            "\(streamingName): \(pending.target.bandwidth / 1000) kbit/s "
                + (description == .rejected
                    ? "has other streams than its manifest tells" : "does not switch with the variant played")
                + "; left out")
        variantSelection.withLock { _ = $0.rejected.insert(pending.target.id) }
        let dropped = pending.streams.all.filter { !pending.previous.all.contains($0) }
        cancelVariantSwitch()
        return dropped
    }

    /// Completes a switch before a seek to `seconds`, which reads from the new variant at once. A variant not yet
    /// described by its own read can't be spliced to (its decoders would be made from the description it was given): the
    /// input describes it now (`DemuxerInput.describeVariant`), and when it can't, the switch is given up and asked for
    /// again, to start after the seek.
    func completeVariantSwitchBeforeSeek(at seconds: Double) {
        beginRequestedVariantSwitch()
        if let pending = variantSwitch, !pending.isTargetVerified, pending.spliceTime == nil,
            input.variantDescription(id: pending.target.id) == .pending
        {
            _ = input.describeVariant(id: pending.target.id, at: seconds)
        }
        _ = verifyVariantSwitchTarget()
        guard let pending = variantSwitch else { return }
        if !pending.isTargetVerified, pending.spliceTime == nil {
            cancelVariantSwitch(reporting: false)
            variantSelection.withLock { selection in
                if selection.requested == nil { selection.requested = pending.target.id }
            }
            return
        }
        if pending.spliceTime == nil {
            // The keyframe waited for the old variant; the seek reads from the new one at its target instead (the parameter
            // sets that were in band with the keyframe are still its).
            let keyframe = pending.candidate?.data
            variantSwitch?.candidate = nil
            variantSwitch?.heldVideo = []
            variantSwitch?.heldOld = []
            let time = timebase.num > 0 ? Int64(seconds * Double(timebase.den) / Double(timebase.num)) : 0
            guard spliceVariantVideo(at: time, keyframe: keyframe) else { return }
        }
        spliceVariantAudio(releasingHeld: false)
    }

    /// At the end of the input a switch either never reached its keyframe, or its audio takes over now.
    func endVariantSwitchAtEOF() {
        guard let pending = variantSwitch else { return }
        if pending.spliceTime == nil {
            // The old variant ended: what it had left to hand over is all it had.
            if pending.candidate != nil {
                spliceHeldVideo()
                if variantSwitch != nil { spliceVariantAudio(releasingHeld: true) }
            } else {
                cancelVariantSwitch()
            }
        } else {
            spliceVariantAudio(releasingHeld: true)
        }
    }

    private func finishVariantSwitch() {
        guard let pending = variantSwitch else { return }
        // Every track now points at the new variant's stream, the one heard or not: with no audio track of this
        // input selected (an external file plays) the switch splices no audio, and selecting a track later must
        // still find the stream read now, not the old variant's, discarded below.
        audioTracks = audioTracks.map { track in
            guard let position = pending.previous.audio.firstIndex(of: track.streamIndex),
                pending.streams.audio.indices.contains(position)
            else { return track }
            return track.with(streamIndex: pending.streams.audio[position])
        }
        for index in pending.previous.all where !pending.streams.all.contains(index) {
            input.setReading(false, stream: index)
        }
        variantSwitch = nil
    }

    /// - Parameter reporting: Report the variant still playing (`onVariantChanged`), unless another was asked for.
    func cancelVariantSwitch(reporting: Bool = true) {
        guard let pending = variantSwitch else { return }
        // The old variant plays on: what was delayed of it is queued, before anything it reads next.
        for old in pending.heldOld { releaseOldVideo(old) }
        for index in pending.streams.all where !pending.previous.all.contains(index) {
            input.setReading(false, stream: index)
        }
        variantSwitch = nil
        // Its download was given up for the new variant's: it is read again, from the segment it was in, after what it had
        // queued of that segment is cut (`restartAbandonedDownload`), so the decoder does not get the same times twice. Not
        // rare: a target still described as another variant (almost every rung at a start) is verified only by this
        // switch's first read, and one that does not match ends here.
        if let abandoned = pending.abandoned {
            AppLog.warning(
                .demuxer, "\(streamingName): a switch that took a download over was given up; reading it again")
            applyStreamSelection()
            restartAbandonedDownload(abandoned)
        }
        // The variant asked for never played: report the one still read, from where reading is.
        if reporting {
            reportVariant(at: readAheadState.withLock { $0 })
        }
    }
}
