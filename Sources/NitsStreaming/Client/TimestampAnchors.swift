import Foundation
import os

/// The seconds that put an HLS stream's media timestamps on the playlist's timeline, one for each discontinuity
/// sequence, shared by all its lanes and runs (hls.js's `initPTS[cc]`, ExoPlayer's `TimestampAdjusterProvider`).
///
/// The first run read in a sequence (a variant's or a rendition's) anchors it: its first timestamp is where the
/// playlist puts its first segment. Every later run of that sequence, of any lane and from any segment (a seek, a
/// variant switched to, an audio rendition), takes the same offset: the media's own timestamps place it, so the sound of
/// a rendition keeps its place against the picture, and a variant joins the old one where their timestamps meet,
/// whatever the `EXTINF`s summed to on the way (an integer `EXTINF` of a 10.01 s segment is 0.3 s off after five minutes).
/// The playlist only says which segment to load. A run whose first packet the offset puts further than `tolerance` (the
/// target duration) from where the playlist says (variants of other timestamp bases, numbers of a discontinuity that
/// don't match across playlists) is anchored anew, and anchors the sequence for the runs after it.
///
/// Who anchors (`Role`): the picture's runs, and an audio rendition's (which waits for the picture at a break first,
/// `StreamingLane.waitsForAnchor`, so that the picture anchors whenever it gets there). Cues never do: they are sparse, the
/// first may be far into its segment. A WebVTT rendition has no timestamps of its own, and its cues take the offset of
/// the sequence they are in (`cueOffset`); cues of a sequence nobody anchored (a subtitle playlist without the breaks
/// the picture's has) take the offset the picture is read with.
package final class TimestampAnchors: Sendable {
    package enum Role: Sendable {
        /// A variant's run: anchors, and is the offset cues fall back on.
        case picture
        /// An audio rendition's run: anchors.
        case sound
        /// Cues in a container (IMSC in fMP4, MPEG-TS): take the offset, never anchor.
        case cues
    }

    private struct State {
        var offsets: [Int: Double] = [:]
        /// The offset of the picture's last run.
        var picture: Double?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The offset of a run of `sequence` that starts at `start` on the timeline, the first timestamp it read being
    /// `first` (seconds of the media's clock, as read: unwrapped by `nearest`, which moves it by whole wraps nearest a
    /// time of the media's clock). Anchors the sequence when it has no offset yet, or one that doesn't fit. Cues take the
    /// sequence's offset as it is (`cueOffset`), else their own, and tell nothing.
    package func offset(
        of sequence: Int, start: Double, first: Double, tolerance: Double, role: Role,
        nearest: @Sendable (Double) -> Double
    ) -> Double {
        state.withLock { state in
            let own = start - first
            if role == .cues { return Self.cueOffset(of: sequence, in: state) ?? own }
            var offset = own
            if let shared = state.offsets[sequence], abs(nearest(start - shared) + shared - start) <= tolerance {
                offset = shared
            } else {
                if let shared = state.offsets[sequence] {
                    StreamingLog.info(
                        "HLS: a run of discontinuity \(sequence) is \(String(format: "%.3f", shared - own)) s off the anchor, anchored anew"
                    )
                }
                state.offsets[sequence] = own
            }
            if role == .picture { state.picture = offset }
            return offset
        }
    }

    /// The offset a WebVTT segment's cues of `sequence` are placed with (`cueOffset`); nil before any run anchored.
    func subtitleShift(for sequence: Int) -> Double? {
        state.withLock { Self.cueOffset(of: sequence, in: $0) }
    }

    /// Whether any run has anchored a sequence: before, cues are placed with no offset at all.
    var hasAnchors: Bool {
        state.withLock { !$0.offsets.isEmpty }
    }

    /// Whether a run of `sequence` has anchored it.
    func isAnchored(_ sequence: Int) -> Bool {
        state.withLock { $0.offsets[sequence] != nil }
    }

    /// What cues of `sequence` are placed with: its offset, else the picture's (a subtitle playlist whose numbers don't
    /// follow the picture's breaks, or a break the picture has not anchored within the wait).
    private static func cueOffset(of sequence: Int, in state: State) -> Double? {
        state.offsets[sequence] ?? state.picture
    }
}

/// Timestamps of a stream that wraps (MPEG-TS's 33 bits at 90 kHz, every 26.5 hours) made one growing line: each value
/// is read as the one nearest the last decode time, `wrap` ticks apart. A segment read after the wrap, or a picture's
/// presentation time just past it while its decode time is before, both come out right.
package struct TimestampUnwrapper: Sendable {
    let wrap: Int64
    private var offset: Int64 = 0
    private var reference: Int64?

    /// A stream that wraps at `bits`; nil for a stream that doesn't (FFmpeg's `pts_wrap_bits` of 63 or more).
    init?(bits: Int32) {
        guard bits > 1, bits < 63 else { return nil }
        wrap = Int64(1) << Int64(bits)
    }

    /// Starts the line near `ticks`: the first value is read as the one nearest it, whole wraps apart (a run of a
    /// sequence anchored before the media's clock wrapped, or after).
    mutating func expect(near ticks: Int64) {
        reference = ticks
        offset = 0
    }

    /// `value` on the unwrapped line, nearest the reference.
    func unwrapped(_ value: Int64) -> Int64 {
        let result = value &+ offset
        guard let reference else { return result }
        return result &+ wrap &* Self.wraps(from: result, to: reference, wrap: wrap)
    }

    /// Whole wraps that bring `value` nearest `reference`.
    static func wraps(from value: Int64, to reference: Int64, wrap: Int64) -> Int64 {
        Int64((Double(reference &- value) / Double(wrap)).rounded())
    }

    /// `value` moved by the whole wraps that bring it nearest `reference` (seconds, or any unit the three share).
    static func nearest(_ value: Double, to reference: Double, wrap: Double) -> Double {
        value + wrap * ((reference - value) / wrap).rounded()
    }

    /// A packet's timestamps: the decode time moves the reference, the presentation time is placed by it. Without a
    /// decode time the presentation time stands for it.
    mutating func unwrap(pts: Int64?, dts: Int64?) -> (pts: Int64?, dts: Int64?) {
        let decode = (dts ?? pts).map(unwrapped)
        let presentation = pts.map(unwrapped)
        if let decode, let source = dts ?? pts {
            offset = decode - source
            reference = decode
        }
        return (presentation, dts == nil ? nil : decode)
    }
}
