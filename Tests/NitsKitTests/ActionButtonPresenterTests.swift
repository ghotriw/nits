import NitsCore
import Testing

@testable import NitsUI

@Suite("Action button presenter")
@MainActor
struct ActionButtonPresenterTests {
    private static let intro = PlaybackActionButton(id: "intro", title: "Skip Intro", start: 10, end: 70)
    private static let next = PlaybackActionButton(
        id: "next", title: "Next Episode", start: 2666.5, allowsAutoPress: false)

    private func makePresenter(autoPress: Bool = false) -> ActionButtonPresenter {
        let presenter = ActionButtonPresenter()
        presenter.displayDuration = 8
        presenter.autoPress = autoPress
        return presenter
    }

    /// Plays from `start` to `end` in 50 ms ticks, as the engine's time observer does, and returns the auto-presses.
    @discardableResult
    private func play(
        _ presenter: ActionButtonPresenter, from start: Double, to end: Double,
        buttons: [PlaybackActionButton] = [intro]
    ) -> [String] {
        var pressed: [String] = []
        let steps = Int(((end - start) / 0.05).rounded())
        for step in 0...steps {
            // Rounded to microseconds so the last tick lands exactly on `end`.
            let time = ((start + Double(step) * 0.05) * 1e6).rounded() / 1e6
            let active = PlaybackActionButton.active(in: buttons, at: time)
            if let button = presenter.update(active: active, at: time, isPlaying: true) {
                pressed.append(button.id)
            }
        }
        return pressed
    }

    @Test("The button stays up for its display time, then only with the controls, and goes when the span ends")
    func testVisibility() {
        let presenter = makePresenter()
        play(presenter, from: 9, to: 9.5)
        #expect(presenter.button == nil && !presenter.isVisible)

        play(presenter, from: 10, to: 17.5)
        #expect(presenter.button == Self.intro)
        #expect(presenter.isProminent && presenter.isVisible)
        #expect(presenter.autoPressProgress == nil)

        play(presenter, from: 17.55, to: 18.5)
        #expect(!presenter.isProminent && !presenter.isVisible)
        presenter.areControlsVisible = true
        #expect(presenter.isVisible)

        play(presenter, from: 18.55, to: 70)
        #expect(presenter.button == nil && !presenter.isVisible)
    }

    @Test("Auto-press fills up over the display time and presses once at its end")
    func testAutoPress() {
        let presenter = makePresenter(autoPress: true)
        #expect(play(presenter, from: 10, to: 14).isEmpty)
        #expect(abs((presenter.autoPressProgress ?? -1) - 0.5) < 0.01)

        #expect(play(presenter, from: 14.05, to: 20) == ["intro"])
        #expect(presenter.button == nil)
    }

    @Test("The countdown holds while paused and restarts after a seek inside the span")
    func testPauseAndSeek() {
        let presenter = makePresenter(autoPress: true)
        play(presenter, from: 10, to: 15)
        // Paused: the same position keeps coming (or nothing at all) and the countdown holds.
        for _ in 0..<100 { _ = presenter.update(active: Self.intro, at: 15, isPlaying: true) }
        #expect(abs(presenter.elapsed - 5) < 0.01)
        // Clock jitter a few frames back (a resume re-anchoring the clock) is not a seek.
        _ = presenter.update(active: Self.intro, at: 14.9, isPlaying: true)
        _ = presenter.update(active: Self.intro, at: 15.05, isPlaying: true)
        #expect(abs(presenter.elapsed - 5.05) < 0.01)

        // A seek forward inside the span restarts it rather than counting the skipped time.
        #expect(play(presenter, from: 40, to: 47) == [])
        #expect(presenter.isProminent)
        // A seek back restarts it too.
        play(presenter, from: 20, to: 21)
        #expect(abs(presenter.elapsed - 1) < 0.01)
    }

    @Test("Scrubbing and frame steps on pause don't count; a scrub past jitter restarts the countdown")
    func testPausedMovesDontCount() {
        let presenter = makePresenter(autoPress: true)
        play(presenter, from: 10, to: 15)
        // Frame steps forward and back: no count, no restart, and no drift building up to one.
        for step in 1...300 {
            #expect(presenter.update(active: Self.intro, at: 15 + Double(step) * 0.04, isPlaying: false) == nil)
        }
        for step in 1...20 {
            _ = presenter.update(active: Self.intro, at: 27 - Double(step) * 0.04, isPlaying: false)
        }
        #expect(abs(presenter.elapsed - 5) < 0.01)
        // Dragging the timeline in big steps restarts it, still without counting.
        for time in stride(from: 30.0, through: 40.0, by: 0.5) {
            #expect(presenter.update(active: Self.intro, at: time, isPlaying: false) == nil)
        }
        #expect(presenter.elapsed == 0)
        #expect(presenter.isProminent)
    }

    @Test("A 1 s arrow seek while playing restarts the countdown")
    func testOneSecondSeek() {
        let presenter = makePresenter()
        play(presenter, from: 10, to: 15)
        // As seen mid-seek (not playing), and as a bare position jump.
        _ = presenter.update(active: Self.intro, at: 16, isPlaying: false)
        #expect(presenter.elapsed == 0)
        play(presenter, from: 16, to: 18)
        _ = presenter.update(active: Self.intro, at: 19, isPlaying: true)
        #expect(presenter.elapsed == 0)
    }

    @Test("A reset for new media brings back a dismissed button of the same id")
    func testResetForNewMedia() {
        let presenter = makePresenter()
        play(presenter, from: 10, to: 12)
        presenter.dismiss()
        #expect(play(presenter, from: 12.05, to: 13).isEmpty)
        #expect(presenter.button == nil)

        presenter.reset()
        _ = presenter.update(active: Self.intro, at: 13, isPlaying: false)
        #expect(presenter.button == Self.intro && presenter.isProminent)
    }

    @Test("Auto-press stays off for a button that opts out and when the span ends first")
    func testNoAutoPress() {
        let presenter = makePresenter(autoPress: true)
        #expect(play(presenter, from: 2666.5, to: 2690, buttons: [Self.next]).isEmpty)
        #expect(presenter.autoPressProgress == nil)

        let short = PlaybackActionButton(id: "recap", title: "Skip Recap", start: 0, end: 5)
        #expect(play(presenter, from: 0, to: 10, buttons: [short]).isEmpty)
    }

    @Test("Dismissing hides the button for the rest of its span; coming back into the span shows it again")
    func testDismiss() {
        let presenter = makePresenter(autoPress: true)
        play(presenter, from: 10, to: 12)
        presenter.dismiss()
        #expect(presenter.button == nil && !presenter.isVisible)

        presenter.areControlsVisible = true
        #expect(play(presenter, from: 12.05, to: 30).isEmpty)
        #expect(presenter.button == nil)
        // A seek inside the span keeps it dismissed.
        play(presenter, from: 50, to: 51)
        #expect(presenter.button == nil)

        // Leaving the span and seeking back in brings it back with a fresh countdown.
        play(presenter, from: 5, to: 5)
        play(presenter, from: 12, to: 13)
        #expect(presenter.button == Self.intro && presenter.isProminent)
    }

    @Test("A press takes the button once and hides it")
    func testPress() {
        let presenter = makePresenter()
        #expect(presenter.press() == nil)
        play(presenter, from: 10, to: 11)
        #expect(presenter.press() == Self.intro)
        #expect(presenter.press() == nil)
        #expect(!presenter.isVisible)
    }

    @Test("A button replaced mid-span with the same id keeps its state and takes the new title")
    func testReplacedButton() {
        let presenter = makePresenter()
        play(presenter, from: 10, to: 12)
        let renamed = PlaybackActionButton(id: "intro", title: "Skip Opening", start: 10, end: 70)
        play(presenter, from: 12.05, to: 13, buttons: [renamed])
        #expect(presenter.button?.title == "Skip Opening")
        #expect(abs(presenter.elapsed - 3) < 0.01)
    }
}
