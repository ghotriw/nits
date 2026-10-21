import CFFmpeg
import Foundation
import os

/// In-band embedded subtitle tracker for `MediaDemuxer`: the selected subtitle track as packets pass (as mpv and VLC
/// take embedded subtitles), for every source: a read of the whole file would read every byte of it, slow on a network
/// volume.
///
/// Concurrency model & Locking:
/// - State is protected by its own lightweight lock `liveSubtitleState`, decoupled from the demuxer's I/O `lock`.
///   UI readers (`getLiveSubtitleDocument()`, `subtitleWindow(around:readAhead:)`, `liveSubtitleSelection`) never
///   contend on the I/O lock.
/// - Mutating methods that touch `selectedStreamIndex` or `liveBitmapDecoder` (`selectTrack`, `readPacket`,
///   `beginSeek`, `endSeek`) MUST be called exclusively under `MediaDemuxer.lock`.
/// - Lock hierarchy: `MediaDemuxer.lock` -> `liveSubtitleState` or `stash` (never the reverse, never one inside the other).
final class LiveSubtitleTracker: @unchecked Sendable {
    struct LiveSubtitleState {
        /// What makes a text cue the same one read again (a seek back, a window read).
        struct CueKey: Hashable {
            let milliseconds: Int64
            let text: String

            init(_ cue: SubtitleCue) {
                milliseconds = Int64((cue.startTime * 1000).rounded())
                text = cue.text
            }
        }

        var cues: [SubtitleCue] = []
        var cueKeys: Set<CueKey> = []
        var imageCues: [SubtitleImageCue] = []
        /// The script of the selected ASS / SSA track: header and fonts from the stream, events as they are read.
        var assScript: AssScript?
        /// Payloads of the events in `assScript`, to leave out an event read again.
        var assPayloads: Set<String> = []
        var version: Int = 0
        /// Counts track selections, so a read made for a track since left isn't merged (`mergeLiveSubtitles`).
        var selection = 0
        /// Stream of the selected track, `-1` for none: the video stream for closed captions in its pictures.
        var streamIndex = -1
        /// The CEA-608 field of a selected closed-caption track.
        var captionField: Int?
        /// The closed-caption screens in the lists (`ClosedCaptionDecoder.Screen`), cleared ones too, by time and one
        /// a step (`Screen.step`): a screen ends the one before it. `cue` indexes `cues`; `nil` for a clear.
        /// `provisional`: `Screen.isProvisional`.
        var captionScreens: [(time: Double, cue: Int?, provisional: Bool)] = []
        /// Timeline ranges whose packets of the selected stream are in the lists: spans read before the last seek and
        /// windows merged, sorted and apart. The span being read now runs from `spanStart` to `readAheadSeconds`, and on
        /// as playback reads: `nil` while a seek is under way, `infinity` when the reads were at the end already.
        var coverage: [ClosedRange<Double>] = []
        var spanStart: Double?
        /// The stretch of reading playback is in: a seek starts another (`SubtitleImageCue.readSpan`).
        var readSpan = 0
        /// Times at which sets playback read in `readSpan` ended the set before them (`BitmapSubtitleDecoder.Output`),
        /// applied again after a window merge: the set they end may only arrive with it.
        var bitmapTruncations: [Double] = []
        /// What playback read of the selected track before it was chosen, until a window read takes it
        /// (`takeStashedSubtitles`).
        var stashed: SubtitlePacketStash.Snapshot?

        mutating func cover(_ range: ClosedRange<Double>) {
            var merged = range
            coverage.removeAll { other in
                guard other.overlaps(merged) else { return false }
                merged = min(merged.lowerBound, other.lowerBound)...max(merged.upperBound, other.upperBound)
                return true
            }
            coverage.append(merged)
            coverage.sort { $0.lowerBound < $1.lowerBound }
        }
    }

    /// Stream index of the selected subtitle track, whose packets go to `processPacket`, or -1 if none (also for
    /// closed captions in the video stream's pictures, which `processVideoPacket` reads).
    /// Modified under `MediaDemuxer.lock`; can be read under `MediaDemuxer.lock` without locking `liveSubtitleState`.
    private(set) var selectedStreamIndex: Int = -1

    /// Decodes the selected track when it is a bitmap one; used under the demuxer's main lock, like `processPacket`.
    private var liveBitmapDecoder: BitmapSubtitleDecoder?
    /// Decodes the selected track when it is closed captions; used under the demuxer's main lock, like the above.
    private var liveCaptionDecoder: ClosedCaptionDecoder?

    /// Live in-band subtitle state is guarded by its own lightweight lock, NOT the demuxer's I/O lock.
    /// Lock order: demuxer lock -> liveSubtitleState (never the reverse).
    private let liveSubtitleState = OSAllocatedUnfairLock(initialState: LiveSubtitleState())
    /// The packets of every subtitle stream playback reads, for a track chosen later. Changed under
    /// `MediaDemuxer.lock`, but its own lock lets `noteSubtitleReadsStart` reach it without that one.
    private let stash = OSAllocatedUnfairLock(initialState: SubtitlePacketStash())
    /// Which streams of the file carry subtitles, by index (`readPacket`). Under `MediaDemuxer.lock`.
    private var subtitleStreams: [Bool] = []

    init() {}

    var version: Int {
        liveSubtitleState.withLock { $0.version }
    }

    /// Identifies the current track selection and reading stretch for `mergeLiveSubtitles`, with the stream to read
    /// for it (`-1` for none) and, for closed captions, their field. Never touches the I/O lock.
    var liveSubtitleSelection: (id: Int, streamIndex: Int, captionField: Int?, span: Int) {
        liveSubtitleState.withLock { ($0.selection, $0.streamIndex, $0.captionField, $0.readSpan) }
    }

    func selectTrack(
        id trackId: Int?,
        tracks: [SubtitleTrack],
        in formatCtx: UnsafeMutablePointer<AVFormatContext>?,
        readAhead: Double
    ) {
        let track = trackId.flatMap { id in tracks.first { $0.id == id } }
        let streamIndex = track?.streamIndex ?? -1
        liveBitmapDecoder = nil
        liveCaptionDecoder = nil
        if let field = track?.closedCaptionField, let formatCtx, streamIndex >= 0,
            streamIndex < Int(formatCtx.pointee.nb_streams), let stream = formatCtx.pointee.streams[streamIndex]
        {
            liveCaptionDecoder = ClosedCaptionDecoder(field: field, stream: stream)
        }
        // Captions in the video's pictures come through `processVideoPacket`: the video's packets must not go to the
        // subtitle path, and a caption stream FFmpeg can't decode isn't read as text.
        let readsCaptionStream = track?.captionsInVideo == false && liveCaptionDecoder != nil
        self.selectedStreamIndex = track?.closedCaptionField == nil || readsCaptionStream ? streamIndex : -1

        // Closed captions in the video's pictures aren't kept: a window read gets them.
        let stashed =
            track?.captionsInVideo == false
            ? formatCtx.flatMap { ctx in
                stash.withLockUnchecked { $0.snapshot(of: streamIndex, in: ctx, readAhead: readAhead) }
            } : nil
        liveSubtitleState.withLock { state in
            state.stashed = stashed
            state.streamIndex = streamIndex
            state.captionField = track?.closedCaptionField
            state.captionScreens.removeAll()
            state.cues.removeAll()
            state.cueKeys.removeAll()
            state.imageCues.removeAll()
            state.assScript = nil
            state.assPayloads.removeAll()
            state.version += 1
            state.selection += 1
            state.coverage.removeAll()
            state.readSpan += 1
            state.bitmapTruncations.removeAll()
            // Nothing read since opening (`-infinity`): reads start at the beginning. At the end, nothing more comes.
            state.spanStart = readAhead.isFinite ? readAhead : (readAhead < 0 ? 0 : .infinity)
        }

        if let trackId, let track = tracks.first(where: { $0.id == trackId }) {
            if track.format == .ass, let formatCtx,
                track.streamIndex < Int(formatCtx.pointee.nb_streams),
                let stream = formatCtx.pointee.streams[track.streamIndex]
            {
                let script = AssScript(
                    header: EmbeddedSubtitleReader.assHeader(of: stream),
                    fonts: EmbeddedSubtitleReader.attachedFonts(in: formatCtx))
                liveSubtitleState.withLock { $0.assScript = script }
            }
            if track.format == .bitmap, let formatCtx,
                track.streamIndex < Int(formatCtx.pointee.nb_streams),
                let stream = formatCtx.pointee.streams[track.streamIndex]
            {
                liveBitmapDecoder = BitmapSubtitleDecoder(stream: stream)
            }
            AppLog.info(
                .subtitles,
                "Subtitle track selected: id=\(trackId), streamIndex=\(track.streamIndex), title='\(track.title)'"
            )
        }
    }

    /// Phase 1 of seek: flush bitmap decoder, cover already read range, clear spanStart (so concurrent window reads
    /// return nil during seek I/O), bump readSpan and clear bitmap truncations for the upcoming reads.
    ///
    /// The subtitle packets read so far stay in the lists; reads go on from the seek target (`endSeek(at:)`), once the
    /// seek's own reads (which leave the read-ahead mark where it was) are done.
    func beginSeek(previousReadAhead: Double) {
        liveBitmapDecoder?.flush()
        addCaptions(liveCaptionDecoder?.reset() ?? [])
        liveSubtitleState.withLock { state in
            if let start = state.spanStart, previousReadAhead >= start { state.cover(start...previousReadAhead) }
            state.spanStart = nil
            // The seek's own reads already belong to the next stretch: they start where it lands.
            state.readSpan += 1
            state.bitmapTruncations.removeAll()
        }
        stash.withLock { $0.endStretch(at: previousReadAhead) }
    }

    /// Phase 2 of seek: restore spanStart to the landed position after seek's own reads are complete.
    /// Called in defer: a keyframe search that backs off, or reads to the end, would otherwise leave them ahead.
    func endSeek(at seconds: Double) {
        liveSubtitleState.withLock { state in
            state.spanStart = seconds
        }
        stash.withLock { $0.startStretch(at: seconds) }
    }

    /// Returns a SubtitleDocument with all cues collected in-band so far for the active subtitle track.
    /// Never touches the I/O lock, so it is safe to call from the main thread during network reads/seeks.
    func getLiveSubtitleDocument() -> SubtitleDocument {
        let (cues, imageCues, script) = liveSubtitleState.withLock { ($0.cues, $0.imageCues, $0.assScript) }
        // A closed-caption cue a clear replaced has no text left (`addCaption`).
        return SubtitleDocument(cues: cues.filter { !$0.text.isEmpty }, imageCues: imageCues, assScript: script)
    }

    /// The part of the timeline a window read (`EmbeddedSubtitleReader.readSubtitles`) must read so the selected track
    /// is whole at `time` (track time: the subtitle delay applied), less what the lists hold already; `nil` when
    /// nothing is missing.
    ///
    /// It starts `windowPreroll` before `time` and ends where playback reads from (`spanStart`): what lies between was
    /// read before the track was chosen, or skipped by a seek. When `time` is past everything playback has read (a
    /// negative subtitle delay shows the track ahead of the picture by more than playback reads ahead), it ends
    /// `windowLookahead` past `time` instead, so such a track is read ahead in steps. While a seek is under way there is
    /// none: its landing asks again. It starts past what the lists hold already, and ends before what they hold up to
    /// its end.
    func subtitleWindow(around time: Double, readAhead: Double) -> ClosedRange<Double>? {
        let start = max(0, time - EmbeddedSubtitleReader.windowPreroll)
        let window: ClosedRange<Double>? = liveSubtitleState.withLock { state in
            guard let spanStart = state.spanStart else { return nil }
            let isAhead = time > max(spanStart, readAhead)
            let end = isAhead ? time + EmbeddedSubtitleReader.windowLookahead : spanStart
            guard end > start else { return nil }
            // What the lists hold from the start on isn't read again.
            var covered = state.coverage
            if readAhead >= spanStart { covered.append(spanStart...readAhead) }
            var lower = start
            while let range = covered.first(where: { $0.contains(lower) && $0.upperBound > lower }) {
                lower = range.upperBound
            }
            // Read ahead again only once half of the last lookahead is used: a read per step, not per time tick.
            if isAhead, lower > time + EmbeddedSubtitleReader.windowLookahead / 2 { return nil }
            // Nor what they hold up to the end (stretches playback read before the track was chosen, `mergeStashed`);
            // a range held inside the window is read again, not left as a gap before the time.
            var upper = end
            while let range = covered.first(where: { $0.contains(upper) && $0.lowerBound < upper }) {
                upper = range.lowerBound
            }
            return lower < upper ? lower...upper : nil
        }
        return window
    }

    func noteSubtitleReadsStart(at seconds: Double) {
        liveSubtitleState.withLock { state in
            if let start = state.spanStart, seconds > start { state.spanStart = seconds }
        }
        stash.withLock { $0.noteReadsStart(at: seconds) }
    }

    @discardableResult
    func mergeLiveSubtitles(
        _ packets: EmbeddedSubtitleReader.Packets, covering range: ClosedRange<Double>, selection: Int, span: Int
    ) -> Bool {
        liveSubtitleState.withLock { state in
            guard state.selection == selection, state.readSpan == span else { return false }
            // The window ends where playback reads from, or reads on ahead of it: it joins the stretch being read.
            Self.add(packets, span: state.readSpan, replaying: state.bitmapTruncations, to: &state)
            state.cover(range)
            state.version += 1
            return true
        }
    }

    /// The packets playback read of the track before it was chosen (`SubtitlePacketStash`), taken once by the window
    /// reads that follow a selection, with the selection and reading stretch they are for (`mergeStashed`).
    func takeStashedSubtitles() -> (snapshot: SubtitlePacketStash.Snapshot, selection: Int, span: Int)? {
        liveSubtitleState.withLock { state in
            defer { state.stashed = nil }
            return state.stashed.map { ($0, state.selection, state.readSpan) }
        }
    }

    /// Adds what the stretches of a stash snapshot decoded to (`EmbeddedSubtitleReader.decode`), one `Packets` a
    /// stretch, for the selection `selection`. The current stretch joins the one being read, unless a seek (`span`)
    /// has ended it since; a set from an earlier one is never ended by a later stretch's. Dropped (returning `false`)
    /// if another track was chosen meanwhile.
    @discardableResult
    func mergeStashed(
        _ decoded: [EmbeddedSubtitleReader.Packets], of snapshot: SubtitlePacketStash.Snapshot, selection: Int,
        span: Int
    ) -> Bool {
        liveSubtitleState.withLock { state in
            guard state.selection == selection else { return false }
            for (position, (stretch, packets)) in zip(snapshot.stretches, decoded).enumerated() {
                if stretch.isCurrent, state.readSpan == span {
                    Self.add(packets, span: state.readSpan, replaying: state.bitmapTruncations, to: &state)
                    // As read by playback: a window merged later may bring the set one of these ends.
                    state.bitmapTruncations += packets.bitmapOutputs.compactMap(\.truncatePreviousAt)
                } else {
                    // Below every stretch of reading counted (`readSpan`), one apart each.
                    Self.add(packets, span: -1 - position, replaying: [], to: &state)
                }
                state.cover(stretch.range)
            }
            state.version += 1
            return true
        }
    }

    private static func add(
        _ packets: EmbeddedSubtitleReader.Packets, span: Int, replaying truncations: [Double],
        to state: inout LiveSubtitleState
    ) {
        for cue in packets.cues { addLiveCue(cue, to: &state) }
        for screen in packets.captionScreens { addCaption(screen, to: &state) }
        state.imageCues.merge(window: packets.bitmapOutputs, span: span, replaying: truncations)
        for event in packets.assEvents where state.assScript != nil {
            guard state.assPayloads.insert(event.payload).inserted else { continue }
            state.assScript?.events.append(event)
        }
    }

    /// Forgets the packets read so far: the demuxer read the start of the file to describe it, and reads it again from
    /// the beginning. Under `MediaDemuxer.lock`.
    func resetStash() {
        stash.withLock { $0 = SubtitlePacketStash() }
    }

    /// A packet playback read: kept for a track chosen later, and taken by the selected one. Under
    /// `MediaDemuxer.lock`.
    func readPacket(_ pkt: UnsafeMutablePointer<AVPacket>, in formatCtx: UnsafeMutablePointer<AVFormatContext>) {
        let index = Int(pkt.pointee.stream_index)
        // Picture and sound packets, nearly all of them, skip the stash's lock. MPEG-TS can add streams as it reads.
        if subtitleStreams.count != Int(formatCtx.pointee.nb_streams) {
            subtitleStreams = (0..<Int(formatCtx.pointee.nb_streams)).map { position in
                formatCtx.pointee.streams[position]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
            }
        }
        if subtitleStreams.indices.contains(index), subtitleStreams[index] {
            stash.withLockUnchecked { $0.add(pkt, in: formatCtx) }
        }
        if index == selectedStreamIndex { processPacket(pkt, in: formatCtx) }
    }

    private func processPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>, in formatCtx: UnsafeMutablePointer<AVFormatContext>?
    ) {
        guard let formatCtx, selectedStreamIndex >= 0,
            selectedStreamIndex < Int(formatCtx.pointee.nb_streams),
            let stream = formatCtx.pointee.streams[selectedStreamIndex]
        else { return }

        if let liveCaptionDecoder {
            addCaptions(liveCaptionDecoder.decode(pkt))
            return
        }
        if let liveBitmapDecoder {
            let output = liveBitmapDecoder.decode(pkt)
            liveSubtitleState.withLock { state in
                if let time = output.truncatePreviousAt { state.bitmapTruncations.append(time) }
                // A seek back decodes sets that are there already; one read before a seek isn't ended by this one.
                if state.imageCues.apply(output, deduplicating: true, span: state.readSpan) { state.version += 1 }
            }
            return
        }

        let timebase = stream.pointee.time_base
        let codecId = stream.pointee.codecpar.pointee.codec_id
        // Only a selected ASS track keeps events (the script is there then); other codecs aren't decoded for them.
        if liveSubtitleState.withLock({ $0.assScript != nil }),
            let event = EmbeddedSubtitleReader.assEvent(from: pkt, timebase: timebase)
        {
            liveSubtitleState.withLock { state in
                // A seek back reads events again; libass drops a repeated ReadOrder, but the list shouldn't grow.
                guard state.assScript != nil, state.assPayloads.insert(event.payload).inserted else { return }
                state.assScript?.events.append(event)
                state.version += 1
            }
        }
        guard
            let newCue = EmbeddedSubtitleReader.parseSubtitleCue(
                pkt: pkt, timebase: timebase, codecId: codecId, cueIndex: 0)
        else {
            return
        }

        liveSubtitleState.withLock { state in
            if Self.addLiveCue(newCue, to: &state) { state.version += 1 }
        }
    }

    /// The closed captions of the selected track in a video packet playback decodes: every picture that reaches the
    /// decoder, and only those, as the captions' screens build on each other. Under `MediaDemuxer.lock`.
    func processVideoPacket(_ pkt: UnsafePointer<AVPacket>) {
        guard let liveCaptionDecoder, liveCaptionDecoder.readsVideo else { return }
        addCaptions(liveCaptionDecoder.decode(pkt))
    }

    /// The closed captions of the last pictures, held back for those shown before them: the input has ended. Under
    /// `MediaDemuxer.lock`.
    func finishCaptions() {
        guard let liveCaptionDecoder else { return }
        addCaptions(liveCaptionDecoder.finish())
    }

    private func addCaptions(_ screens: [ClosedCaptionDecoder.Screen]) {
        guard !screens.isEmpty else { return }
        liveSubtitleState.withLock { state in
            var changed = false
            for screen in screens { changed = Self.addCaption(screen, to: &state) || changed }
            if changed { state.version += 1 }
        }
    }

    /// Adds a closed-caption screen: it ends the cue on screen when it comes, and its text (unless it clears the
    /// screen) is a cue up to the next screen, `ClosedCaptionDecoder.holdLimit` at most.
    ///
    /// A step the lists have a screen for already keeps one read through it over a provisional one, else the fuller
    /// one, by rows, then characters: read again (a seek back, a window read), the step gives the same screen, unless
    /// the decoder started (on an empty screen) while the captions were up, and then its screens lack what came
    /// before. A cue a clear replaces keeps its place in `cues` with no text.
    @discardableResult
    static func addCaption(_ screen: ClosedCaptionDecoder.Screen, to state: inout LiveSubtitleState) -> Bool {
        let step = screen.step
        var low = 0
        var high = state.captionScreens.count
        while low < high {
            let middle = (low + high) / 2
            if ClosedCaptionDecoder.step(of: state.captionScreens[middle].time) < step {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low
        let cue = SubtitleCue(
            id: state.cues.count + 1, startTime: screen.time, endTime: screen.time, text: screen.text,
            alignment: screen.alignment)
        if index < state.captionScreens.count, ClosedCaptionDecoder.step(of: state.captionScreens[index].time) == step {
            let listed = state.captionScreens[index]
            let weight = { (text: String) in (text.split(separator: "\n").count, text.count) }
            let replaces =
                listed.provisional != screen.isProvisional
                ? listed.provisional : weight(screen.text) > weight(listed.cue.map { state.cues[$0].text } ?? "")
            guard replaces else { return false }
            var cueIndex = listed.cue
            if let listedCue = listed.cue {
                state.cues[listedCue] = SubtitleCue(
                    id: state.cues[listedCue].id, startTime: cue.startTime, endTime: cue.endTime, text: cue.text,
                    alignment: cue.alignment)
            } else if !screen.text.isEmpty {
                state.cues.append(cue)
                cueIndex = state.cues.count - 1
            }
            state.captionScreens[index] = (screen.time, cueIndex, screen.isProvisional)
        } else {
            if !screen.text.isEmpty { state.cues.append(cue) }
            state.captionScreens.insert(
                (screen.time, screen.text.isEmpty ? nil : state.cues.count - 1, screen.isProvisional), at: index)
        }
        // The screen ends the one before it, and is ended by the next.
        for position in max(index - 1, 0)...index {
            guard let listed = state.captionScreens[position].cue else { continue }
            let next =
                state.captionScreens.indices.contains(position + 1)
                ? state.captionScreens[position + 1].time : .infinity
            let shown = state.cues[listed]
            state.cues[listed] = SubtitleCue(
                id: shown.id, startTime: shown.startTime,
                endTime: min(shown.startTime + ClosedCaptionDecoder.holdLimit, next), text: shown.text,
                alignment: shown.alignment)
        }
        return true
    }

    /// Adds a text cue unless the list has it (a seek back or a window read reads it again); ids follow the list.
    @discardableResult
    private static func addLiveCue(_ cue: SubtitleCue, to state: inout LiveSubtitleState) -> Bool {
        // A cue read again has the same timestamp; a set of keys keeps a long track from comparing every cue.
        guard state.cueKeys.insert(LiveSubtitleState.CueKey(cue)).inserted else { return false }
        state.cues.append(
            SubtitleCue(
                id: state.cues.count + 1, startTime: cue.startTime, endTime: cue.endTime, text: cue.text,
                alignment: cue.alignment, rawPayload: cue.rawPayload))
        return true
    }
}
