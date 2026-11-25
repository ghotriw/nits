#if os(iOS)
    import Foundation

    /// When the controls are on screen: on a load, on a pause and on any touch, and for three seconds after the last
    /// touch while the video plays. Never while it is paused, scrubbed, buffering or showing an error. A value over
    /// instants, so a test brings its own clock.
    struct ControlsVisibility: Equatable {
        static let hideDelay: Duration = .seconds(3)

        /// What the screen is doing, as far as the controls care.
        struct Context: Equatable {
            var isLoaded = false
            var isPlaying = false
            var isScrubbing = false
            var isBuffering = false
            var hasError = false
            /// VoiceOver is running: its user would lose the buttons three seconds after the last touch.
            var isVoiceOverRunning = false
            /// A panel (chapters) is open over the picture: it is read, so the controls stay with it.
            var isPanelOpen = false

            /// The controls stay whatever the time.
            var holdsControls: Bool {
                !isLoaded || !isPlaying || isScrubbing || isBuffering || hasError || isVoiceOverRunning || isPanelOpen
            }
        }

        private(set) var lastTouch: ContinuousClock.Instant

        init(now: ContinuousClock.Instant = .now) {
            lastTouch = now
        }

        mutating func touch(at now: ContinuousClock.Instant = .now) {
            lastTouch = now
        }

        func isVisible(at now: ContinuousClock.Instant = .now, _ context: Context) -> Bool {
            context.holdsControls || now - lastTouch < Self.hideDelay
        }

        /// A tap on the picture: hides the controls that are showing (where they may go), shows those that are not.
        mutating func toggle(at now: ContinuousClock.Instant = .now, _ context: Context) {
            if isVisible(at: now, context) {
                lastTouch = now - Self.hideDelay
            } else {
                lastTouch = now
            }
        }
    }
#endif
