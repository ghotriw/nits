import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("Action Buttons")
struct ActionButtonTests {
    private static let intro = PlaybackActionButton(id: "intro", title: "Skip Intro", start: 10, end: 70)
    private static let recap = PlaybackActionButton(id: "recap", title: "Skip Recap", start: 20, end: 30)
    private static let next = PlaybackActionButton(id: "next", title: "Next Episode", start: 2666.5)

    @Test("A span includes its start, excludes its end, and an open end runs to the end of the media")
    func testContains() {
        #expect(!Self.intro.contains(9.99))
        #expect(Self.intro.contains(10))
        #expect(Self.intro.contains(69.99))
        #expect(!Self.intro.contains(70))
        #expect(Self.next.contains(2666.5))
        #expect(Self.next.contains(100_000))
        #expect(!Self.next.contains(.nan))
    }

    @Test("The active button is the one that started last among those containing the time")
    func testActiveLookup() {
        let buttons = [Self.recap, Self.intro, Self.next]
        #expect(PlaybackActionButton.active(in: buttons, at: 5) == nil)
        #expect(PlaybackActionButton.active(in: buttons, at: 15) == Self.intro)
        #expect(PlaybackActionButton.active(in: buttons, at: 25) == Self.recap)
        #expect(PlaybackActionButton.active(in: buttons, at: 30) == Self.intro)
        #expect(PlaybackActionButton.active(in: buttons, at: 100) == nil)
        #expect(PlaybackActionButton.active(in: buttons, at: 2700) == Self.next)
        #expect(PlaybackActionButton.active(in: [], at: 15) == nil)
    }

    @Test("A subtitle or artwork makes the button an Up Next card; a plain title stays a plain button")
    func testCard() {
        #expect(!Self.intro.isCard)
        let withSubtitle = PlaybackActionButton(
            id: "next", title: "Next Episode", start: 2666.5, subtitle: "S2 · E5 · The Episode")
        #expect(withSubtitle.isCard)
        let withArtwork = PlaybackActionButton(
            id: "next", title: "Next Episode", start: 2666.5,
            artworkURL: URL(string: "https://media.example/Items/42/Images/Primary?api_key=abc"))
        #expect(withArtwork.isCard)
    }

    @Test("Engine follows the playback position and reports presses of its own buttons only")
    @MainActor
    func testEngineActiveButtonAndPress() {
        let engine = PlayerEngine.makeForTesting()
        var pressed: [String] = []
        engine.actionButtons.onPress = { pressed.append($0) }

        engine.currentTime = 15
        engine.actionButtons.setHostButtons([Self.intro, Self.next])
        // Nothing is active until media is loaded.
        #expect(engine.actionButtons.active == nil)
        engine.isLoaded = true
        #expect(engine.actionButtons.active == Self.intro)

        engine.currentTime = 70
        #expect(engine.actionButtons.active == nil)
        engine.currentTime = 2700
        #expect(engine.actionButtons.active == Self.next)

        engine.actionButtons.perform(Self.next)
        engine.actionButtons.perform(Self.recap)  // not one of the engine's buttons
        #expect(pressed == ["next"])

        engine.actionButtons.setHostButtons([])
        #expect(engine.actionButtons.active == nil)
    }

    @Test("A load replaces the previous media's buttons at once with the request's, and stop clears them")
    @MainActor
    func testLoadReplacesButtons() {
        let engine = PlayerEngine.makeForTesting()
        engine.actionButtons.setHostButtons([Self.next])

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nits-missing-\(UUID()).mkv").path
        let generation = engine.actionButtons.loadGeneration
        engine.load(MediaLoadRequest(path: missing))
        #expect(engine.actionButtons.buttons.isEmpty)
        #expect(engine.actionButtons.active == nil)
        #expect(engine.actionButtons.loadGeneration == generation + 1)

        engine.load(MediaLoadRequest(path: missing).actionButtons([Self.intro]))
        #expect(engine.actionButtons.buttons == [Self.intro])

        engine.stop()
        #expect(engine.actionButtons.buttons.isEmpty)
    }
}
