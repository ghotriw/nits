import CFFmpeg
import Foundation
import os

/// An HLS stream read by Nits' own client, not FFmpeg's `hls.c`: the playlists are parsed and placed on a timeline
/// (`HLSTimeline`), the segments downloaded (`HLSSegmentLoader`) and demuxed by FFmpeg's container demuxers
/// (`HLSSegmentReader`), and the packets handed to `MediaDemuxer` through `DemuxerInput`, as a file's are.
///
/// The stream is read as **lanes** (`HLSLane`): the variant chosen (its picture, and the sound muxed into it) and each
/// audio rendition with a playlist of its own. A lane is read as far as its next packet; `read` hands out the one
/// whose packet decodes first, so the renditions come out interleaved on the shared timeline. Streams are described
/// once, at the opening, in a table (`AVStreamTable`) and keep their index for good: a lane's later runs map onto them.
///
/// The timeline starts at zero at the first segment of the playlist as first loaded; for a live stream the packets are
/// moved to start at the segment reading began at (`timelineOrigin`), as the FFmpeg path does, and the window is told
/// from the playlist's own model (`liveWindow`).
///
/// This phase reads one variant and the audio renditions; a switch of variants, subtitle renditions and the ABR
/// measurements come with phase 5 of `.agents/hls-client/PLAN.md`. Used behind `HLSInput.isEnabled`.
final class HLSInput: DemuxerInput, @unchecked Sendable {
    /// Whether `MediaDemuxer` opens HTTP(S) `.m3u8` URLs with this client (`NITS_HLS_CLIENT=1`), while both paths exist.
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["NITS_HLS_CLIENT"] == "1" }

    /// Whether `url` is one this input opens: a playlist over HTTP(S).
    static func applies(to url: String) -> Bool {
        guard HTTPSessionTransport.serves(url), let parsed = URL(string: url) else { return false }
        return ["m3u8", "m3u"].contains(parsed.pathExtension.lowercased())
    }

    /// The streams of a reader that the input describes and reads: pictures and sounds (not cover art, subtitles in
    /// the segments, data).
    static func keeps(_ stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let type = stream.pointee.codecpar.pointee.codec_type
        if type == AVMEDIA_TYPE_VIDEO { return stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 }
        return type == AVMEDIA_TYPE_AUDIO
    }

    /// A live stream is joined this many target durations behind its edge (RFC 8216 6.3.3).
    static let edgeMargin = 3.0

    private struct StreamInfo {
        let lane: Int
        /// Position among the streams of the lane (`HLSLane.streams`).
        let slot: Int
        let title: String
    }

    private let table: AVStreamTable
    private let transport: HTTPSessionTransport
    private let interrupt: FFmpegInterrupt
    private var lanes: [HLSLane] = []
    private var infos: [StreamInfo] = []
    private let meter: TransferAccount
    /// Seconds on the timeline that the packets handed out are moved by.
    private let origin: Double
    /// The timeline's seconds of the last packet handed out: where a lane read again starts.
    private var lastTime = 0.0
    let isLivePlaylist: Bool
    let durationSeconds: Double

    let traits = DemuxerInputTraits(hasIndex: false, landsBetweenKeyframes: true)
    let isNetworkSource = true
    let streamingName = "HLS"
    let openingLinkRate: Double? = nil
    let chapters: [MediaChapter.Raw] = []
    let attachedFonts: [AssScript.Font] = []

    var timelineOrigin: Int64 { Int64((origin * Double(AV_TIME_BASE)).rounded()) }
    var network: (any NetworkReadAccount)? { meter }

    // MARK: Opening

    /// Opens the stream at `url`, a master or a media playlist. Nil when it can't (recorded on `interrupt`).
    init?(url: String, headers: [String: String], interrupt: FFmpegInterrupt) {
        self.interrupt = interrupt
        guard let masterURL = URL(string: url), let table = AVStreamTable() else { return nil }
        self.table = table
        let transport = HTTPSessionTransport(source: url, headers: headers) { interrupt.shouldInterruptFFmpeg }
        self.transport = transport
        meter = TransferAccount(meter: transport.meter)
        let loader = HLSSegmentLoader(transport: transport)
        let shouldAbort: () -> Bool = { interrupt.shouldInterruptFFmpeg }

        func fail(_ message: String, code: Int32 = -EIO) {
            interrupt.recordError(code: code, message: message)
            AppLog.error(.demuxer, "HLS: \(message) for '\(MediaURL.loggable(url))'")
        }

        // The playlists the stream is read from: the master's choice of variant and renditions, or the media
        // playlist itself.
        let first: (data: Data, servedFrom: URL)
        let parsed: HLSPlaylist
        do {
            first = try loader.playlist(masterURL)
            parsed = try HLSPlaylist.parse(first.data, url: first.servedFrom)
        } catch let error as HLSSegmentLoadError {
            let code = HLSSegmentReader.code(for: error)
            fail("playlist failed to load (\(error))", code: code)
            return nil
        } catch {
            fail("not a playlist (\(error))")
            return nil
        }

        struct Wanted {
            var url: URL
            var kind: HLSLane.Kind
            var rendition: HLSRendition?
        }
        var wanted: [Wanted] = []
        var variables: [String: String] = [:]
        switch parsed {
        case .media:
            wanted = [Wanted(url: masterURL, kind: .primary, rendition: nil)]
        case .master(let master):
            variables = master.variables
            guard let variant = Self.startVariant(of: master) else {
                fail("the master playlist lists no variant")
                return nil
            }
            wanted = [Wanted(url: variant.url, kind: .primary, rendition: nil)]
            if let group = variant.audioGroup {
                for rendition in master.renditions(.audio, group: group) {
                    guard let renditionURL = rendition.url else { continue }
                    wanted.append(Wanted(url: renditionURL, kind: .audio, rendition: rendition))
                }
            }
        }

        // Fetched side by side: each is a round trip.
        let requests = wanted
        let imported = variables
        let slots = requests.map { _ in Slot<HLSMediaPlaylist>() }
        let failures = requests.map { _ in Slot<Int32>() }
        let problems = requests.map { _ in Slot<String>() }
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            if case .media(let media) = parsed, index == 0 {
                slots[index].set(media)
                return
            }
            do {
                let loaded = try loader.playlist(requests[index].url)
                if case .media(let media) = try HLSPlaylist.parse(
                    loaded.data, url: loaded.servedFrom, variables: imported)
                {
                    slots[index].set(media)
                }
            } catch let error as HLSSegmentLoadError {
                failures[index].set(HLSSegmentReader.code(for: error))
            } catch {
                problems[index].set("not a playlist (\(error))")
            }
        }
        guard let primaryPlaylist = slots[0].value, !primaryPlaylist.segments.isEmpty else {
            fail(
                problems[0].value ?? "the media playlist is missing or lists no segments",
                code: failures[0].value ?? -EIO)
            return nil
        }
        let primary = HLSTimeline(primaryPlaylist)
        var built: [(lane: HLSLane, rendition: HLSRendition?)] = [
            (
                HLSLane(
                    kind: .primary, url: wanted[0].url, timeline: primary, variables: variables, loader: loader,
                    shouldAbort: shouldAbort), nil
            )
        ]
        for index in wanted.indices.dropFirst() {
            // A rendition that failed to load or lists nothing is left out; the stream plays without it.
            guard let playlist = slots[index].value,
                let timeline = HLSTimeline(playlist, alignedTo: primary, sharesSequenceNumbers: false)
            else { continue }
            built.append(
                (
                    HLSLane(
                        kind: .audio, url: wanted[index].url, timeline: timeline, variables: variables,
                        loader: loader, shouldAbort: shouldAbort), wanted[index].rendition
                ))
        }

        // Where reading starts: the beginning, or for a live stream a few target durations behind its edge.
        let isLive = primaryPlaylist.isLive
        let startTime =
            isLive ? max(primary.start, primary.end - Self.edgeMargin * primary.targetDuration) : primary.start
        let startEntry = primary.entry(at: startTime)
        origin = isLive ? (startEntry?.start ?? 0) : 0
        isLivePlaylist = isLive
        durationSeconds = isLive ? 0 : primary.end - primary.start

        // Each lane opened at the segment that holds the start, side by side, to learn its streams.
        let toOpen = built.map(\.lane)
        let results = toOpen.map { _ in Slot<HLSSegmentReaderError>() }
        DispatchQueue.concurrentPerform(iterations: toOpen.count) { index in
            do throws(HLSSegmentReaderError) { try toOpen[index].open(at: startTime) } catch {
                results[index].set(error)
            }
        }
        for (index, entry) in built.enumerated() {
            if let error = results[index].value {
                if index == 0 {
                    fail("the first segment failed to open (\(error))", code: error.code)
                    return nil
                }
                continue
            }
            let laneIndex = lanes.count
            var slotsOfLane: [HLSLane.StreamSlot] = []
            for stream in entry.lane.readerStreams where Self.keeps(stream) {
                guard let added = table.addStream() else { continue }
                Self.describe(stream, in: added, as: entry.rendition)
                infos.append(
                    StreamInfo(lane: laneIndex, slot: slotsOfLane.count, title: entry.rendition?.name ?? ""))
                slotsOfLane.append(
                    HLSLane.StreamSlot(
                        table: Int(added.pointee.index), timebase: added.pointee.time_base,
                        type: added.pointee.codecpar.pointee.codec_type))
            }
            guard !slotsOfLane.isEmpty else { continue }
            entry.lane.setStreams(slotsOfLane)
            lanes.append(entry.lane)
        }
        guard !lanes.isEmpty, lanes[0].kind == .primary else {
            fail("the stream has nothing to play")
            return nil
        }
        AppLog.info(
            .demuxer,
            "HLS client: \(lanes.count) rendition(s), \(infos.count) stream(s)\(isLive ? ", live" : "")")
    }

    /// The variant playback starts on: the top of the ladder by bandwidth, among those with a picture when there are any.
    private static func startVariant(of master: HLSMasterPlaylist) -> HLSVariant? {
        let withPicture = master.variants.filter { $0.resolution != nil || ($0.codecs.map(hasVideoCodec) ?? false) }
        return (withPicture.isEmpty ? master.variants : withPicture).max { $0.bandwidth < $1.bandwidth }
    }

    private static func hasVideoCodec(_ codecs: String) -> Bool {
        let prefixes = ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09", "vp08"]
        return codecs.split(separator: ",").contains { codec in
            prefixes.contains { codec.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
        }
    }

    /// Copies what the decoders and the track lists read of `stream` into the table's `added`.
    private static func describe(
        _ stream: UnsafeMutablePointer<AVStream>, in added: UnsafeMutablePointer<AVStream>, as rendition: HLSRendition?
    ) {
        _ = avcodec_parameters_copy(added.pointee.codecpar, stream.pointee.codecpar)
        added.pointee.time_base = stream.pointee.time_base
        added.pointee.avg_frame_rate = stream.pointee.avg_frame_rate
        added.pointee.r_frame_rate = stream.pointee.r_frame_rate
        added.pointee.sample_aspect_ratio = stream.pointee.sample_aspect_ratio
        added.pointee.disposition = stream.pointee.disposition
        _ = av_dict_copy(&added.pointee.metadata, stream.pointee.metadata, 0)
        guard let rendition else { return }
        if let language = rendition.language { _ = av_dict_set(&added.pointee.metadata, "language", language, 0) }
        _ = av_dict_set(&added.pointee.metadata, "title", rendition.name, 0)
        if rendition.isDefault { added.pointee.disposition |= AV_DISPOSITION_DEFAULT }
        if rendition.isForced { added.pointee.disposition |= AV_DISPOSITION_FORCED }
        if rendition.characteristics.contains("public.accessibility.describes-video") {
            added.pointee.disposition |= AV_DISPOSITION_VISUAL_IMPAIRED
        }
    }

    deinit { close() }

    // MARK: Description

    var streamCount: Int { table.streamCount }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? { table.stream(index) }

    func title(ofStream index: Int) -> String {
        infos.indices.contains(index) ? infos[index].title : ""
    }

    func variantCandidates() -> [MediaDemuxer.VariantCandidate]? { nil }

    func liveWindow() -> LiveWindow? {
        guard var window = lanes.first?.window else { return nil }
        window.start -= origin
        window.end -= origin
        return window
    }

    func finishOpening() {}

    // MARK: Reading

    func read(_ pkt: inout AVPacket) -> Int32 {
        var best: HLSLane?
        for lane in lanes where lane.isRead {
            if !lane.hasPending {
                let code = lane.fill()
                if code == MediaDemuxer.averrorEOF { continue }
                if code < 0 {
                    // A rendition besides the picture that fails is dropped: the stream plays without it, as at the opening.
                    guard lane !== lanes[0], code != HTTPSessionInput.averrorExit else { return code }
                    AppLog.warning(.demuxer, "HLS: a rendition failed (\(code)) and is left out")
                    lane.giveUp()
                    continue
                }
            }
            if best.map({ lane.pendingTime < $0.pendingTime }) ?? true { best = lane }
        }
        guard let best else { return MediaDemuxer.averrorEOF }
        // Where reading is: the picture's, not an audio rendition read ahead of it.
        if best === lanes[0], best.pendingTime.isFinite { lastTime = best.pendingTime }
        best.take(into: &pkt)
        rebase(&pkt)
        return 0
    }

    /// Moves a packet from the playlist's timeline to the zero-based one handed out.
    private func rebase(_ pkt: inout AVPacket) {
        guard origin != 0, let stream = table.stream(Int(pkt.stream_index)) else { return }
        let base = stream.pointee.time_base
        let shift = Int64((origin * Double(base.den) / Double(base.num)).rounded())
        if pkt.pts != Int64.min { pkt.pts -= shift }
        if pkt.dts != Int64.min { pkt.dts -= shift }
    }

    // MARK: Seeking

    func seek(to target: Int64, flags: Int32, streams: (video: Int, audio: Int)) -> Int32 {
        reposition(to: target, of: streams.video >= 0 ? streams.video : streams.audio, flags: flags)
    }

    /// Moves every lane read, as a seek of one stream moves a whole container in FFmpeg (`syncToVideoKeyframe` backs
    /// off on the picture, and the sound must follow).
    func seek(stream index: Int, to target: Int64, flags: Int32) -> Int32 {
        reposition(to: target, of: index, flags: flags)
    }

    /// Every lane read starts again at the segment that holds `target` (in stream `index`'s time base): for a seek
    /// backward that is the keyframe at or before it (a segment starts at one), and the demuxer reads on to the
    /// keyframe it wants (`syncToVideoKeyframe`). A seek forward drops what comes before the target, as `hls.c` does:
    /// the lane of the stream up to its first keyframe at or after it, the others up to it.
    private func reposition(to target: Int64, of index: Int, flags: Int32) -> Int32 {
        guard let stream = table.stream(index), infos.indices.contains(index) else { return -1 }
        let seconds = Self.seconds(target, stream.pointee.time_base) + origin
        let seekLane = lanes[infos[index].lane]
        let isForward = flags & AVSEEK_FLAG_BACKWARD == 0
        guard !isForward || seekLane.contains(seconds) else { return -1 }
        let type = stream.pointee.codecpar.pointee.codec_type
        for lane in lanes where lane.isRead {
            let keyframeOf = lane === seekLane && type == AVMEDIA_TYPE_VIDEO ? type : nil
            lane.reposition(
                at: seconds, landing: isForward ? HLSLane.Landing(time: seconds, keyframeOf: keyframeOf) : nil)
        }
        lastTime = seconds
        return 0
    }

    /// Back to where reading began: the start, or a live stream's join point (`origin`), as `FFmpegInput` rewinds to
    /// `timelineOrigin`.
    func rewind() {
        for lane in lanes where lane.isRead { lane.reposition(at: origin) }
        lastTime = origin
    }

    func setReading(_ isRead: Bool, stream index: Int) {
        guard infos.indices.contains(index) else { return }
        let info = infos[index]
        let lane = lanes[info.lane]
        let wasRead = lane.isRead
        lane.setReading(isRead, slot: info.slot)
        // A rendition read again starts where the picture is read, not where it was left.
        if lane.isRead, !wasRead { lane.reposition(at: lastTime) }
    }

    func closeUnusedRepresentations() {}

    func prepareSeek(reading indices: [Int]) {}

    func close() {
        for lane in lanes { lane.close() }
    }

    private static func seconds(_ ticks: Int64, _ base: AVRational) -> Double {
        Double(ticks) * Double(base.num) / Double(base.den)
    }
}

/// A value one iteration of `concurrentPerform` sets and the caller reads after it.
private final class Slot<Value: Sendable>: @unchecked Sendable {
    private let stored = OSAllocatedUnfairLock<Value?>(initialState: nil)

    func set(_ value: Value) {
        stored.withLock { $0 = value }
    }

    var value: Value? { stored.withLock { $0 } }
}

/// What the transport measured, for adaptive bitrate (phase 5 reads it).
private final class TransferAccount: NetworkReadAccount {
    let transferMeter: NetworkTransferMeter?

    init(meter: NetworkTransferMeter) {
        transferMeter = meter
    }

    var total: Int64 { Int64(transferMeter?.receivedBytes ?? 0) }
    var openSeconds: Double { 0 }
    var lastOpen: (asked: ContinuousClock.Instant, opened: ContinuousClock.Instant, total: Int64, openSeconds: Double)?
    {
        nil
    }
}
