import CFFmpeg
import Foundation
import os

/// An HLS stream read by Nits' own client, not FFmpeg's `hls.c`: the playlists are parsed and placed on a timeline
/// (`HLSTimeline`), the segments downloaded (`HLSSegmentLoader`) and demuxed by FFmpeg's container demuxers
/// (`HLSSegmentReader`), and the packets handed to `MediaDemuxer` through `DemuxerInput`, as a file's are.
///
/// The stream is read as **lanes** (`HLSLane`): a lane for each variant's playlist (its video, and the sound muxed into
/// it) and for each audio and subtitle rendition with a playlist of its own. A lane is read as far as its next packet;
/// `read` hands out the one whose packet decodes first, so the renditions come out interleaved on the shared timeline.
/// Streams are described once, at the opening, in a table (`AVStreamTable`) and keep their index for good: a lane's
/// later runs map onto them.
///
/// **Variants.** Every variant is a lane with streams of its own, which `variantCandidates()` groups as `hls.c`'s
/// programs: the demuxer chooses the start and switches (`MediaDemuxer+Variants.swift`), with the splice it has for any
/// input. It reads the lanes of the variants selected only (`setReading`). Every variant is probed at the opening: its
/// first segment is read as far as FFmpeg's analysis goes (up to `max_analyze_duration` of media: often the whole of
/// a short segment), all variants side by side, as the opening's requests (`HTTPSessionTransport`'s opening limit: held
/// to a small buffer, no adaptive-bitrate sample, but a measure of the link, `openingLinkRate`). The probe is dropped
/// once the streams are described, the one of the variant played included: its download was held to the opening's
/// buffer, and what it left is asked for again unheld (continuing it would hold the start of playback to a link as it
/// is the moment the opening ends). A lane that is not read afterwards downloads nothing more. The first segment of a run
/// the lane then reads is kept by it (`HLSLane.startBody`) for a seek or the demuxer's rewind to its start, which
/// replay what was read and go on with the same download. A lane read again for a switch starts at the segment
/// after the one the picture is at (`HLSLane.catchUp`); the demuxer drops its pictures up to the keyframe it splices at.
///
/// Timeline 0 is the first segment listed when the playlist was first loaded, live or not (so `timelineOrigin` is 0 and
/// nothing is rebased); the window is told from the playlist's own model (`liveWindow`).
///
final class HLSInput: DemuxerInput, @unchecked Sendable {

    /// Whether `url` is one this input opens: a playlist (`.m3u8`, `.m3u`) over HTTP(S), or a saved one, a file whose
    /// text is an HLS manifest (`PlaylistParser.isHLSManifest`; a plain `.m3u` list of tracks is not).
    static func applies(to path: String) -> Bool {
        let url = MediaURL.normalizeMediaPath(path)
        if HTTPSessionTransport.serves(url) {
            guard let parsed = URL(string: url) else { return false }
            return playlistExtensions.contains(parsed.pathExtension.lowercased())
        }
        let file = URL(fileURLWithPath: url)
        guard playlistExtensions.contains(file.pathExtension.lowercased()),
            let data = try? Data(contentsOf: file, options: .mappedIfSafe),
            let text = TextFileEncoding.decode(data)?.text
        else { return false }
        return PlaylistParser.isHLSManifest(content: text)
    }

    private static let playlistExtensions: Set<String> = ["m3u8", "m3u"]

    /// Whether an HTTP(S) address that FFmpeg could not open (`AVERROR_INVALIDDATA`) serves a playlist under another
    /// name or none (`.php?id=`, `.txt`, no extension): its first bytes say. The one request is a range of a few hundred
    /// bytes, answered and dropped. Asked only after FFmpeg failed, so a file never pays for it.
    static func sniffsAsPlaylist(_ url: String, headers: [String: String], interrupt: FFmpegInterrupt) -> Bool {
        guard HTTPSessionTransport.serves(url) else { return false }
        let transport = HTTPSessionTransport(source: url, headers: headers) { interrupt.shouldInterruptFFmpeg }
        guard
            case .input(let input) = transport.open(
                url, offset: 0, end: 512, cookies: nil, cookieOrigin: nil, followsRedirects: true)
        else { return false }
        defer { input.close() }
        let wanted = 16
        var head = [UInt8](repeating: 0, count: wanted)
        var count = 0
        while count < wanted {
            let offset = count
            let read = head.withUnsafeMutableBufferPointer {
                input.read($0.baseAddress! + offset, Int32(wanted - offset))
            }
            if read <= 0 { break }
            count += Int(read)
        }
        var bytes = head.prefix(count)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return bytes.starts(with: Array("#EXTM3U".utf8))
    }

    /// The streams of a reader that a lane of `kind` describes and reads: pictures and sounds of a variant (not cover
    /// art, subtitles in the segments, data), the sound of an audio rendition, the cues of a subtitle rendition.
    static func keeps(_ stream: UnsafeMutablePointer<AVStream>, in kind: HLSLane.Kind) -> Bool {
        let type = stream.pointee.codecpar.pointee.codec_type
        switch kind {
        case .primary:
            if type == AVMEDIA_TYPE_VIDEO { return stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 }
            return type == AVMEDIA_TYPE_AUDIO
        case .audio: return type == AVMEDIA_TYPE_AUDIO
        case .subtitle: return type == AVMEDIA_TYPE_SUBTITLE
        }
    }

    /// A live stream is joined this many target durations behind its edge (RFC 8216 6.3.3).
    static let edgeMargin = 3.0
    /// Bits a second under which the opening's transfers prove the link slow, and the start is a lower rung than the top
    /// (measured by the first client, which prefetched 128 KB segment starts, at TCP's slow start: 4.8 to 62 Mbit/s on
    /// fast links). The probes here read more (a segment, often) from every variant side by side, which
    /// shares the link: the rate is a lower bound of it, so it proves a link slow, never fast; not measured with these
    /// probes on a real link yet.
    static let slowLinkLimit = 3_000_000.0

    private struct StreamInfo {
        let lane: Int
        /// Position among the streams of the lane (`HLSLane.streams`).
        let slot: Int
        let title: String
    }

    /// A variant of a master playlist: the lane of its playlist, and the renditions it plays with.
    private struct Variant {
        let id: Int
        let bandwidth: Int
        let lane: Int
        let audioLanes: [Int]
        let subtitleLanes: [Int]
    }

    private let table: AVStreamTable
    private let transport: HTTPSessionTransport
    private let interrupt: FFmpegInterrupt
    private var lanes: [HLSLane] = []
    /// The lanes as `read` visits them: the variants' first, so that the picture's run anchors its sequence's timestamps
    /// (`HLSTimestampAnchors`) after a seek, and the subtitle renditions' last, read only as far as the others are.
    private var readOrder: [HLSLane] = []
    private var infos: [StreamInfo] = []
    /// How to read each subtitle rendition outside playback, by table stream; set once at the end of `init`.
    private var subtitleSources: [Int: HLSSubtitleWindowSource] = [:]
    /// The variants of a master playlist (none for a media playlist), in the order it lists them.
    private var variants: [Variant] = []
    private let meter: TransferAccount
    /// The timeline's seconds of the last picture handed out: where a lane read again starts.
    private var lastTime = 0.0
    /// The variant being caught up for a switch: its pictures are not where the picture is.
    private var catchingUp: HLSLane?
    let isLivePlaylist: Bool
    let durationSeconds: Double

    let traits = DemuxerInputTraits(hasIndex: false, landsBetweenKeyframes: true, opensAsFile: false)
    let isNetworkSource: Bool
    let streamingName = "HLS"
    let chapters: [MediaChapter.Raw] = []
    let attachedFonts: [AssScript.Font] = []

    /// The timeline starts at zero at the first segment listed at the opening, live or not: nothing to rebase.
    var timelineOrigin: Int64 { 0 }
    var network: (any NetworkReadAccount)? { isNetworkSource ? meter : nil }

    /// What the opening's probes carried, when it proves the link slow: playback then starts on a rung that fits it.
    var openingLinkRate: Double? {
        guard !variants.isEmpty, let rate = transport.openingThroughput, rate < Self.slowLinkLimit else { return nil }
        return rate
    }

    // MARK: Opening

    /// What a playlist the opening loads is for.
    private struct Wanted {
        var url: URL
        var kind: HLSLane.Kind
        var rendition: HLSRendition?
    }

    /// Opens the stream at `url`, a master or a media playlist. Nil when it can't (recorded on `interrupt`).
    init?(url address: String, headers: [String: String], interrupt: FFmpegInterrupt) {
        let url = MediaURL.normalizeMediaPath(address)
        self.interrupt = interrupt
        let began = ContinuousClock.now
        let isLocal = !HTTPSessionTransport.serves(url)
        guard let masterURL = isLocal ? URL(fileURLWithPath: url) : URL(string: url), let table = AVStreamTable() else {
            return nil
        }
        isNetworkSource = MediaURL.isNetworkSource(url)
        self.table = table
        let transport = HTTPSessionTransport(source: url, headers: headers) { interrupt.shouldInterruptFFmpeg }
        self.transport = transport
        meter = TransferAccount(meter: transport.meter)
        let loader = HLSSegmentLoader(transport: transport, allowsFiles: isLocal)
        let shouldAbort: () -> Bool = { interrupt.shouldInterruptFFmpeg }

        func fail(_ message: String, code: Int32 = -EIO) {
            interrupt.recordError(code: code, message: message)
            AppLog.error(.demuxer, "HLS: \(message) for '\(MediaURL.loggable(url))'")
        }

        let first: (data: Data, servedFrom: URL)
        let parsed: HLSPlaylist
        var masterLoaded = began
        do {
            first = try loader.playlist(masterURL)
            parsed = try HLSPlaylist.parse(first.data, url: first.servedFrom)
            masterLoaded = ContinuousClock.now
        } catch let error as HLSSegmentLoadError {
            let code = HLSSegmentReader.code(for: error)
            fail("playlist failed to load (\(error))", code: code)
            return nil
        } catch {
            fail("not a playlist (\(error))")
            return nil
        }

        // The playlists the stream is read from: the media playlist itself, or the master's variants and the renditions
        // they play with (each address once: variants differing in their audio group share a playlist).
        var wanted: [Wanted] = []
        var variables: [String: String] = [:]
        /// Each variant of the master: its bandwidth and the positions in `wanted` of its playlist and renditions.
        var plan: [(bandwidth: Int, video: Int, audio: [Int], subtitles: [Int])] = []
        switch parsed {
        case .media:
            wanted = [Wanted(url: masterURL, kind: .primary, rendition: nil)]
        case .master(let master):
            variables = master.variables
            let listed = Self.ladder(of: master)
            guard !listed.isEmpty else {
                fail("the master playlist lists no variant")
                return nil
            }
            var positions: [String: Int] = [:]
            func position(of url: URL, kind: HLSLane.Kind, rendition: HLSRendition?) -> Int {
                let key = "\(kind):\(url.absoluteString)"
                if let known = positions[key] { return known }
                wanted.append(Wanted(url: url, kind: kind, rendition: rendition))
                positions[key] = wanted.count - 1
                return wanted.count - 1
            }
            for variant in listed {
                let video = position(of: variant.url, kind: .primary, rendition: nil)
                var audio: [Int] = []
                if let group = variant.audioGroup {
                    for rendition in master.renditions(.audio, group: group) {
                        guard let renditionURL = rendition.url else { continue }
                        audio.append(position(of: renditionURL, kind: .audio, rendition: rendition))
                    }
                }
                var subtitles: [Int] = []
                if let group = variant.subtitlesGroup {
                    for rendition in master.renditions(.subtitles, group: group) {
                        guard let renditionURL = rendition.url else { continue }
                        subtitles.append(position(of: renditionURL, kind: .subtitle, rendition: rendition))
                    }
                }
                plan.append((variant.bandwidth, video, audio, subtitles))
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

        let playlistsLoaded = ContinuousClock.now

        // The reference the others are aligned to, and where reading starts: the top of the ladder that loaded.
        let referenceIndex: Int
        if plan.isEmpty {
            referenceIndex = 0
        } else {
            let loaded = plan.filter { slots[$0.video].value?.segments.isEmpty == false }
            guard let best = loaded.max(by: { $0.bandwidth < $1.bandwidth }) else {
                let firstVideo = plan[0].video
                fail(
                    problems[firstVideo].value ?? "the media playlists are missing or list no segments",
                    code: failures[firstVideo].value ?? -EIO)
                return nil
            }
            referenceIndex = best.video
        }
        guard let referencePlaylist = slots[referenceIndex].value, !referencePlaylist.segments.isEmpty else {
            fail(
                problems[referenceIndex].value ?? "the media playlist is missing or lists no segments",
                code: failures[referenceIndex].value ?? -EIO)
            return nil
        }
        let reference = HLSTimeline(referencePlaylist)

        // Where reading starts: the beginning, or for a live stream a few target durations behind its edge.
        let isLive = referencePlaylist.isLive
        let startTime =
            isLive ? max(reference.start, reference.end - Self.edgeMargin * reference.targetDuration) : reference.start
        isLivePlaylist = isLive
        durationSeconds = isLive ? 0 : reference.end - reference.start

        // The offsets of the timestamps, shared by every lane: a sequence's first run anchors it, the others take it.
        let anchors = HLSTimestampAnchors()
        var built: [HLSLane?] = wanted.indices.map { index in
            guard let playlist = slots[index].value, !playlist.segments.isEmpty else { return nil }
            let timeline: HLSTimeline
            if index == referenceIndex {
                timeline = reference
            } else {
                // A variant of the ladder shares the reference's sequence numbers; a rendition's need not.
                guard
                    let aligned = HLSTimeline(
                        playlist, alignedTo: reference, sharesSequenceNumbers: wanted[index].kind == .primary)
                else { return nil }
                timeline = aligned
            }
            return HLSLane(
                kind: wanted[index].kind, url: wanted[index].url, timeline: timeline, variables: variables,
                loader: loader, anchors: anchors, shouldAbort: shouldAbort)
        }

        // Each lane opened at the segment that holds the start, side by side, to learn its streams. One playlist alone
        // is read from its first segment at once; a master's lanes are probed (the start of the segment only) and the
        // ones the demuxer chooses are started afterwards.
        let isProbing = !plan.isEmpty
        let toOpen = built
        let results = toOpen.map { _ in Slot<HLSSegmentReaderError>() }
        DispatchQueue.concurrentPerform(iterations: toOpen.count) { index in
            // A subtitle rendition's streams are known without a read (its first segment may have no cues).
            guard let lane = toOpen[index], lane.kind != .subtitle else { return }
            do throws(HLSSegmentReaderError) {
                if isProbing {
                    try lane.probe(at: startTime)
                } else {
                    try lane.open(at: startTime)
                }
            } catch {
                results[index].set(error)
            }
        }
        let probed = ContinuousClock.now
        var laneOfWanted: [Int: Int] = [:]
        for (index, lane) in built.enumerated() {
            guard let lane else { continue }
            if let error = results[index].value {
                if !isProbing {
                    fail("the first segment failed to open (\(error))", code: error.code)
                    return nil
                }
                // A rung or rendition that fails to open is left out; the stream plays without it.
                AppLog.warning(.demuxer, "HLS: \(wanted[index].url.lastPathComponent) failed to open (\(error))")
                lane.close()
                built[index] = nil
                continue
            }
            let laneIndex = lanes.count
            var slotsOfLane: [HLSLane.StreamSlot] = []
            func register(_ added: UnsafeMutablePointer<AVStream>) {
                infos.append(
                    StreamInfo(lane: laneIndex, slot: slotsOfLane.count, title: wanted[index].rendition?.name ?? ""))
                slotsOfLane.append(
                    HLSLane.StreamSlot(
                        table: Int(added.pointee.index), timebase: added.pointee.time_base,
                        type: added.pointee.codecpar.pointee.codec_type))
            }
            if lane.kind == .subtitle {
                // What FFmpeg's `webvtt` demuxer makes of every segment: one stream of cues in milliseconds.
                if let added = table.addStream() {
                    added.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
                    added.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_WEBVTT
                    added.pointee.time_base = AVRational(num: 1, den: 1000)
                    Self.describe(rendition: wanted[index].rendition, in: added)
                    register(added)
                }
            }
            for stream in lane.readerStreams where Self.keeps(stream, in: lane.kind) {
                guard let added = table.addStream() else { continue }
                Self.describe(stream, in: added)
                Self.describe(rendition: wanted[index].rendition, in: added)
                register(added)
            }
            if isProbing { lane.endProbe() }
            guard !slotsOfLane.isEmpty else {
                // Nothing the input plays: its table streams (none yet added) stay out, the lane is not read.
                lane.close()
                continue
            }
            lane.setStreams(slotsOfLane)
            if isProbing { lane.reposition(at: startTime) }
            laneOfWanted[index] = laneIndex
            lanes.append(lane)
        }
        guard lanes.contains(where: { $0.kind == .primary }) else {
            fail("the stream has nothing to play")
            return nil
        }
        readOrder = [HLSLane.Kind.primary, .audio, .subtitle].flatMap { kind in lanes.filter { $0.kind == kind } }
        // A live stream's renditions are read by playback alone (its window moves).
        if !isLive {
            for lane in lanes where lane.kind == .subtitle {
                guard let slot = lane.streams.first else { continue }
                subtitleSources[slot.table] = HLSSubtitleWindowSource(
                    address: url, headers: headers, allowsFiles: isLocal, url: lane.url, timeline: lane.timeline,
                    variables: variables, anchors: anchors, cookies: { [transport] in transport.cookies })
            }
        }

        // The variants whose playlist opened, with the renditions that did.
        for (position, entry) in plan.enumerated() {
            guard let video = laneOfWanted[entry.video] else { continue }
            variants.append(
                Variant(
                    id: position + 1, bandwidth: entry.bandwidth, lane: video,
                    audioLanes: entry.audio.compactMap { laneOfWanted[$0] },
                    subtitleLanes: entry.subtitles.compactMap { laneOfWanted[$0] }))
        }
        let opened = toOpen.filter { $0 != nil && $0?.kind != .subtitle }.count
        let ms = HLSOpeningMeasure.ms
        let ended = ContinuousClock.now
        let playlists = "playlists=\(plan.isEmpty ? 0 : requests.count)/\(ms(playlistsLoaded - masterLoaded))"
        let probes = "\(isProbing ? "probes" : "firstRun")=\(opened)/\(ms(probed - playlistsLoaded))"
        AppLog.info(
            .demuxer,
            "\(HLSOpeningMeasure.opening) master=\(ms(masterLoaded - began)) \(playlists) \(probes) "
                + "describe=\(ms(ended - probed)) total=\(ms(ended - began))")
        AppLog.info(
            .demuxer,
            "HLS client: \(lanes.count) lane(s), \(infos.count) stream(s)\(variants.isEmpty ? "" : ", \(variants.count) variant(s)")\(isLive ? ", live" : "")"
                + (transport.openingThroughput.map { ", opening \(Int($0 / 1000)) kbit/s" } ?? "")
        )
    }

    /// The variants the stream is played from: those with a picture, when there are any (a sound-only variant is no rung
    /// of a ladder of pictures), and of those the ones that switch with the best (`BANDWIDTH`), the one played: the same
    /// video codec (`CODECS`, Dolby Vision's `SUPPLEMENTAL-CODECS`), `VIDEO-RANGE` and rendition groups. The playlists of
    /// the others, and the renditions only they refer to, are never loaded or probed: Apple's AV1 example, 13 tiers × 5
    /// audio groups, probes 13 pictures and 2 sounds instead of 13 and 10; a ladder of two codecs, one.
    /// `MediaDemuxer.canSwitch` decides more finely once probed. All are kept when a variant doesn't tell its codecs.
    static func ladder(of master: HLSMasterPlaylist) -> [HLSVariant] {
        let withPicture = master.variants.filter { $0.resolution != nil || $0.codecs.flatMap(CodecFamily.video) != nil }
        let candidates = withPicture.isEmpty ? master.variants : withPicture
        guard let best = candidates.max(by: { $0.bandwidth < $1.bandwidth }),
            candidates.allSatisfy({ $0.codecs.flatMap(CodecFamily.video) != nil })
        else { return candidates }
        return candidates.filter { LadderKey($0) == LadderKey(best) }
    }

    /// What variants that switch with each other share (`ladder(of:)`).
    private struct LadderKey: Equatable {
        let codec: String?
        let supplementalCodec: String?
        let range: HLSVideoRange?
        let groups: [String?]

        init(_ variant: HLSVariant) {
            codec = variant.codecs.flatMap(CodecFamily.video)
            supplementalCodec = variant.supplementalCodecs.flatMap(CodecFamily.video)
            range = variant.videoRange
            groups = [variant.audioGroup, variant.videoGroup, variant.subtitlesGroup]
        }
    }

    /// Copies what the decoders and the track lists read of `stream` into the table's `added`.
    private static func describe(_ stream: UnsafeMutablePointer<AVStream>, in added: UnsafeMutablePointer<AVStream>) {
        _ = avcodec_parameters_copy(added.pointee.codecpar, stream.pointee.codecpar)
        added.pointee.time_base = stream.pointee.time_base
        added.pointee.avg_frame_rate = stream.pointee.avg_frame_rate
        added.pointee.r_frame_rate = stream.pointee.r_frame_rate
        added.pointee.sample_aspect_ratio = stream.pointee.sample_aspect_ratio
        added.pointee.disposition = stream.pointee.disposition
        _ = av_dict_copy(&added.pointee.metadata, stream.pointee.metadata, 0)
    }

    /// What an `EXT-X-MEDIA` tells of the rendition's stream: language, name, default / forced.
    private static func describe(rendition: HLSRendition?, in added: UnsafeMutablePointer<AVStream>) {
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

    /// The streams of lane `index`, as the table numbers them.
    private func tableStreams(ofLane index: Int, _ type: AVMediaType? = nil) -> [Int] {
        lanes[index].streams.filter { type == nil || $0.type == type }.map(\.table)
    }

    /// The variants as `hls.c`'s programs group their streams: the variant's own (its picture, the sound muxed into it)
    /// and those of the renditions it names. A variant of a media playlist alone is none.
    func variantCandidates() -> [MediaDemuxer.VariantCandidate]? {
        guard !variants.isEmpty else { return nil }
        return variants.map { variant in
            let own = tableStreams(ofLane: variant.lane)
            let audio =
                tableStreams(ofLane: variant.lane, AVMEDIA_TYPE_AUDIO)
                + variant.audioLanes.flatMap { tableStreams(ofLane: $0) }
            let subtitles = variant.subtitleLanes.flatMap { tableStreams(ofLane: $0) }
            return MediaDemuxer.VariantCandidate(
                id: variant.id, bandwidth: variant.bandwidth,
                streams: MediaDemuxer.VariantStreams(
                    video: tableStreams(ofLane: variant.lane, AVMEDIA_TYPE_VIDEO).first, audio: audio,
                    subtitles: subtitles, all: own.filter { !audio.contains($0) } + audio + subtitles))
        }
    }

    /// The window of the lane the picture is read from (the one read; the first before any is).
    func liveWindow() -> LiveWindow? {
        let primaries = lanes.filter { $0.kind == .primary }
        guard let window = (primaries.first { $0.isRead } ?? primaries.first)?.window else { return nil }
        return window
    }

    /// The source for reading the subtitle rendition behind table stream `index` outside playback
    /// (`EmbeddedSubtitleReader.readSubtitles(hls:in:interrupt:)`); nil for any other stream and for a live stream.
    /// Made once at the opening: readable from any thread.
    func subtitleWindowSource(forStream index: Int) -> HLSSubtitleWindowSource? { subtitleSources[index] }

    /// The opening is done: what it downloaded (the probes, the first segment read to describe the picture, on a link
    /// that may not be the one playback runs on) is no sample of the link for adaptive bitrate.
    func finishOpening() {
        transport.endOpening()
        _ = transport.meter.take()
    }

    // MARK: Reading

    /// Hands out the packet that decodes first of the lanes'. Each lane read holds its next packet, but a subtitle
    /// rendition's lane loads no segment that starts after the picture's and sound's next packet
    /// (`HLSLane.fill(before:picture:)`): a stretch without cues would hold the read until its next cue. A rendition's run
    /// at a break waits for the picture to anchor it (`HLSLane.waitsForAnchor`): the variants' lanes come first.
    func read(_ pkt: inout AVPacket) -> Int32 {
        var best: HLSLane?
        /// The decode time of the next packet of a picture or sound, and of a picture.
        var media: Double?
        var picture: Double?
        for lane in readOrder where lane.isRead {
            if !lane.hasPending {
                let code: Int32
                switch lane.kind {
                case .primary: code = lane.fill()
                case .audio: code = lane.fill(picture: picture)
                case .subtitle: code = lane.fill(before: media, picture: picture)
                }
                if code == MediaDemuxer.averrorEOF || (lane.kind != .primary && code == HLSLane.held) { continue }
                if code < 0 {
                    guard code != HTTPSessionInput.averrorExit, canDrop(lane) else { return code }
                    AppLog.warning(.demuxer, "HLS: a rendition failed (\(code)) and is left out")
                    lane.giveUp()
                    continue
                }
            }
            if lane.kind != .subtitle { media = min(media ?? .infinity, lane.pendingTime) }
            if lane.kind == .primary { picture = min(picture ?? .infinity, lane.pendingTime) }
            if best.map({ lane.pendingTime < $0.pendingTime }) ?? true { best = lane }
        }
        guard let best else { return MediaDemuxer.averrorEOF }
        // Where reading is: the picture's, not a rendition read ahead of it.
        if lanes.lazy.filter({ $0.kind == .primary && $0.isRead }).count < 2 { catchingUp = nil }
        if best.kind == .primary, best !== catchingUp, best.pendingTime.isFinite { lastTime = best.pendingTime }
        best.take(into: &pkt)
        return 0
    }

    /// Whether the stream plays without `lane`: a rendition besides the picture, or a variant while another is read (the
    /// one a switch is catching up; the demuxer's splice never comes and the old one plays on).
    private func canDrop(_ lane: HLSLane) -> Bool {
        lane.kind != .primary || lanes.contains { $0 !== lane && $0.kind == .primary && $0.isRead }
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
        let seconds = Self.seconds(target, stream.pointee.time_base)
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

    /// Back to the start of the timeline: the first segment listed at the opening (the window's start for a live stream).
    func rewind() {
        for lane in lanes where lane.isRead { lane.reposition(at: 0) }
        lastTime = 0
    }

    func setReading(_ isRead: Bool, stream index: Int) {
        guard infos.indices.contains(index) else { return }
        let info = infos[index]
        let lane = lanes[info.lane]
        let wasRead = lane.isRead
        lane.setReading(isRead, slot: info.slot)
        guard lane.isRead, !wasRead else { return }
        // A variant read while another is (a switch): it joins at a segment ahead of the picture. Else a rendition read
        // again starts where the picture is read, not where it was left.
        if lane.kind == .primary, lanes.contains(where: { $0 !== lane && $0.kind == .primary && $0.isRead }) {
            catchingUp = lane
            lane.catchUp(after: lastTime)
        } else {
            lane.reposition(at: lastTime)
        }
    }

    /// Whether stream `index` is read (tests).
    func isReading(stream index: Int) -> Bool {
        guard infos.indices.contains(index) else { return false }
        let info = infos[index]
        let lane = lanes[info.lane]
        return lane.streams.indices.contains(info.slot) && lane.streams[info.slot].isRead
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

/// What the transport measured, for adaptive bitrate: the transfers of the segments read (`NetworkTransferMeter`), each
/// apart from its answer, and the time every request waited for its answer, which `MediaDemuxer.noteRead` reads as the
/// time FFmpeg's `io_open` took (a wait at a live edge, a slow server).
private final class TransferAccount: NetworkReadAccount {
    let transferMeter: NetworkTransferMeter?

    init(meter: NetworkTransferMeter) {
        transferMeter = meter
    }

    var total: Int64 { Int64(transferMeter?.receivedBytes ?? 0) }
    var openSeconds: Double { transferMeter?.answerSeconds ?? 0 }
    var lastOpen: (asked: ContinuousClock.Instant, opened: ContinuousClock.Instant, total: Int64, openSeconds: Double)?
    {
        transferMeter?.lastAnswer.map { ($0.asked, $0.answered, $0.total, $0.seconds) }
    }
}
