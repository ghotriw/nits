import AppKit
import Foundation
import NitsCore
import NitsTestSupport
import SwiftUI
import Testing

@testable import NitsKit
@testable import NitsUI

@Suite("Player session")
@MainActor
struct PlayerSessionTests {
    /// A presentation that records what the session asks of it, as a pane of a host would.
    private final class RecordingPresentation: PlayerPresentation {
        var fullscreenToggles = 0
        func toggleFullscreen() { fullscreenToggles += 1 }
    }

    @Test("A session works without a window; fullscreen is the presentation's, and a pane has none")
    func testSessionWithoutWindow() {
        let session = PlayerSession(engine: .makeForTesting())
        #expect(session.pictureInPicture.window == nil)
        #expect(!session.supportsFullscreen)
        session.toggleFullscreen()  // nothing to toggle

        let presentation = RecordingPresentation()
        session.presentation = presentation
        #expect(!session.supportsFullscreen)
        session.toggleFullscreen()
        #expect(presentation.fullscreenToggles == 1)
        session.end()
    }

    @Test("The session takes the engine's callbacks and passes them on to the host's")
    func testCallbacksGoThroughSession() {
        let session = PlayerSession(engine: .makeForTesting())
        defer { session.end() }
        var times: [Double] = []
        var states: [PlaybackState] = []
        session.onTimeUpdate = { current, _ in times.append(current) }
        session.onPlaybackStateChanged = { states.append($0) }

        session.engine.onTimeUpdate?(5, 100)
        session.engine.onPlaybackStateChanged?(.paused)

        #expect(times == [5])
        #expect(states == [.paused])
    }

    @Test("end() reports onClose once with the position, and opens that follow do nothing")
    func testEnd() async {
        let session = PlayerSession(engine: .makeForTesting())
        var closes = 0
        session.onClose = { _, _ in closes += 1 }

        session.end()

        #expect(closes == 1)
        #expect(session.isEnded)
        let task = session.openMedia(urls: [URL(fileURLWithPath: "/nonexistent/never-opened.mkv")])
        await task?.value
        #expect(!session.engine.isLoaded)
    }

    @Test("Keys are read by physical key code and act on the session")
    func testKeyRouter() throws {
        let session = PlayerSession(engine: .makeForTesting())
        defer { session.end() }
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        // 'M' on any layout toggles mute.
        #expect(!session.isMuted)
        #expect(PlayerKeyRouter.handleKeyDown(try key(0x2E), firstResponder: nil, actions: session))
        #expect(session.isMuted)
        // A text field keeps its keys, and Command leaves the key to the menu.
        #expect(!PlayerKeyRouter.handleKeyDown(try key(0x2E), firstResponder: NSTextView(), actions: session))
        #expect(
            !PlayerKeyRouter.handleKeyDown(try key(0x2E, modifiers: .command), firstResponder: nil, actions: session))
        // Escape with nothing to dismiss and no fullscreen is not the player's.
        #expect(!PlayerKeyRouter.handleKeyDown(try key(0x35), firstResponder: nil, actions: session))
    }
}

@Suite("Player session: opening after the end")
@MainActor
struct PlayerSessionEndedTests {
    @Test("A stream opened after end() loads nothing and asks no host to show itself")
    func testOpenAfterEnd() {
        let session = PlayerSession(engine: .makeForTesting())
        var opened = 0
        session.onOpenStream = { _ in opened += 1 }
        session.end()
        session.end()  // twice: nothing happens again

        session.openStream(url: URL(fileURLWithPath: "/nonexistent/x.mkv"), presents: true)

        #expect(opened == 0)
        #expect(!session.engine.isLoaded)
    }

    @Test("The player's view is not a text input, so its keys are the player's")
    func testHostingViewIsNotATextInput() {
        let session = PlayerSession(engine: .makeForTesting())
        defer { session.end() }
        let view = NSHostingView(rootView: session.makeContentView())
        #expect(!(view is any NSTextInputClient))
    }
}
