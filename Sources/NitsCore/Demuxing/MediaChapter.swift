import Foundation

/// A chapter marker read from the container (MKV `ChapterAtom`, MP4 chapter track / Nero `chpl`).
/// Times are in seconds on the same timeline as packet timestamps.
public struct MediaChapter: Sendable, Identifiable, Equatable {
    /// Position in the sorted chapter list.
    public let id: Int
    /// Container title; `nil` when the chapter has none.
    public let title: String?
    public let start: Double
    public let end: Double

    public init(id: Int, title: String?, start: Double, end: Double) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }

    public var duration: Double { max(end - start, 0) }

    /// `title`, or "Chapter N" when the container gives none.
    public var displayTitle: String { title ?? "Chapter \(id + 1)" }
}

extension MediaChapter {
    /// One chapter as read from the container, before cleanup.
    public struct Raw: Sendable, Equatable {
        public var title: String?
        public var start: Double
        /// `nil` when the container does not set an end.
        public var end: Double?

        public init(title: String?, start: Double, end: Double?) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// Sorts raw chapters, fills missing ends from the next chapter (or `duration`), clamps them to
    /// `duration` when it is known and drops duplicates and chapters that start past the end.
    public static func normalized(_ raw: [Raw], duration: Double) -> [MediaChapter] {
        let hasDuration = duration > 0
        let sorted =
            raw
            .filter { $0.start.isFinite && (!hasDuration || $0.start < duration) }
            .sorted { $0.start < $1.start }

        var starts: [(title: String?, start: Double, end: Double?)] = []
        for entry in sorted {
            let start = max(entry.start, 0)
            // Two chapters at the same position can't both be jumped to; keep the first.
            if let last = starts.last, abs(last.start - start) < 0.001 { continue }
            let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            starts.append((title?.isEmpty == false ? title : nil, start, entry.end))
        }

        return starts.enumerated().map { index, entry in
            let nextStart = index + 1 < starts.count ? starts[index + 1].start : nil
            var end = entry.end ?? nextStart ?? (hasDuration ? duration : entry.start)
            if let nextStart { end = min(end, nextStart) }
            if hasDuration { end = min(end, duration) }
            return MediaChapter(id: index, title: entry.title, start: entry.start, end: max(end, entry.start))
        }
    }
}

/// Chapter lookups and navigation targets.
public enum ChapterNavigator {
    /// "Previous chapter" restarts the current chapter when playback is further into it than this.
    public static let restartThreshold: Double = 5

    /// A position this close before a chapter start counts as that chapter. An exact seek settles on the frame
    /// whose display interval contains the target, so a chapter starting between frame boundaries lands up to half a
    /// frame early (over 40 ms at 12 fps); without the tolerance the chapter just jumped to would read as the
    /// previous one, and "next" would repeat it.
    static let startTolerance: Double = 0.25

    /// Index of the chapter playing at `time`, or `nil` before the first chapter.
    public static func index(at time: Double, in chapters: [MediaChapter]) -> Int? {
        var low = 0
        var high = chapters.count
        while low < high {
            let mid = (low + high) / 2
            if chapters[mid].start <= time + startTolerance {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The chapter "next chapter" goes to, or `nil` on the last chapter.
    public static func next(from time: Double, in chapters: [MediaChapter]) -> MediaChapter? {
        let target = index(at: time, in: chapters).map { $0 + 1 } ?? 0
        return target < chapters.count ? chapters[target] : nil
    }

    /// The chapter "previous chapter" goes to: the start of the current chapter when playback is more
    /// than `threshold` into it (or it is the first), otherwise the previous one.
    public static func previous(
        from time: Double, in chapters: [MediaChapter], threshold: Double = restartThreshold
    ) -> MediaChapter? {
        guard let current = index(at: time, in: chapters) else { return nil }
        if time - chapters[current].start > threshold || current == 0 {
            return chapters[current]
        }
        return chapters[current - 1]
    }
}
