import Foundation
import os

/// A bitmap subtitle (PGS, VobSub, DVB): one display set, drawn as pictures at fixed places on a canvas that is
/// stretched over the video.
public struct SubtitleImageCue: Sendable, Identifiable, Equatable {
    /// One picture of the set: palette indices rather than pixels, since a film holds thousands of them.
    public struct Region: Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        /// `width * height` palette indices, row by row without padding.
        let indices: Data
        /// Up to 256 straight-alpha colors as `0xAARRGGBB`; an index past the end is transparent.
        let palette: [UInt32]
        /// Finished premultiplied BGRA, for pictures a renderer composed (libass) instead of a palette bitmap.
        private let rendered: Data?

        public init(x: Int, y: Int, width: Int, height: Int, indices: Data, palette: [UInt32]) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.indices = indices
            self.palette = palette
            self.rendered = nil
        }

        public init(x: Int, y: Int, width: Int, height: Int, premultipliedBGRA: Data) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.indices = Data()
            self.palette = []
            self.rendered = premultipliedBGRA
        }

        /// Premultiplied BGRA, `width * 4` bytes per row: what `CGImage` takes as `premultipliedFirst` with
        /// `byteOrder32Little`.
        public func premultipliedBGRA() -> Data {
            if let rendered { return rendered }
            var lookup = [UInt32](repeating: 0, count: 256)
            for (index, argb) in palette.prefix(256).enumerated() {
                let alpha = argb >> 24
                func scaled(_ shift: UInt32) -> UInt32 { (((argb >> shift) & 0xFF) * alpha + 127) / 255 }
                lookup[index] = alpha << 24 | scaled(16) << 16 | scaled(8) << 8 | scaled(0)
            }
            var pixels = [UInt32](repeating: 0, count: width * height)
            indices.withUnsafeBytes { source in
                for position in 0..<min(pixels.count, source.count) {
                    pixels[position] = lookup[Int(source[position])]
                }
            }
            return pixels.withUnsafeBytes { Data($0) }
        }
    }

    /// Unique in the process for cues the player makes (`makeID()`), so a view can key pictures by it.
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    /// Size of the area the regions are placed on; `0` when the stream doesn't say, meaning the video's size.
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let regions: [Region]
    /// The stream gave no end (PGS never does): `endTime` is a guess that the next display set, which clears or
    /// replaces this one, replaces by its own time, later or earlier.
    let endIsEstimated: Bool
    /// The stretch of reading the set came from, when sets are collected as playback reads (`apply(_:span:)`): a seek
    /// starts another, and a set's end only comes from a later set of the same one, with nothing unread between them.
    var readSpan = 0

    public init(
        id: Int,
        startTime: Double,
        endTime: Double,
        canvasWidth: Int,
        canvasHeight: Int,
        regions: [Region],
        endIsEstimated: Bool = false
    ) {
        self.endIsEstimated = endIsEstimated
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.regions = regions
    }

    private static let lastID = OSAllocatedUnfairLock(initialState: 0)

    static func makeID() -> Int {
        lastID.withLock { id in
            id += 1
            return id
        }
    }

    /// The same set ending at `time` if it would last longer: the next display set replaces it.
    func truncated(at time: Double) -> SubtitleImageCue {
        guard endTime > time else { return self }
        return ending(at: time)
    }

    /// The same set ending at `time`, sooner or later than it was thought to.
    func ending(at time: Double) -> SubtitleImageCue {
        var ended = SubtitleImageCue(
            id: id, startTime: startTime, endTime: max(time, startTime), canvasWidth: canvasWidth,
            canvasHeight: canvasHeight, regions: regions)
        ended.readSpan = readSpan
        return ended
    }

    /// Identity and timing only: comparing pictures would make every on-screen check read megabytes.
    public static func == (lhs: SubtitleImageCue, rhs: SubtitleImageCue) -> Bool {
        lhs.id == rhs.id && lhs.startTime == rhs.startTime && lhs.endTime == rhs.endTime
    }
}

extension [SubtitleImageCue] {
    /// Applies what a packet decoded to: the set it replaces or clears ends there, and its own set joins the list.
    /// The set concerned is the latest one that started before that time. If its end was only estimated it ends there
    /// whenever that is, even later than guessed; a known end is only cut short. A set read again after a seek back
    /// starts at that time, not before it, so it is left alone, and so are the sets from further on that the list
    /// still holds. With `deduplicating`, a set starting where one already does is left out. Returns whether the list
    /// changed.
    ///
    /// With `span` (sets collected as playback reads, across seeks), the output was read in that stretch of reading:
    /// it ends the set concerned only if that set was read in the same one, as a seek may have skipped the packet that
    /// really ended it; its own set is marked with it, and so is a set it repeats, read again without a gap now.
    @discardableResult
    mutating func apply(_ output: BitmapSubtitleDecoder.Output, deduplicating: Bool = false, span: Int? = nil) -> Bool {
        var changed = false
        if let time = output.truncatePreviousAt,
            let index = indices.filter({ self[$0].startTime < time }).max(by: {
                self[$0].startTime < self[$1].startTime
            }),
            span == nil || self[index].readSpan == span
        {
            let previous = self[index]
            let updated = previous.endIsEstimated ? previous.ending(at: time) : previous.truncated(at: time)
            if updated.endTime != previous.endTime || previous.endIsEstimated {
                self[index] = updated
                changed = true
            }
        }
        if var cue = output.cue {
            if let span { cue.readSpan = span }
            if deduplicating, let existing = firstIndex(where: { abs($0.startTime - cue.startTime) < 0.05 }) {
                // Read again with its end this time (a window's set, ended within the window).
                if self[existing].endIsEstimated, !cue.endIsEstimated {
                    self[existing] = self[existing].ending(at: cue.endTime)
                    changed = true
                }
                if let span { self[existing].readSpan = span }
            } else {
                append(cue)
                changed = true
            }
        }
        return changed
    }

    /// Adds the sets of a window read (ends among them applied) to the ones playback collected in the stretch of
    /// reading `span`, which the window joins, then applies again the ends playback read in it (`truncations`). It may
    /// have read the set that clears or replaces one of the window's before the window arrived, with nothing in the
    /// list yet for it to end. A time applied twice changes nothing.
    mutating func merge(window outputs: [BitmapSubtitleDecoder.Output], span: Int, replaying truncations: [Double]) {
        var window: [SubtitleImageCue] = []
        for output in outputs { window.apply(output) }
        for cue in window { apply(BitmapSubtitleDecoder.Output(cue: cue), deduplicating: true, span: span) }
        for time in truncations.sorted() { apply(BitmapSubtitleDecoder.Output(truncatePreviousAt: time), span: span) }
    }
}
