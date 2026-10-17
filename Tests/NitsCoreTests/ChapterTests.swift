import Foundation
import Testing

@testable import NitsCore

@Suite("Container Chapters", .hostDependent)
struct ChapterTests {
    private static func chapters(_ starts: [Double], duration: Double) -> [MediaChapter] {
        MediaChapter.normalized(starts.map { MediaChapter.Raw(title: nil, start: $0, end: nil) }, duration: duration)
    }

    // MARK: - Normalization

    @Test("Normalization sorts, fills missing ends and drops duplicates and out-of-range chapters")
    func testNormalization() {
        let raw: [MediaChapter.Raw] = [
            .init(title: "  Third  ", start: 20, end: nil),
            .init(title: "First", start: 0, end: 12),  // overlaps the next start: clipped
            .init(title: "Duplicate", start: 0, end: 5),
            .init(title: "", start: 10, end: nil),
            .init(title: "Past end", start: 40, end: 45),
            .init(title: "Bad", start: .nan, end: nil),
        ]
        let chapters = MediaChapter.normalized(raw, duration: 30)

        #expect(chapters.map(\.start) == [0, 10, 20])
        #expect(chapters.map(\.end) == [10, 20, 30])
        #expect(chapters.map(\.id) == [0, 1, 2])
        #expect(chapters.map(\.title) == ["First", nil, "Third"])
        #expect(chapters[1].displayTitle == "Chapter 2")
    }

    @Test("Normalization keeps an explicit end before the next start and clamps to the duration")
    func testNormalizationEnds() {
        let raw: [MediaChapter.Raw] = [
            .init(title: nil, start: 0, end: 8),
            .init(title: nil, start: 10, end: 50),
        ]
        let chapters = MediaChapter.normalized(raw, duration: 30)
        #expect(chapters.map(\.end) == [8, 30])

        // Unknown duration (live stream): the last chapter keeps its own end.
        #expect(MediaChapter.normalized(raw, duration: 0).map(\.end) == [8, 50])
    }

    // MARK: - Navigation

    @Test("Chapter lookup finds the chapter at a time, tolerating positions just before a start")
    func testIndexLookup() {
        let chapters = Self.chapters([5, 10, 20], duration: 30)
        #expect(ChapterNavigator.index(at: 0, in: chapters) == nil)
        #expect(ChapterNavigator.index(at: 5, in: chapters) == 0)
        #expect(ChapterNavigator.index(at: 9.99, in: chapters) == 1)
        // An exact seek to 10s that settled a few frames early still counts as that chapter.
        #expect(ChapterNavigator.index(at: 9.92, in: chapters) == 1)
        #expect(ChapterNavigator.index(at: 9.5, in: chapters) == 0)
        #expect(ChapterNavigator.index(at: 15, in: chapters) == 1)
        #expect(ChapterNavigator.index(at: 29, in: chapters) == 2)
        #expect(ChapterNavigator.index(at: 3, in: []) == nil)
    }

    @Test("Next chapter steps forward and stops on the last one")
    func testNext() {
        let chapters = Self.chapters([5, 10, 20], duration: 30)
        #expect(ChapterNavigator.next(from: 0, in: chapters)?.start == 5)
        #expect(ChapterNavigator.next(from: 12, in: chapters)?.start == 20)
        #expect(ChapterNavigator.next(from: 25, in: chapters) == nil)
        // Landing just short of a chapter start must not make "next" repeat that chapter.
        #expect(ChapterNavigator.next(from: 9.94, in: chapters)?.start == 20)
        #expect(ChapterNavigator.next(from: 0, in: []) == nil)
    }

    @Test("Previous chapter restarts the current one past the threshold, else goes back")
    func testPrevious() {
        let chapters = Self.chapters([0, 10, 20], duration: 30)
        #expect(ChapterNavigator.previous(from: 17, in: chapters)?.start == 10)
        #expect(ChapterNavigator.previous(from: 12, in: chapters)?.start == 0)
        #expect(ChapterNavigator.previous(from: 10, in: chapters)?.start == 0)
        #expect(ChapterNavigator.previous(from: 3, in: chapters)?.start == 0)
        #expect(ChapterNavigator.previous(from: 3, in: Self.chapters([5], duration: 30)) == nil)
    }

    // MARK: - Demuxing

    @Test(
        "Demuxer reads chapters from MKV and MP4",
        arguments: [
            SyntheticTestMediaFactory.Preset.chaptersMKV, .chaptersMP4,
        ])
    func testDemuxerChapters(preset: SyntheticTestMediaFactory.Preset) {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: preset) else { return }
        guard let demuxer = MediaDemuxer(url: path) else {
            Issue.record("Failed to open \(preset.filename)")
            return
        }

        // FFmpeg's MP4 chapter track drops an untitled chapter (the previous one then runs on to the next
        // start), and FFmpeg also exports the Nero `chpl` copy of the last chapter, which normalization drops.
        let isMP4 = preset == .chaptersMP4
        let expected = SyntheticTestMediaFactory.chapterMarkers.filter { !isMP4 || $0.title != nil }
        let chapters = demuxer.chapters
        #expect(chapters.count == expected.count)
        for (index, (chapter, marker)) in zip(chapters, expected).enumerated() {
            let expectedEnd = index + 1 < expected.count ? expected[index + 1].start : marker.end
            #expect(abs(chapter.start - marker.start) < 0.01, "\(chapter) vs \(marker)")
            #expect(abs(chapter.end - expectedEnd) < 0.1, "\(chapter) vs \(marker)")
        }
        #expect(chapters.first?.title == "Opening")
        #expect(chapters.dropFirst().first?.title == "Глава вторая")
        #expect(chapters.last?.title == "Finale")
    }

    @Test("Media without chapters has an empty chapter list")
    func testNoChapters() {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .av1SDR) else { return }
        #expect(MediaDemuxer(url: path)?.chapters.isEmpty == true)
    }

    // MARK: - Engine

    @Test("Engine exposes chapters, tracks the current one and jumps between them", .realtimePlayback)
    @MainActor
    func testEngineNavigation() async throws {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .chaptersMKV) else { return }
        let engine = PlayerEngine.makeForTesting()
        engine.load(path: path)
        #expect(engine.isLoaded)
        #expect(engine.chapters.count == SyntheticTestMediaFactory.chapterMarkers.count)
        #expect(engine.currentChapterIndex == 0)

        // Load autoplays; navigate paused so the position stays where a seek lands. Playing, a busy CI runner
        // resumed the test seconds after the landing, with the clock already in the next chapter.
        engine.pause()
        #expect(
            await engine.waitUntil { !engine.isPlaying && !engine.isSeeking && engine.pendingSeekTime == nil },
            "Pause did not settle")

        #expect(engine.nextChapter()?.start == 4)
        // A second press while the first seek is in flight chains from its target.
        #expect(engine.nextChapter()?.start == 9)
        #expect(await engine.waitUntil { !engine.isSeeking && engine.pendingSeekTime == nil })
        #expect(abs(engine.currentTime - 9) < 0.05, "Expected to land on 9s, got \(engine.currentTime)s")
        #expect(engine.currentChapterIndex == 2)

        // Right at the chapter start "previous" goes back a chapter.
        #expect(engine.previousChapter()?.start == 4)
        #expect(await engine.waitUntil { !engine.isSeeking && engine.pendingSeekTime == nil })
        #expect(engine.currentChapterIndex == 1)

        engine.seekToChapter(try #require(engine.chapters.last))
        #expect(await engine.waitUntil { !engine.isSeeking && engine.pendingSeekTime == nil })
        #expect(engine.currentChapterIndex == 3)
        #expect(engine.nextChapter() == nil)

        engine.stop()
        #expect(engine.chapters.isEmpty)
        #expect(engine.currentChapterIndex == nil)
    }
}
