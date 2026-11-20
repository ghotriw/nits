#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The timeline: what is buffered, where playback is, and a drag that scrubs. A drag begins scrubbing, shows the frames
    /// it passes (a seek that only shows), and on release seeks exactly to where it was let go and ends scrubbing.
    struct ScrubBar: View {
        let engine: PlayerEngine
        let timeline: ScrubTimeline
        /// The fraction being dragged to, while a drag is under way.
        @Binding var dragFraction: Double?

        /// True while the finger is down: the gesture's state, which SwiftUI resets when the system cancels the gesture
        /// (Control Center, the home gesture, a call), a case `onEnded` is never told of.
        @GestureState private var isFingerDown = false

        private static let barHeight: CGFloat = 4

        var body: some View {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let played = dragFraction ?? timeline.fraction(of: engine.currentTime)
                let buffered = timeline.fraction(of: engine.bufferedTime)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.35)).frame(width: width * buffered)
                    Capsule().fill(.white).frame(width: width * played)
                    Circle()
                        .fill(.white)
                        .frame(width: dragFraction == nil ? 12 : 18, height: dragFraction == nil ? 12 : 18)
                        .offset(x: width * played - (dragFraction == nil ? 6 : 9))
                }
                .frame(height: Self.barHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isFingerDown) { _, state, _ in state = true }
                        .onChanged { value in
                            guard !timeline.isEmpty else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            if dragFraction == nil { engine.beginScrubbing() }
                            dragFraction = fraction
                            engine.seek(to: timeline.time(at: fraction))
                        }
                        .onEnded { value in
                            guard !timeline.isEmpty, dragFraction != nil else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            engine.seek(to: timeline.time(at: fraction), exact: true)
                            engine.endScrubbing()
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 44)
            .onChange(of: isFingerDown) { wasDown, isDown in
                // The finger is up and a drag is still on: the system took the gesture, with no `onEnded`.
                guard ScrubDragCancellation.isCancelled(wasDown: wasDown, isDown: isDown, dragFraction: dragFraction)
                else { return }
                engine.endScrubbing()
                dragFraction = nil
            }
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityValue(ScrubTimeline.clock(engine.currentTime))
        }
    }

    /// When a drag of the bar ended without `onEnded`.
    enum ScrubDragCancellation {
        /// The finger went up (`wasDown`, no longer `isDown`) while the bar still shows a drag (`dragFraction`): a finished
        /// drag has cleared it in `onEnded`, which runs before the gesture's state resets.
        static func isCancelled(wasDown: Bool, isDown: Bool, dragFraction: Double?) -> Bool {
            wasDown && !isDown && dragFraction != nil
        }
    }
#endif
