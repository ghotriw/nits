import Foundation
internal import NitsStreaming
import os

/// A dynamic MPD as playlists that slide: the clock the live edge is read off, the manifest fetched again when it says it
/// changes, and the numbers the segments keep across reloads. See `.agents/dash-client/PLAN.md` ("Live").
///
/// **The clock.** What a segment's availability is measured against is the server's: its `UTCTiming` tells (`direct`,
/// `http-iso`, `http-xsdate`, `http-head`), once, at the opening, as an offset from the host's clock; with none the host's
/// is used. The `Date` of the manifest's own answer is not: a cache in front of the manifest serves it with the date it
/// was made (dash.js and shaka-player do not read it either).
///
/// **The window.** Each ask for a playlist lists the segments that have come whole by the clock now (the manifest's
/// timeline up to its end, or a template counted by its `@duration`), the last `timeShiftBufferDepth` of them, at most
/// `DASHPresentation.maxHistory`. The manifest is fetched again, by the caller that finds it due, once its
/// `minimumUpdatePeriod` has passed since the last fetch; asked sooner, the manifest held is read at the clock now.
extension DASHPlaylists {
    /// A manifest as fetched, and when (the host's clock).
    package struct Fetched: Sendable {
        var data: Data
        var servedFrom: URL
        var at: Date
        /// Which fetch it is: the opening's is 0.
        var generation: Int
    }

    /// The lowest `minimumUpdatePeriod` that fetches the manifest again at every ask: `0` says "every segment", which the
    /// opening's side-by-side asks and two lanes would each take for a fetch of their own.
    static let refetchFloor = 0.25
    /// A presentation read at the clock now is used again for asks within this many seconds.
    static let snapshotReuse = 0.5
    /// A segment's start matches another's of the same place within this many seconds (the starts are ticks of a
    /// timescale: equal ones differ by rounding only).
    static let sameStart = 0.001

    /// What the live part of a source keeps: the manifest as last fetched, the server's clock, a presentation read at the
    /// clock now, and the numbers each timeline's segments were given.
    package final class LiveState: @unchecked Sendable {
        /// What a timeline's segments were numbered, to continue the numbers when its window slides (ExoPlayer's
        /// `copyWithNewRepresentation` matches the end of the old index to the start of the new one).
        package struct Memory: Sendable {
            var first: (start: Double, number: Int)
            var last: (start: Double, number: Int, duration: Double)
        }

        package struct State: Sendable {
            var fetch = Store<Fetched>()
            /// The manifest last fetched whole: what a fetch that fails leaves the stream reading.
            var held: Fetched?
            var generation = 0
            /// Seconds the server's clock is ahead of the host's.
            var offset = 0.0
            var updatePeriod: Double?
            var location: URL?
            var snapshot: (generation: Int, at: Date, presentation: DASHPresentation)?
            /// The start of the period played (`Live.periodStart`), once one was read: a later manifest that lists more
            /// periods is read as that one, up to the next one's start.
            var periodStart: Double?
            var memories: [Int: Memory] = [:]
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        /// The opening's fetch, which the first asks are answered from.
        func begin(_ fetched: Fetched, offset: Double, updatePeriod: Double?, location: URL?, periodStart: Double) {
            state.withLock { state in
                state.periodStart = periodStart
                state.fetch = Store(value: fetched)
                state.held = fetched
                state.generation = fetched.generation
                state.offset = offset
                state.updatePeriod = updatePeriod
                state.location = location
            }
        }

        /// The numbers of a timeline's `segments`, continuing those it was given before: found by where its newest (else its
        /// oldest) segment was, by time. A window that slid past all of them continues from the gap; one that shares none and
        /// lies before them (a clock that went back) starts over with the manifest's own. Segments not told by a timeline
        /// keep their own numbers (`$Number$` counted by the clock does not move).
        func assign(_ index: Int, _ segments: [DASHPresentation.Segment], byTime: Bool) -> [Int] {
            guard byTime, let first = segments.first, let last = segments.last else { return segments.map(\.number) }
            return state.withLock { state in
                var base = first.number
                if let memory = state.memories[index] {
                    if let at = segments.lastIndex(where: {
                        abs($0.start - memory.last.start) <= DASHPlaylists.sameStart
                    }) {
                        base = memory.last.number - at
                    } else if let at = segments.firstIndex(where: {
                        abs($0.start - memory.first.start) <= DASHPlaylists.sameStart
                    }) {
                        base = memory.first.number - at
                    } else if first.start > memory.last.start {
                        let gap = first.start - (memory.last.start + memory.last.duration)
                        base = memory.last.number + 1 + DASHPlaylists.segments(in: gap, of: first.duration)
                    }
                }
                state.memories[index] = Memory(
                    first: (first.start, base), last: (last.start, base + segments.count - 1, last.duration))
                return Array(base..<(base + segments.count))
            }
        }
    }

    // MARK: - Clock

    /// Seconds the server's clock is ahead of the host's, as the manifest's `UTCTiming` tells; 0 when none answers. A
    /// descriptor that fails or is not understood is passed over for the next; an abort is the caller's.
    func clockOffset(
        of timings: [DASHPresentation.Live.Timing], loader: SegmentLoader
    ) throws(HLSPlaylistSourceError) -> Double {
        for timing in timings {
            let scheme = timing.scheme.replacingOccurrences(of: "urn:mpeg:dash:utc:", with: "")
                .replacingOccurrences(of: ":2014", with: "").replacingOccurrences(of: ":2012", with: "")
            var server: Date?
            switch scheme {
            case "direct":
                server = DASHElements.dateTime(of: timing.value)
            case "http-iso", "http-xsdate", "http-head":
                for text in timing.value.split(separator: " ") {
                    guard let url = URL(string: String(text), relativeTo: address)?.absoluteURL else { continue }
                    do {
                        if scheme == "http-head" {
                            server = try loader.serverDate(of: url).map { $0.addingTimeInterval(0.5) }
                        } else {
                            let body = try loader.playlist(url).data
                            server = String(data: body.prefix(64), encoding: .utf8).flatMap(DASHElements.dateTime(of:))
                        }
                    } catch {
                        if error == .interrupted { throw .load(error) }
                        StreamingLog.warning("DASH: the clock at \(url.host ?? "?") did not answer (\(error))")
                    }
                    if server != nil { break }
                }
            default:
                StreamingLog.warning("DASH: a clock of \(timing.scheme) is not read")
            }
            if let server { return server.timeIntervalSince(clock()) }
        }
        return 0
    }

    // MARK: - Reading

    /// The presentation `data` tells at the clock `now`; of a live manifest of several periods, the one that starts at
    /// `periodStart` (the one played).
    func presentation(
        _ data: Data, servedFrom: URL, now: Date, periodStart: Double? = nil
    ) throws(HLSPlaylistSourceError) -> DASHPresentation {
        do throws(DASHPresentationError) {
            return try DASHPresentation.parse(data, url: servedFrom, now: now, livePeriodStart: periodStart)
        } catch {
            switch error {
            case .unreadable: throw .unreadable(.notAPlaylist)
            case .unsupported(let reason): throw .unsupported(reason)
            }
        }
    }

    /// The manifest as of now: the one held, or a fetch of it if its `minimumUpdatePeriod` has passed. Made by the first
    /// caller that finds it due, through its own loader; the others wait for it (`Store`).
    private func fetched(loader: SegmentLoader) throws(HLSPlaylistSourceError) -> Fetched {
        let host = clock()
        let (store, generation) = live.state.withLock { state -> (Store<Fetched>, Int) in
            if inline == nil, let current = state.fetch.current, let period = state.updatePeriod,
                host.timeIntervalSince(current.at) >= max(period, Self.refetchFloor)
            {
                state.generation += 1
                state.fetch = Store()
            }
            return (state.fetch, state.generation)
        }
        let result: Fetched
        do throws(HLSPlaylistSourceError) {
            result = try store.value(loader: loader) { loader throws(HLSPlaylistSourceError) in
                let location = live.state.withLock { $0.location } ?? address
                do throws(SegmentLoadError) {
                    let (data, servedFrom) = try loader.playlist(location)
                    return Fetched(data: data, servedFrom: servedFrom, at: clock(), generation: generation)
                } catch {
                    throw .load(error)
                }
            }
        } catch {
            // A fetch that fails is no end of the stream: the manifest held, read at the clock now, still lists what has
            // come (shaka-player and dash.js keep it too); the next ask tries again. An abort is the caller's.
            if case .load(.interrupted) = error { throw error }
            guard let held = live.state.withLock({ $0.held }) else { throw error }
            StreamingLog.warning("DASH: the manifest did not load (\(error)); the one held is read again")
            return held
        }
        return result
    }

    /// The presentation at the clock now, from the manifest as last fetched: shared by the asks that come together (the
    /// opening's, two lanes').
    func snapshot(loader: SegmentLoader) throws(HLSPlaylistSourceError) -> DASHPresentation {
        let fetched = try fetched(loader: loader)
        let host = clock()
        let reused = live.state.withLock { state -> DASHPresentation? in
            guard let held = state.snapshot, held.generation == fetched.generation,
                abs(host.timeIntervalSince(held.at)) < Self.snapshotReuse
            else { return nil }
            return held.presentation
        }
        if let reused { return reused }
        let (offset, periodStart) = live.state.withLock { ($0.offset, $0.periodStart) }
        var used = fetched
        let presentation: DASHPresentation
        do throws(HLSPlaylistSourceError) {
            // A manifest that comes to list a period after the one played (server-side ad insertion's break, told
            // before it comes or after) is read as the one played up to the next one's start: its segments end there, and
            // the playlist with them (`livePlaylist`'s `hasEnded`).
            presentation = try self.presentation(
                fetched.data, servedFrom: fetched.servedFrom, now: host.addingTimeInterval(offset),
                periodStart: periodStart)
        } catch {
            // A fetch that answered with what does not read (cut short, an error page) is no end of the stream either: the
            // last manifest that read is used, as for a fetch that failed. A manifest that reads as one not played is a refusal.
            guard case .unreadable = error, let held = live.state.withLock({ $0.held }),
                held.generation != fetched.generation
            else { throw error }
            StreamingLog.warning("DASH: the manifest fetched does not read; the one held is read again")
            used = held
            presentation = try self.presentation(
                held.data, servedFrom: held.servedFrom, now: host.addingTimeInterval(offset), periodStart: periodStart)
        }
        let finalFetched = used
        live.state.withLock { state in
            state.snapshot = (fetched.generation, host, presentation)
            // Held once it reads: a manifest cut short or unreadable is not one to fall back on.
            state.held = finalFetched
            if inline == nil { state.updatePeriod = presentation.live?.minimumUpdatePeriod }
            state.location = presentation.live?.location
        }
        return presentation
    }

    // MARK: - Playlists

    /// The playlist of the entry at `index` as the clock now has it.
    func livePlaylist(
        _ index: Int, of built: Built, loader: SegmentLoader
    ) throws(HLSPlaylistSourceError) -> HLSMediaPlaylist {
        let presentation = try snapshot(loader: loader)
        let entry = built.entries[index]
        guard let representation = Self.representation(of: entry, in: presentation) else {
            throw .unsupported("\(entry.representation.id) is no longer in the manifest")
        }
        let numbers = try sequences(of: index, in: built, presentation: presentation)
        // The ladder's best picture lists nothing to number by (its first segment has not come): no number, no playlist.
        guard numbers.count == representation.segments.count else {
            throw .unsupported("\(entry.representation.id) has no numbers yet: the ladder's best lists no segments")
        }
        var playlist = HLSMediaPlaylist(
            targetDuration: (representation.segments.map(\.duration).max() ?? 0).rounded(.up))
        playlist.hasIndependentSegments = true
        let live = presentation.live
        // A manifest that turned static, or whose period has ended (another follows it: an ad break), is a recording now:
        // no segment will come.
        let hasEnded = live == nil || presentation.periodDuration.map { (live?.edge ?? 0) >= $0 } == true
        if hasEnded {
            playlist.type = .vod
            playlist.hasEnded = true
        }
        // Not nearer the edge than a segment: a delay of 0 would start where nothing is loaded yet.
        playlist.holdBack = live?.suggestedPresentationDelay.map { max($0, playlist.targetDuration) }
        playlist.updatePeriod = live?.minimumUpdatePeriod
        playlist.segments = representation.segments.enumerated().map { position, segment in
            var listed = HLSSegment(
                url: segment.url, duration: segment.duration, sequence: numbers[position], discontinuitySequence: 0,
                byteRange: segment.byteRange, initSection: representation.initSection)
            listed.programDateTime = live?.date(at: segment.start)
            return listed
        }
        playlist.mediaSequence = playlist.segments.first?.sequence ?? 0
        return playlist
    }

    private static func representation(
        of entry: Entry, in presentation: DASHPresentation
    ) -> DASHPresentation.Representation? {
        presentation.representations.first { isSame($0, entry.representation) }
    }

    /// The numbers the segments of the entry at `index` take now: a timeline's continue those it had; a picture of a
    /// ladder takes the numbers of the ladder's best picture's segment that starts where its own does (and counts on from
    /// the nearest one where the best picture lists none: the edges of two windows are not the same moment).
    private func sequences(
        of index: Int, in built: Built, presentation: DASHPresentation
    ) throws(HLSPlaylistSourceError) -> [Int] {
        let entry = built.entries[index]
        guard let representation = Self.representation(of: entry, in: presentation) else {
            throw .unsupported("\(entry.representation.id) is no longer in the manifest")
        }
        guard case .on(let referenceIndex, let tolerance) = entry.numbering else {
            return live.assign(index, representation.segments, byTime: entry.representation.numbersByTime)
        }
        let reference = built.entries[referenceIndex]
        guard let best = Self.representation(of: reference, in: presentation) else {
            throw .unsupported("\(reference.representation.id) is no longer in the manifest")
        }
        let bestNumbers = live.assign(referenceIndex, best.segments, byTime: reference.representation.numbersByTime)
        return Self.numbers(
            of: representation.segments, byTimeOn: best.segments, numbers: bestNumbers, tolerance: tolerance,
            isStrict: false) ?? []
    }

    /// The numbers `segments` take from `reference`'s (`numbers` of them) by time: each takes the number of the one that
    /// starts where it does (within `tolerance` seconds). One that starts outside the reference's window counts on from the
    /// nearest. Strictly, a segment that starts inside the window where none does has no number, and nil is the answer:
    /// the opening leaves such a picture out of the ladder.
    static func numbers(
        of segments: [DASHPresentation.Segment], byTimeOn reference: [DASHPresentation.Segment], numbers: [Int],
        tolerance: Double, isStrict: Bool
    ) -> [Int]? {
        guard let first = reference.first, let last = reference.last, reference.count == numbers.count else {
            return isStrict ? nil : []
        }
        var result: [Int] = []
        result.reserveCapacity(segments.count)
        var cursor = 0
        for segment in segments {
            while cursor + 1 < reference.count, reference[cursor + 1].start <= segment.start + tolerance { cursor += 1 }
            let near = reference[cursor]
            let delta = segment.start - near.start
            if abs(delta) <= tolerance {
                result.append(numbers[cursor])
                continue
            }
            if isStrict, segment.start >= first.start - tolerance,
                segment.start < last.start + last.duration - tolerance
            {
                return nil
            }
            result.append(numbers[cursor] + Self.segments(in: delta, of: near.duration))
        }
        return result
    }

    /// How many segments of `duration` fit in `span` seconds, rounded. The times are the manifest's: a count past any
    /// window is bounded, never a trap.
    static func segments(in span: Double, of duration: Double) -> Int {
        let count = (span / max(duration, 0.001)).rounded()
        return count.isFinite ? Int(min(max(count, -1.0e12), 1.0e12)) : 0
    }
}
