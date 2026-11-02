import CFFmpeg
import Foundation

/// The splice of a variant switch on FFmpeg's DASH demuxer, whose reads of the two variants interleave by presentation
/// time. HLS's interleave by decode time, so there a new variant's keyframe comes after every picture of the old that
/// decodes before it; here, with B-frames, either may come first, and either order has to give the same pictures:
///
/// - The old variant's pictures are delayed while the switch looks for its keyframe (`VariantSwitch.heldOld`), so that
///   one the old variant read past the keyframe's decode time, in front of it, is still the old variant's to drop.
/// - The new variant's keyframe, and the pictures after it, are held (`candidate`, `heldVideo`) until the old variant
///   has handed over the pictures that decode before it. The format description changes then: a packet keeps the one it
///   was read with, so none of the new variant's can be queued before.
///
/// Held pictures are `AVPacket`s kept by reference. Each goes through what every picture does when it is queued (the
/// captions in its SEI, the read-ahead's account of what was read), in the order the decoder takes them.
extension MediaDemuxer {
    /// The keyframe a splice waits to make (`VariantSwitch.candidate`).
    struct SpliceCandidate {
        /// Its payload, which gives the parameter sets when the stream's extradata has none.
        let data: Data
        /// The splice time: its presentation time (video time base).
        let time: Int64
        /// Its decode time and time base: the old variant's pictures before it still come.
        let decodeTime: Int64
        let timebase: AVRational
    }

    /// The most pictures of the new variant held for the old to catch up to its keyframe (a second or two): past it the
    /// splice is made, and the old variant's pictures that never came are lost.
    static let heldVideoLimit = 120

    /// The most pictures of the old variant delayed while the keyframe is looked for: more than the depth of the
    /// reordering and of the interleave, a second or so of pictures. The oldest is queued as another comes.
    static let heldOldVideoLimit = 48

    /// Whether the switch is on FFmpeg's DASH demuxer (see the extension's description).
    func holdsNewVariantForOld(in ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        ctx.pointee.iformat.map { String(cString: $0.pointee.name) == "dash" } == true
    }

    /// Whether a video packet of either variant is for `admitVideoWaitingForOld`.
    func isVideoOfSwitch(_ index: Int, _ pending: VariantSwitch) -> Bool {
        index == pending.streams.video || index == pending.previous.video
    }

    /// A video packet of the old or the new variant while the switch has not made its splice (DASH). True when it is
    /// queued by the caller as it is; false when it is dropped, or held to be queued here.
    func admitVideoWaitingForOld(_ pkt: inout AVPacket, in ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard let pending = variantSwitch else { return true }
        let index = Int(pkt.stream_index)
        let time = pkt.pts != Int64.min ? pkt.pts : pkt.dts
        let decodeTime = pkt.dts != Int64.min ? pkt.dts : pkt.pts
        guard decodeTime != Int64.min, let stream = ctx.pointee.streams[index] else {
            return index == pending.previous.video
        }
        let base = stream.pointee.time_base

        if index == pending.streams.video {
            // The keyframe has been found and waits for the old variant: the pictures after it wait too.
            if pending.candidate != nil {
                guard let held = HeldVideoPacket(&pkt) else {
                    cancelVariantSwitch(in: ctx)
                    return false
                }
                variantSwitch?.heldVideo.append(held)
                if (variantSwitch?.heldVideo.count ?? 0) >= Self.heldVideoLimit { spliceHeldVideo(in: ctx) }
                return false
            }
            // A variant read before hands out the packet it held when it was discarded first, from back then
            // (FFmpeg's catch-up seek skips only what it reads after).
            guard pkt.flags & AV_PKT_FLAG_KEY != 0, time != Int64.min else { return false }
            // After every picture the old variant has handed over (the delayed ones are not yet): else the keyframe
            // would repeat one. The next keyframe is the one.
            let oldBase = pending.previous.video.flatMap { ctx.pointee.streams[$0]?.pointee.time_base } ?? base
            guard av_compare_ts(decodeTime, base, pending.previousVideoTime, oldBase) > 0,
                let held = HeldVideoPacket(&pkt)
            else { return false }
            // What the old variant read past the keyframe is not to be queued, the rest it is.
            var oldReachedIt = false
            for old in pending.heldOld {
                if av_compare_ts(old.decodeTime, oldBase, decodeTime, base) < 0 {
                    releaseOldVideo(old, in: ctx)
                } else {
                    oldReachedIt = true
                }
            }
            variantSwitch?.heldOld = []
            variantSwitch?.candidate = SpliceCandidate(
                data: held.payload, time: time, decodeTime: decodeTime, timebase: base)
            variantSwitch?.heldVideo = [held]
            if oldReachedIt { spliceHeldVideo(in: ctx) }
            return false
        }

        // The old variant.
        if let candidate = pending.candidate {
            // Its pictures that decode before the keyframe are still its to hand over; the first that decodes with or
            // after it ends them, and is dropped. Past the end of its way (the splice failed), it plays on.
            if av_compare_ts(decodeTime, base, candidate.decodeTime, candidate.timebase) >= 0 {
                return !spliceHeldVideo(in: ctx)
            }
            variantSwitch?.previousVideoTime = max(pending.previousVideoTime, decodeTime)
            return true
        }
        guard let held = HeldVideoPacket(&pkt) else { return true }
        variantSwitch?.heldOld.append(held)
        if (variantSwitch?.heldOld.count ?? 0) > Self.heldOldVideoLimit,
            let oldest = variantSwitch?.heldOld.removeFirst()
        {
            releaseOldVideo(oldest, in: ctx)
        }
        return false
    }

    /// Queues a picture of the old variant that was delayed: it counts as handed over.
    func releaseOldVideo(_ held: HeldVideoPacket, in ctx: UnsafeMutablePointer<AVFormatContext>) {
        queueHeldVideo(held, in: ctx)
        if let handedOver = variantSwitch?.previousVideoTime {
            variantSwitch?.previousVideoTime = max(handedOver, held.decodeTime)
        }
    }

    /// Queues a held picture as every picture is: its captions, then the queue with the format it plays with, and the
    /// account of what has been read.
    private func queueHeldVideo(_ held: HeldVideoPacket, in ctx: UnsafeMutablePointer<AVFormatContext>) {
        subtitleTracker.processVideoPacket(held.packet)
        videoQueue.append(DemuxedVideoPacket(held, format: videoFormat))
        lastVideoReadTime = held.decodeTime
        recordReadAhead(held.packet.pointee, in: ctx)
    }

    /// Makes the splice that waited for the old variant (`VariantSwitch.candidate`), and queues the pictures held, with
    /// the format they play with. Without the old variant's coming (it ended, a seek, too many held) the pictures it
    /// had left are lost. False when the splice could not be made: the switch is given up, the old variant plays on.
    @discardableResult
    func spliceHeldVideo(in ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        guard let pending = variantSwitch, let candidate = pending.candidate else { return false }
        variantSwitch?.candidate = nil
        variantSwitch?.heldVideo = []
        guard spliceVariantVideo(at: candidate.time, keyframe: candidate.data, in: ctx) else { return false }
        for held in pending.heldVideo { queueHeldVideo(held, in: ctx) }
        return true
    }
}

extension MediaDemuxer.HeldVideoPacket {
    /// Its decode time (its presentation time without one), in its stream's time base.
    var decodeTime: Int64 {
        packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
    }

    /// Its payload, which gives parameter sets when they are in band.
    var payload: Data {
        packet.pointee.data.map { Data(bytes: $0, count: Int(packet.pointee.size)) } ?? Data()
    }
}
