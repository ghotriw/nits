import AppKit
import Foundation
import NitsCore
import NitsTestSupport
import Testing

@testable import NitsKit
@testable import NitsUI

@Suite("Media open request")
@MainActor
struct MediaOpenRequestTests {
    /// A folder of its own with empty files of the given names.
    private func makeFolder(_ names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test("Subtitle files come apart from the media, which resolves; a lone subtitle file keeps its own")
    func testResolving() async throws {
        let directory = try makeFolder(["movie.mkv", "Ukrainian.srt", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("movie.mkv")
        let subtitles = directory.appendingPathComponent("Ukrainian.srt")

        let request = await MediaOpenRequest.resolving([subtitles, movie], source: "Test")
        #expect(request.media.map(\.lastPathComponent) == ["movie.mkv"])
        #expect(request.subtitles == [subtitles])

        let alone = await MediaOpenRequest.resolving([subtitles], source: "Test")
        #expect(alone == MediaOpenRequest(media: [], subtitles: [subtitles]))
    }

    @Test("Subtitles that came with media that can't be opened don't go to the media playing")
    func testSubtitlesDroppedWithUnplayableMedia() async throws {
        let directory = try makeFolder(["Ukrainian.srt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.mkv")

        let request = await MediaOpenRequest.resolving(
            [missing, directory.appendingPathComponent("Ukrainian.srt")], source: "Test")
        #expect(request == MediaOpenRequest(media: []))
    }

    @Test("Opening nothing playable, or subtitles with nothing loaded, says so on the OSD")
    func testOpenWithoutMedia() async {
        let controller = PlayerWindowController(engine: .makeForTesting())
        defer { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }

        await controller.open(MediaOpenRequest(media: []))
        guard case .custom(_, let nothing, _, _) = controller.uiState.osd.currentEvent else {
            Issue.record("Expected a custom OSD event, got \(String(describing: controller.uiState.osd.currentEvent))")
            return
        }
        #expect(nothing == "No playable media")

        await controller.open(MediaOpenRequest(media: [], subtitles: [URL(fileURLWithPath: "/m/a.srt")]))
        guard case .custom(_, let noVideo, _, _) = controller.uiState.osd.currentEvent else {
            Issue.record("Expected a custom OSD event, got \(String(describing: controller.uiState.osd.currentEvent))")
            return
        }
        #expect(noVideo == "Open a video first")
        #expect(controller.engine.subtitles.tracks.isEmpty)
    }

    @Test("Subtitles opened with a file that fails to load are not attached")
    func testSubtitlesNotAttachedWhenLoadFails() async throws {
        let directory = try makeFolder(["broken.mkv", "Ukrainian.srt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PlayerWindowController(engine: .makeForTesting())
        defer { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }

        await controller.open(
            MediaOpenRequest(
                media: [directory.appendingPathComponent("broken.mkv")],
                subtitles: [directory.appendingPathComponent("Ukrainian.srt")]))
        #expect(!controller.engine.isLoaded)
        #expect(controller.engine.subtitles.tracks.isEmpty)
    }

    @Test("A drop opens in place, without bringing the window forward")
    func testDropOpensInPlace() async throws {
        let directory = try makeFolder(["broken.mkv"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PlayerWindowController(engine: .makeForTesting())
        defer { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }

        await controller.openMedia(urls: [directory.appendingPathComponent("broken.mkv")])?.value
        #expect(controller.engine.loadError != nil)
        #expect(controller.window?.isVisible == false)
    }

    @Test("A drop still resolving when the window closes opens nothing")
    func testDropAfterCloseOpensNothing() async throws {
        let directory = try makeFolder(["broken.mkv"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PlayerWindowController(engine: .makeForTesting())

        let task = controller.openMedia(urls: [directory.appendingPathComponent("broken.mkv")])
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await task?.value
        #expect(controller.engine.loadError == nil)
        #expect(controller.window?.isVisible == false)
    }
}
