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
/// - Mutating methods that touch `selectedStreamIndex` or `liveBitmapDecoder` (`selectTrack`, `processPacket`,
///   `beginSeek`, `endSeek`) MUST be called exclusively under `MediaDemuxer.lock`.
/// - Lock hierarchy: `MediaDemuxer.lock` -> `liveSubtitleState` (never the reverse).
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
        /// Stream of the selected track, `-1` for none.
        var streamIndex = -1
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

    /// Stream index of the selected subtitle track, or -1 if none.
    /// Modified under `MediaDemuxer.lock`; can be read under `MediaDemuxer.lock` without locking `liveSubtitleState`.
    private(set) var selectedStreamIndex: Int = -1

    /// Decodes the selected track when it is a bitmap one; used under the demuxer's main lock, like `processPacket`.
    private var liveBitmapDecoder: BitmapSubtitleDecoder?

    /// Live in-band subtitle state is guarded by its own lightweight lock, NOT the demuxer's I/O lock.
    /// Lock order: demuxer lock -> liveSubtitleState (never the reverse).
    private let liveSubtitleState = OSAllocatedUnfairLock(initialState: LiveSubtitleState())

    init() {}

    var version: Int {
        liveSubtitleState.withLock { $0.version }
    }

    /// Identifies the current track selection and reading stretch for `mergeLiveSubtitles`, with the stream to read
    /// for it (`-1` for none). Never touches the I/O lock.
    var liveSubtitleSelection: (id: Int, streamIndex: Int, span: Int) {
        liveSubtitleState.withLock { ($0.selection, $0.streamIndex, $0.readSpan) }
    }

    func selectTrack(
        id trackId: Int?,
        tracks: [SubtitleTrack],
        in formatCtx: UnsafeMutablePointer<AVFormatContext>?,
        readAhead: Double
    ) {
        let streamIndex = trackId.flatMap { id in tracks.first { $0.id == id }?.streamIndex } ?? -1
        self.selectedStreamIndex = streamIndex

        liveSubtitleState.withLock { state in
            state.streamIndex = streamIndex
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
        liveBitmapDecoder = nil

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
        liveSubtitleState.withLock { state in
            if let start = state.spanStart, previousReadAhead >= start { state.cover(start...previousReadAhead) }
            state.spanStart = nil
            // The seek's own reads already belong to the next stretch: they start where it lands.
            state.readSpan += 1
            state.bitmapTruncations.removeAll()
        }
    }

    /// Phase 2 of seek: restore spanStart to the landed position after seek's own reads are complete.
    /// Called in defer: a keyframe search that backs off, or reads to the end, would otherwise leave them ahead.
    func endSeek(at seconds: Double) {
        liveSubtitleState.withLock { state in
            state.spanStart = seconds
        }
    }

    /// Returns a SubtitleDocument with all cues collected in-band so far for the active subtitle track.
    /// Never touches the I/O lock, so it is safe to call from the main thread during network reads/seeks.
    func getLiveSubtitleDocument() -> SubtitleDocument {
        let (cues, imageCues, script) = liveSubtitleState.withLock { ($0.cues, $0.imageCues, $0.assScript) }
        return SubtitleDocument(cues: cues, imageCues: imageCues, assScript: script)
    }

    /// The part of the timeline a window read (`EmbeddedSubtitleReader.readSubtitles`) must read so the selected track
    /// is whole at `time` (track time: the subtitle delay applied), less what the lists hold already; `nil` when
    /// nothing is missing.
    ///
    /// It starts `windowPreroll` before `time` and ends where playback reads from (`spanStart`): what lies between was
    /// read before the track was chosen, or skipped by a seek. When `time` is past everything playback has read (a
    /// negative subtitle delay shows the track ahead of the picture by more than playback reads ahead), it ends
    /// `windowLookahead` past `time` instead, so such a track is read ahead in steps. While a seek is under way there is
    /// none: its landing asks again.
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
            return lower < end ? lower...end : nil
        }
        return window
    }

    func noteSubtitleReadsStart(at seconds: Double) {
        liveSubtitleState.withLock { state in
            if let start = state.spanStart, seconds > start { state.spanStart = seconds }
        }
    }

    @discardableResult
    func mergeLiveSubtitles(
        _ packets: EmbeddedSubtitleReader.Packets, covering range: ClosedRange<Double>, selection: Int, span: Int
    ) -> Bool {
        liveSubtitleState.withLock { state in
            guard state.selection == selection, state.readSpan == span else { return false }
            for cue in packets.cues { Self.addLiveCue(cue, to: &state) }
            // The window ends where playback reads from, or reads on ahead of it: it joins the stretch being read.
            state.imageCues.merge(
                window: packets.bitmapOutputs, span: state.readSpan, replaying: state.bitmapTruncations)
            for event in packets.assEvents where state.assScript != nil {
                guard state.assPayloads.insert(event.payload).inserted else { continue }
                state.assScript?.events.append(event)
            }
            state.cover(range)
            state.version += 1
            return true
        }
    }

    func processPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>, in formatCtx: UnsafeMutablePointer<AVFormatContext>?
    ) {
        guard let formatCtx, selectedStreamIndex >= 0,
            selectedStreamIndex < Int(formatCtx.pointee.nb_streams),
            let stream = formatCtx.pointee.streams[selectedStreamIndex]
        else { return }

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
