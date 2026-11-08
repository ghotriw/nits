import AppKit
import NitsCore
import NitsTestSupport
import Testing

@testable import NitsKit
@testable import NitsUI

@Suite("Host window presentation")
@MainActor
struct HostWindowPresentationTests {
    private func makeWindow(toolbar: NSToolbar? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbar = toolbar
        return window
    }

    @Test("Attaching presents the session in the window and takes its title bar; detaching gives both back")
    func testAttachAndDetach() {
        let session = PlayerSession(engine: .makeForTesting())
        defer { session.end() }
        let window = makeWindow()

        let presentation = HostWindowPresentation(session: session, window: window)
        #expect(session.presentation === presentation)
        #expect(session.pictureInPicture.window === window)
        #expect(session.supportsFullscreen)
        #expect(session.uiState.movesWindow)
        #expect(session.uiState.titleBarDoubleClicked != nil)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.toolbar != nil)  // a compact one, as tall as the header strip

        session.onControlsVisibilityChanged?(false)
        #expect(!presentation.areControlsVisible)
        session.onOpenStream?(false)
        #expect(presentation.areControlsVisible)

        presentation.detach()
        #expect(session.presentation == nil)
        #expect(session.pictureInPicture.window == nil)
        #expect(!session.uiState.movesWindow)
        #expect(session.uiState.titleBarDoubleClicked == nil)
        #expect(session.onOpenStream == nil)
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .visible)
        #expect(window.toolbar == nil)
        #expect(!session.isEnded)  // the host may show it elsewhere
    }

    @Test("A host's toolbar stays the host's; without adopting the title bar the window is left as it is")
    func testHostToolbarAndPlainTitleBar() {
        let session = PlayerSession(engine: .makeForTesting())
        defer { session.end() }
        let toolbar = NSToolbar()
        let window = makeWindow(toolbar: toolbar)

        let adopting = HostWindowPresentation(session: session, window: window)
        #expect(window.toolbar === toolbar)
        adopting.detach()
        #expect(window.toolbar === toolbar)
        #expect(window.toolbarStyle == .automatic)

        let plain = HostWindowPresentation(session: session, window: window, adoptsTitleBar: false)
        #expect(session.presentation === plain)
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(!window.titlebarAppearsTransparent)
        plain.detach()
    }

    @Test("Closing the window ends the session and detaches before the host hears of it")
    func testWindowClose() {
        let session = PlayerSession(engine: .makeForTesting())
        let window = makeWindow()
        let presentation = HostWindowPresentation(session: session, window: window)
        var closes = 0
        presentation.onWindowClose = {
            #expect(session.isEnded)
            #expect(session.presentation == nil)
            closes += 1
        }

        window.close()

        #expect(closes == 1)
        #expect(!window.titlebarAppearsTransparent)
    }

    @Test(
        "Presenting a session elsewhere gives the first window back at once, and releasing the old one changes nothing")
    func testReplacement() {
        let session = PlayerSession(engine: .makeForTesting())
        defer { session.end() }
        let first = makeWindow()
        let second = makeWindow()

        var old: HostWindowPresentation? = HostWindowPresentation(session: session, window: first)
        let current = HostWindowPresentation(session: session, window: second)
        #expect(!first.titlebarAppearsTransparent)  // given back before the old one is released
        #expect(first.toolbar == nil)
        current.detach()
        old = nil  // released after the session was detached from the new one: nothing of it comes back

        #expect(old == nil)
        #expect(session.presentation == nil)
        #expect(!session.uiState.movesWindow)
        #expect(session.onOpenStream == nil)
    }

    @Test("Presenting again in the same window keeps the title bar the window had before the first")
    func testReplacementInSameWindow() {
        let session = PlayerSession(engine: .makeForTesting())
        defer { session.end() }
        let window = makeWindow()

        let first = HostWindowPresentation(session: session, window: window)
        let second = HostWindowPresentation(session: session, window: window)
        #expect(session.presentation === second)
        #expect(window.titlebarAppearsTransparent)
        second.detach()
        first.detach()  // detached already

        #expect(!window.titlebarAppearsTransparent)
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .visible)
        #expect(window.toolbar == nil)
    }
}
