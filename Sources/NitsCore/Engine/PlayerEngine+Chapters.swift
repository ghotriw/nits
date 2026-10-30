import Foundation

extension PlayerEngine {
    /// Seeks exactly to the start of `chapter`.
    public func seekToChapter(_ chapter: MediaChapter) {
        guard isLoaded, media.chapters.indices.contains(chapter.id) else { return }
        AppLog.info(.engine, "Seeking to chapter \(chapter.id + 1)/\(media.chapters.count) at \(chapter.start)s")
        seek(to: chapter.start, exact: true)
    }

    /// Jumps to the next chapter; returns it, or `nil` on the last chapter (playback is left as is).
    @discardableResult
    public func nextChapter() -> MediaChapter? {
        guard let chapter = ChapterNavigator.next(from: chapterNavigationTime, in: media.chapters) else { return nil }
        seekToChapter(chapter)
        return chapter
    }

    /// Restarts the current chapter, or jumps to the previous one near its start; returns the target.
    @discardableResult
    public func previousChapter() -> MediaChapter? {
        guard let chapter = ChapterNavigator.previous(from: chapterNavigationTime, in: media.chapters) else {
            return nil
        }
        seekToChapter(chapter)
        return chapter
    }

    /// Steps from the pending seek target so rapid presses chain instead of resolving to the same chapter.
    private var chapterNavigationTime: Double {
        chase?.seconds ?? currentTime
    }

    func updateCurrentChapterIndex() {
        // Most ticks stay inside the current chapter; skip the search and the observation write.
        if let index = currentChapterIndex, media.chapters.indices.contains(index) {
            let chapter = media.chapters[index]
            let nextStart = index + 1 < media.chapters.count ? media.chapters[index + 1].start : .infinity
            if currentTime + ChapterNavigator.startTolerance >= chapter.start
                && currentTime + ChapterNavigator.startTolerance < nextStart
            {
                return
            }
        }
        let index = ChapterNavigator.index(at: currentTime, in: media.chapters)
        if index != currentChapterIndex {
            AppLog.debug(
                .engine,
                "Current chapter \(String(describing: currentChapterIndex)) -> \(String(describing: index)) at \(currentTime)s (pending \(String(describing: chase?.seconds)), seeking \(isSeeking))"
            )
            currentChapterIndex = index
        }
    }
}
