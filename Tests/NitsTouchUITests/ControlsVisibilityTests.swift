#if os(iOS)
    import Testing

    @testable import NitsTouchUI

    @Suite("Controls visibility")
    struct ControlsVisibilityTests {
        private let start = ContinuousClock.now
        private let playing = ControlsVisibility.Context(isLoaded: true, isPlaying: true)

        private func at(_ seconds: Double) -> ContinuousClock.Instant {
            start + .milliseconds(Int(seconds * 1000))
        }

        @Test("While playing the controls hide three seconds after the last touch")
        func hidesAfterThreeSecondsWhilePlaying() {
            let visibility = ControlsVisibility(now: start)
            #expect(visibility.isVisible(at: at(0), playing))
            #expect(visibility.isVisible(at: at(2.9), playing))
            #expect(!visibility.isVisible(at: at(3.0), playing))
        }

        @Test("Paused, they stay however long")
        func staysWhilePaused() {
            let visibility = ControlsVisibility(now: start)
            var paused = playing
            paused.isPlaying = false
            #expect(visibility.isVisible(at: at(600), paused))
        }

        @Test("Scrubbing, buffering, an error or VoiceOver keeps them")
        func staysWhileScrubbing() {
            let visibility = ControlsVisibility(now: start)
            for change: (inout ControlsVisibility.Context) -> Void in [
                { $0.isScrubbing = true }, { $0.isBuffering = true }, { $0.hasError = true },
                { $0.isVoiceOverRunning = true },
            ] {
                var context = playing
                change(&context)
                #expect(visibility.isVisible(at: at(600), context))
            }
        }

        @Test("Nothing loaded keeps them (there is the empty state)")
        func staysWithNothingLoaded() {
            #expect(ControlsVisibility(now: start).isVisible(at: at(600), .init()))
        }

        @Test("A touch starts the three seconds again")
        func touchRestartsTimer() {
            var visibility = ControlsVisibility(now: start)
            visibility.touch(at: at(2))
            #expect(visibility.isVisible(at: at(4.9), playing))
            #expect(!visibility.isVisible(at: at(5.0), playing))
        }

        @Test("A tap hides what shows and shows what is hidden")
        func toggle() {
            var visibility = ControlsVisibility(now: start)
            visibility.toggle(at: at(1), playing)
            #expect(!visibility.isVisible(at: at(1), playing))
            visibility.toggle(at: at(2), playing)
            #expect(visibility.isVisible(at: at(2), playing))
            // Paused they cannot be hidden: the tap changes nothing visible.
            var paused = playing
            paused.isPlaying = false
            visibility.toggle(at: at(3), paused)
            #expect(visibility.isVisible(at: at(3), paused))
        }
    }

    @Suite("Scrub timeline")
    struct ScrubTimelineTests {
        @Test("A recording runs from 0 to its length")
        func recording() {
            let timeline = ScrubTimeline(duration: 200)
            #expect(timeline.fraction(of: 50) == 0.25)
            #expect(timeline.time(at: 0.5) == 100)
            #expect(timeline.fraction(of: 500) == 1)
            #expect(timeline.time(at: -1) == 0)
        }

        @Test("A live stream runs over its window")
        func live() {
            let timeline = ScrubTimeline(duration: 0, liveWindow: (start: 1000, end: 1060))
            #expect(timeline.fraction(of: 1030) == 0.5)
            #expect(timeline.time(at: 1) == 1060)
        }

        @Test("An empty span is at 0 and takes no touch")
        func empty() {
            let timeline = ScrubTimeline(duration: 0)
            #expect(timeline.isEmpty)
            #expect(timeline.fraction(of: 5) == 0)
        }

        @Test("Clock text")
        func clock() {
            #expect(ScrubTimeline.clock(65) == "1:05")
            #expect(ScrubTimeline.clock(3725) == "1:02:05")
            #expect(ScrubTimeline.clock(.nan) == "--:--")
        }
    }
#endif
