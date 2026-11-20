#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The host's action button ("Skip Intro", "Next Episode") with a dismiss button beside it, bottom trailing above the
    /// timeline. Feeds the playback position to the session's `ActionButtonPresenter` and reports presses to the engine.
    /// A button with a subtitle or artwork (an "Up Next" card on macOS) shows as the plain button.
    struct ActionButtonView: View {
        let session: TouchPlayerSession
        /// Whether the controls are on screen: the button sits above them and, after its own time, shows only with them.
        let areControlsVisible: Bool
        /// A tap on the button counts as a touch for the controls' hiding.
        let onTouch: () -> Void

        private var engine: PlayerEngine { session.engine }
        private var presenter: ActionButtonPresenter { session.actionButton }

        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                Color.clear.allowsHitTesting(false)
                if presenter.isVisible, let button = presenter.button {
                    HStack(spacing: 8) {
                        dismissButton
                        actionButton(button)
                    }
                    .padding(.trailing, 16)
                    // Clear of the timeline while the controls are up.
                    .padding(.bottom, areControlsVisible ? 72 : 24)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: presenter.isVisible)
            .animation(.easeInOut(duration: 0.2), value: areControlsVisible)
            .onChange(of: areControlsVisible, initial: true) { _, visible in
                presenter.areControlsVisible = visible
            }
            .onChange(of: engine.currentTime) { _, time in
                update(at: time)
            }
            .onChange(of: engine.actionButtons.active, initial: true) { _, _ in
                update(at: engine.currentTime)
            }
            .onChange(of: engine.actionButtons.loadGeneration) { _, _ in
                // New media: a span with the same id at the same position is still a new span.
                presenter.reset()
                update(at: engine.currentTime)
            }
        }

        private func actionButton(_ button: PlaybackActionButton) -> some View {
            Button {
                onTouch()
                if let pressed = presenter.press() {
                    engine.actionButtons.perform(pressed)
                }
            } label: {
                Text(button.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(alignment: .leading) {
                        // Auto-press countdown: fills from the leading edge until the button presses itself.
                        if let progress = presenter.autoPressProgress {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(Color.white.opacity(0.22))
                                    .frame(width: geo.size.width * progress)
                                    .animation(.linear(duration: 0.1), value: progress)
                            }
                        }
                    }
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(button.title)
        }

        private var dismissButton: some View {
            Button {
                onTouch()
                presenter.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }

        private func update(at time: Double) {
            let isPlaying = engine.isPlaying && !engine.isSeeking && engine.pendingSeekTime == nil
            if let button = presenter.update(active: engine.actionButtons.active, at: time, isPlaying: isPlaying) {
                engine.actionButtons.perform(button)
            }
        }
    }
#endif
