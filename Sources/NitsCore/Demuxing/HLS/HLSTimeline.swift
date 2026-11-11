import Foundation

/// A rendition's segments placed on the playlist's timeline: each starts where the one before ends (the sum of the
/// `EXTINF` durations), from zero at the first segment of the playlist as first loaded. That is the timeline packets
/// are moved onto, whatever their own timestamps do at a discontinuity.
///
/// A live playlist is reloaded into it (`reload`): segments are matched by their media sequence number, so that one
/// listed again keeps its place, those added follow and those the server dropped leave the window (they expire). The
/// timeline keeps only the window the playlist lists.
///
/// Another rendition of the same stream (a variant switched to, an audio rendition) is placed on the same timeline
/// (`init(_:alignedTo:sharesSequenceNumbers:)`).
struct HLSTimeline: Sendable, Equatable {
    /// A segment and where it starts on the timeline, in seconds.
    struct Entry: Sendable, Equatable {
        var segment: HLSSegment
        var start: Double
        /// `start` was read off the media (`measure`), not only summed from durations.
        var isMeasured = false
        /// The run of the timeline the entry was placed in (`epoch`): a restart numbers its segments again, and an entry of
        /// an earlier one that has the same number is not the one listed now.
        var epoch = 0

        var end: Double { start + segment.duration }
        var sequence: Int { segment.sequence }
    }

    /// What a reload did.
    enum ReloadChange: Sendable, Equatable {
        /// The same segments, and no end.
        case unchanged
        /// Segments were added or dropped, or the playlist ended.
        case updated(added: Int, expired: Int)
        /// The numbers jumped past the window (the reload came late, or the server renumbered), or the caller took the
        /// playlist as a restart (`restart`). The new segments start a run of their own (a discontinuity) after the old
        /// end, `gap` seconds after it: the segments missed, by date or by count (none past `longestMissedSpan`).
        case restarted(gap: Double)
        /// Not newer than the window (a CDN edge that lags, or a restart within it): ignored, the window stays.
        case stale
        /// Wholly behind the window (the server restarted, or an edge lags by more than a window): ignored, the window
        /// stays. The caller may reload again, or take it as a restart (`restart`).
        case reset
    }

    /// What follows a segment, for a reader that read it.
    enum Next: Sendable, Equatable {
        case entry(Entry)
        /// The segments that followed left the window before they were read (or a late reload never saw them):
        /// reading goes on from this one, the first listed after.
        case expired(resumingAt: Entry)
        /// Past the live edge: a reload may bring it.
        case pending
        /// The playlist ended there.
        case ended
    }

    /// The segments the playlist lists, in order.
    private(set) var entries: [Entry]
    private(set) var targetDuration: Double
    private(set) var hasEnded: Bool
    /// The playlist could change when first loaded: it has a live window (`liveWindow`).
    let isLive: Bool
    /// The first load that listed segments listed the stream from its start (`listsFromStreamStart`): renditions
    /// loaded so are aligned at `streamStart`.
    private(set) var beganAtStreamStart: Bool
    /// The playlist dropped segments from its start since it was first loaded, or had before (one not from the stream's
    /// start, `listsFromStreamStart`).
    private(set) var hasSlid: Bool
    /// Where the timeline starts while nothing is listed.
    private var emptyStart: Double
    /// Where the stream's start is on the timeline, when the playlist listed it (`beganAtStreamStart`): it stays there
    /// once the window slides on.
    private(set) var streamStart: Double?
    /// What the server's discontinuity sequence numbers are short of those matched by media sequence (a server that
    /// doesn't keep `EXT-X-DISCONTINUITY-SEQUENCE`, a restart): added to the numbers of segments loaded since.
    private var discontinuityCorrection = 0
    /// Counts the restarts (`startRun`): entries placed after one belong to a run of the timeline of their own.
    private var epoch = 0

    /// Places `playlist`'s segments from `start`.
    init(_ playlist: HLSMediaPlaylist, start: Double = 0) {
        targetDuration = playlist.targetDuration
        hasEnded = !playlist.isLive
        isLive = playlist.isLive
        beganAtStreamStart = Self.listsFromStreamStart(playlist)
        hasSlid = !beganAtStreamStart
        emptyStart = start
        streamStart = beganAtStreamStart ? start : nil
        entries = Self.place(playlist.segments, from: start, epoch: 0)
    }

    /// Places `playlist`, another rendition of the stream, on `reference`'s timeline (`alignedStart`).
    /// `sharesSequenceNumbers`: it is a variant of the reference's ladder, whose segments are the same spans of time
    /// under the same numbers; an audio or subtitle rendition's need not be.
    ///
    /// Nil for an empty playlist or reference: there is nothing to align, and the segments a reload brings would be
    /// placed from the reference's start, not where they belong. Made from the first load that lists segments.
    init?(_ playlist: HLSMediaPlaylist, alignedTo reference: HLSTimeline, sharesSequenceNumbers: Bool) {
        guard !playlist.segments.isEmpty, !reference.isEmpty else { return nil }
        self.init(
            playlist,
            start: Self.alignedStart(of: playlist, to: reference, sharesSequenceNumbers: sharesSequenceNumbers))
    }

    // MARK: Reading

    var isEmpty: Bool { entries.isEmpty }
    /// Start of the first segment listed.
    var start: Double { entries.first?.start ?? emptyStart }
    /// End of the last segment listed: the live edge of a live playlist, the duration of a finished one.
    var end: Double { entries.last?.end ?? emptyStart }
    var firstSequence: Int? { entries.first?.sequence }
    var lastSequence: Int? { entries.last?.sequence }

    /// The window of a playlist that was live when first loaded; nil for one finished then.
    var liveWindow: LiveWindow? {
        isLive ? LiveWindow(start: start, end: end, hasSlid: hasSlid, hasEnded: hasEnded) : nil
    }

    /// The segment listed with media sequence number `sequence`.
    func entry(sequence: Int) -> Entry? {
        guard let first = firstSequence, sequence >= first, sequence - first < entries.count else { return nil }
        return entries[sequence - first]
    }

    /// The index of the segment that holds `time`: the first for a time before the window, the last for its very end;
    /// nil past the end, or for an empty playlist. A segment of no duration holds no time.
    func index(at time: Double) -> Int? {
        guard let first = entries.first, time <= end else { return nil }
        var low = 0
        if time > first.start {
            // The last segment that starts at or before `time`…
            var high = entries.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if entries[middle].start <= time { low = middle } else { high = middle - 1 }
            }
            // …that has a duration: segments of none at the boundary give way to the one that ends there.
            while low > 0, entries[low].segment.duration == 0 { low -= 1 }
        }
        // Before the first that has one: that one.
        if entries[low].segment.duration == 0 {
            low = entries[low...].firstIndex { $0.segment.duration > 0 } ?? low
        }
        return low
    }

    func entry(at time: Double) -> Entry? { index(at: time).map { entries[$0] } }

    /// What comes after `read`, an entry of this timeline read before (not another rendition's: its segments need not
    /// meet this one's ends, and an overlap would read as a gap): by media sequence while the window still lists it
    /// where it was (the same run of the timeline: a place moved by `measure` is still its place), else by
    /// time (a restart numbers from zero again, a late reload skips numbers).
    func next(after read: Entry) -> Next {
        guard let first = entries.first, let last = entries.last else { return hasEnded ? .ended : .pending }
        if entry(sequence: read.sequence)?.epoch == read.epoch {
            return read.sequence == last.sequence
                ? (hasEnded ? .ended : .pending) : .entry(entries[read.sequence + 1 - first.sequence])
        }
        // The first that ends after it: the one that follows it, or what comes after a gap.
        let tolerance = 0.001
        guard let next = entries.first(where: { $0.end > read.end + tolerance }) else {
            return hasEnded ? .ended : .pending
        }
        return abs(next.start - read.end) <= tolerance ? .entry(next) : .expired(resumingAt: next)
    }

    // MARK: Measuring

    /// Takes where the media says the segment with media sequence `sequence` starts (the first presentation time of its
    /// first picture, on this timeline), as hls.js corrects a fragment's start from its PTS (`updateFragPTSDTS`). The
    /// durations the playlist lists are rounded (an integer `EXTINF` for 6.006 s) and add up to a drift; the media's own
    /// times don't. The entries around it follow:
    /// - between two measured entries the durations are scaled to fit the span (the error spreads evenly);
    /// - before the first measured entry and after the last, they are placed from it as listed.
    ///
    /// Nothing changes (false) for a segment the window doesn't list, or listed under another address (`url`: a reload
    /// that renumbered), for a start further than a target duration from where the timeline puts it (the media's clock
    /// jumped: its offset is `HLSTimestampAnchors`' to decide, not a correction of the span) and for one that would
    /// scale a span by more than half or double.
    @discardableResult
    mutating func measure(sequence: Int, url: URL, byteRange: HLSByteRange?, start observed: Double) -> Bool {
        guard let first = firstSequence, sequence >= first, sequence - first < entries.count else { return false }
        let index = sequence - first
        // By path and byte range: a CDN that signs addresses anew at each reload changes the query only, while a renumbering
        // moves the range of a segment in a file of them all.
        guard entries[index].segment.url.path == url.path, entries[index].segment.byteRange == byteRange,
            observed.isFinite
        else { return false }
        let delta = observed - entries[index].start
        guard abs(delta) <= max(targetDuration, 1) else { return false }
        if abs(delta) < Self.measureResolution {
            entries[index].isMeasured = true
            return false
        }
        var placed = entries
        placed[index].start = observed
        placed[index].isMeasured = true
        let before = placed[..<index].lastIndex(where: \.isMeasured)
        let after = placed[(index + 1)...].firstIndex(where: \.isMeasured)
        guard Self.fit(&placed, from: before, to: index), Self.fit(&placed, from: index, to: after) else {
            return false
        }
        entries = placed
        return true
    }

    /// Differences smaller than this are rounding of the playlist's durations (milliseconds), not drift.
    static let measureResolution = 0.001

    /// Places the entries between `lower` and `upper` (either may be nil: an end of the window) from the measured one
    /// at the other side. Both measured: the durations from `lower` up to `upper` are scaled so that `lower` ends where
    /// `upper` starts. False when the span can't take it (it would shrink or stretch by more than half / double).
    private static func fit(_ entries: inout [Entry], from lower: Int?, to upper: Int?) -> Bool {
        switch (lower, upper) {
        case (let lower?, let upper?):
            guard upper > lower else { return true }
            let listed = entries[lower..<upper].reduce(0) { $0 + $1.segment.duration }
            let span = entries[upper].start - entries[lower].start
            guard listed > 0, span > 0, span / listed >= 0.5, span / listed <= 2 else { return false }
            let ratio = span / listed
            var cursor = entries[lower].start
            for position in lower..<upper {
                entries[position].start = cursor
                entries[position].segment.duration *= ratio
                cursor += entries[position].segment.duration
            }
        case (let lower?, nil):
            var cursor = entries[lower].end
            for position in (lower + 1)..<max(entries.count, lower + 1) {
                entries[position].start = cursor
                cursor = entries[position].end
            }
        case (nil, let upper?):
            var cursor = entries[upper].start
            for position in (0..<upper).reversed() {
                cursor -= entries[position].segment.duration
                entries[position].start = cursor
            }
        case (nil, nil):
            break
        }
        return true
    }

    // MARK: Reloading

    /// Merges a reload of the same playlist.
    ///
    /// A reload is taken when it is newer than the window, as ExoPlayer decides: one whose first segment is
    /// later, or the same with as many segments or more. One that isn't is `.stale` (a CDN edge that lags) and changes
    /// nothing, or `.reset` when its numbers are wholly behind the window (the server restarted, or lags by more than a
    /// window). Neither is merged: a restart can't be told from a lagging edge by the playlist alone, so the caller
    /// decides (`restart`), as ExoPlayer reports a reset or a stuck playlist and lets the player act.
    @discardableResult
    mutating func reload(_ playlist: HLSMediaPlaylist) -> ReloadChange {
        let wasEnded = hasEnded
        let change = merge(playlist)
        return change == .unchanged && wasEnded != hasEnded ? .updated(added: 0, expired: 0) : change
    }

    /// Places `playlist`'s segments after the window as a run of their own, whatever their numbers: the caller took a
    /// `.stale` or `.reset` playlist as a restart of the stream.
    @discardableResult
    mutating func restart(_ playlist: HLSMediaPlaylist) -> ReloadChange {
        guard let last = entries.last else { return reload(playlist) }
        // A server that restarted numbers from the start again: its numbers no longer say where the stream is.
        return startRun(of: playlist, after: last, gap: 0, keepsNumbers: false)
    }

    /// The most a late reload is taken to have missed, by count or by date: a longer span is a server that renumbered
    /// or whose clock jumped.
    static let longestMissedSpan = 3600.0
    /// How far a rendition's date may be from the reference's it is aligned by, at least: past that and its own
    /// duration, the two don't overlap and dates don't align them (hls.js's bound).
    static let longestDateOffset = 60.0

    private mutating func merge(_ playlist: HLSMediaPlaylist) -> ReloadChange {
        let segments = playlist.segments
        guard let oldFirst = entries.first, let oldLast = entries.last else {
            // Nothing was listed: the new segments start where the timeline does, and the first that are listed tell
            // how the playlist began.
            accept(playlist)
            entries = Self.place(segments, from: emptyStart, epoch: epoch)
            if isLive, !segments.isEmpty {
                beganAtStreamStart = Self.listsFromStreamStart(playlist)
                hasSlid = !beganAtStreamStart
                streamStart = beganAtStreamStart ? emptyStart : nil
            }
            return entries.isEmpty ? .unchanged : .updated(added: entries.count, expired: 0)
        }
        guard let newFirst = segments.first else {
            // Emptied: nothing to match, the window stays.
            accept(playlist)
            return .unchanged
        }
        let newLast = newFirst.sequence + segments.count - 1
        guard newLast >= oldFirst.sequence else { return .reset }
        // As ExoPlayer's `isNewerThan`: a later first segment, or the same with as many segments or more (the same
        // count is merged too: addresses may have been signed anew).
        let isNewer =
            newFirst.sequence > oldFirst.sequence
            || (newFirst.sequence == oldFirst.sequence
                && segments.count >= entries.count)
        guard isNewer else { return .stale }

        if newFirst.sequence <= oldLast.sequence {
            // A segment both list: its place holds, the others are placed from it.
            accept(playlist)
            let anchor = entries[newFirst.sequence - oldFirst.sequence]
            discontinuityCorrection = anchor.segment.discontinuitySequence - newFirst.discontinuitySequence
            var cursor = anchor.start
            entries = corrected(segments).map { segment in
                var entry = Entry(segment: segment, start: cursor, epoch: epoch)
                // One listed before keeps its place, duration and run; what to load (its address, signed anew by
                // some CDNs at every reload, its key, a gap) is the new playlist's.
                if let known = self.entry(sequence: segment.sequence) {
                    entry.start = known.start
                    entry.isMeasured = known.isMeasured
                    entry.epoch = known.epoch
                    entry.segment.duration = known.segment.duration
                    entry.segment.discontinuitySequence = known.segment.discontinuitySequence
                    entry.segment.isDiscontinuity = known.segment.isDiscontinuity
                }
                cursor = entry.end
                return entry
            }
            let expired = newFirst.sequence - oldFirst.sequence
            let added = max(0, newLast - oldLast.sequence)
            if expired > 0 { hasSlid = true }
            return added == 0 && expired == 0 ? .unchanged : .updated(added: added, expired: expired)
        }

        if newFirst.sequence == oldLast.sequence + 1 {
            // Right after the window, nothing missed: the stream goes on (ExoPlayer places it at the old end too).
            let expired = entries.count
            accept(playlist)
            discontinuityCorrection =
                oldLast.segment.discontinuitySequence - newFirst.discontinuitySequence
                + (newFirst.isDiscontinuity ? 1 : 0)
            entries = Self.place(corrected(segments), from: oldLast.end, epoch: epoch)
            hasSlid = true
            return .updated(added: segments.count, expired: expired)
        }

        // Past the window: segments were missed, by date when both tell one (and it doesn't go back), else counted at
        // the target they were served under.
        let missed: Double
        if let date = newFirst.programDateTime, let oldDate = oldLast.segment.programDateTime,
            case let byDate = date.timeIntervalSince(oldDate) - oldLast.segment.duration, byDate >= 0
        {
            missed = byDate
        } else {
            missed = Double(newFirst.sequence - oldLast.sequence - 1) * targetDuration
        }
        return startRun(of: playlist, after: oldLast, gap: missed > Self.longestMissedSpan ? 0 : missed)
    }

    /// Places `playlist`'s segments as a run of their own, `gap` after `last`.
    ///
    /// A new run (a reader reads it apart from what was before). Numbered as the server numbers it when it says its
    /// discontinuity sequence (`declaresDiscontinuitySequence`, `keepsNumbers`), as the numbers are what the stream's
    /// playlists share, and the timestamps' offsets with them (`HLSTimestampAnchors`): a lane not read for a while that
    /// numbered on its own would take another lane's offset at the next real break. Else as a discontinuity after the old
    /// last: missed segments may have held one, which a server that doesn't keep the tag wouldn't tell (the numbers of
    /// such a server are the lane's own anyway).
    private mutating func startRun(
        of playlist: HLSMediaPlaylist, after last: Entry, gap: Double, keepsNumbers: Bool = true
    ) -> ReloadChange {
        accept(playlist)
        guard let first = playlist.segments.first else { return .unchanged }
        if !(keepsNumbers && playlist.declaresDiscontinuitySequence
            && first.discontinuitySequence + discontinuityCorrection >= last.segment.discontinuitySequence)
        {
            discontinuityCorrection = last.segment.discontinuitySequence + 1 - first.discontinuitySequence
        }
        epoch += 1
        entries = Self.place(corrected(playlist.segments), from: last.end + gap, epoch: epoch)
        entries[0].segment.isDiscontinuity = true
        hasSlid = true
        return .restarted(gap: gap)
    }

    /// Takes what a reload tells of the whole playlist.
    private mutating func accept(_ playlist: HLSMediaPlaylist) {
        targetDuration = playlist.targetDuration
        hasEnded = !playlist.isLive
    }

    /// A playlist that lists the stream from its start: finished (VOD) or an event, or one whose first segment is the
    /// stream's (media sequence 0, or 1, as some servers number from). A finished live window that had slid is not.
    static func listsFromStreamStart(_ playlist: HLSMediaPlaylist) -> Bool {
        playlist.type == .vod || playlist.type == .event || playlist.mediaSequence <= 1
    }

    // MARK: Placing

    private func corrected(_ segments: [HLSSegment]) -> [HLSSegment] {
        guard discontinuityCorrection != 0 else { return segments }
        return segments.map { segment in
            var segment = segment
            segment.discontinuitySequence += discontinuityCorrection
            return segment
        }
    }

    private static func place(_ segments: [HLSSegment], from start: Double, epoch: Int) -> [Entry] {
        var cursor = start
        return segments.map { segment in
            defer { cursor += segment.duration }
            return Entry(segment: segment, start: cursor, epoch: epoch)
        }
    }

    /// Where `playlist`'s first segment starts on `reference`'s timeline, for another rendition of the stream:
    /// - both from the stream's start (`listsFromStreamStart`): where the reference's stream started;
    /// - else by date (`EXT-X-PROGRAM-DATE-TIME`, within `longestDateOffset`), against the reference's latest segment dated at or before (its
    ///   first dated, for a rendition that starts before it);
    /// - else, for a variant of the reference's ladder (`sharesSequenceNumbers`), by media sequence number;
    /// - else, both live, at the same live edge; both finished, at the same end.
    static func alignedStart(
        of playlist: HLSMediaPlaylist, to reference: HLSTimeline, sharesSequenceNumbers: Bool
    ) -> Double {
        guard !playlist.segments.isEmpty, !reference.isEmpty else { return reference.start }
        if listsFromStreamStart(playlist), let origin = reference.streamStart { return origin }
        let durationBefore = { (index: Int) in playlist.segments[..<index].reduce(0) { $0 + $1.duration } }
        if let dated = playlist.segments.firstIndex(where: { $0.programDateTime != nil }),
            let date = playlist.segments[dated].programDateTime,
            let anchor = reference.entries.last(where: { $0.segment.programDateTime.map { $0 <= date } ?? false })
                ?? reference.entries.first(where: { $0.segment.programDateTime != nil }),
            let anchorDate = anchor.segment.programDateTime,
            // Dates that far apart don't overlap: not aligned by them (hls.js's bound).
            abs(date.timeIntervalSince(anchorDate)) <= max(Self.longestDateOffset, playlist.duration)
        {
            return anchor.start + date.timeIntervalSince(anchorDate) - durationBefore(dated)
        }
        if sharesSequenceNumbers,
            let (index, anchor) = playlist.segments.indices.lazy.compactMap({ index in
                reference.entry(sequence: playlist.segments[index].sequence).map { (index, $0) }
            }).first
        {
            return anchor.start - durationBefore(index)
        }
        if playlist.isLive, !reference.hasEnded { return reference.end - playlist.duration }
        // Both finished: they ended at the same point.
        if !playlist.isLive, reference.hasEnded { return reference.end - playlist.duration }
        return reference.start
    }
}
