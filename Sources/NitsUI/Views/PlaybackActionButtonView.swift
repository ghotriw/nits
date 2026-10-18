import NitsCore
import SwiftUI

/// The host's action button ("Skip Intro", "Next Episode") with a dismiss button beside it, in the bottom-trailing
/// corner above the control bar. Feeds the playback position to `presenter` and reports presses to the engine.
public struct PlaybackActionButtonView: View {
    let engine: PlayerEngine
    let presenter: ActionButtonPresenter
    /// Whether the control bar is on screen: the button sits above it and, after its own time, shows only with it.
    var areControlsVisible: Bool
    /// Width taken by an open side panel; the button stays beside it.
    var trailingInset: CGFloat = 0
    /// Whether the pointer is over the buttons: the host keeps the controls (and the cursor) up meanwhile, so the
    /// button doesn't slide away from under it.
    @Binding var isHovered: Bool

    public init(
        engine: PlayerEngine,
        presenter: ActionButtonPresenter,
        areControlsVisible: Bool,
        trailingInset: CGFloat = 0,
        isHovered: Binding<Bool> = .constant(false)
    ) {
        self.engine = engine
        self.presenter = presenter
        self.areControlsVisible = areControlsVisible
        self.trailingInset = trailingInset
        self._isHovered = isHovered
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .allowsHitTesting(false)
            if presenter.isVisible, let button = presenter.button {
                HStack(spacing: 8) {
                    dismissButton
                    actionButton(button)
                }
                .onHover { isHovered = $0 }
                .padding(.trailing, 28 + trailingInset)
                // Clear of the control bar while it is up.
                .padding(.bottom, areControlsVisible ? 72 : 32)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: presenter.isVisible)
        .animation(.easeInOut(duration: 0.2), value: areControlsVisible)
        .onChange(of: areControlsVisible, initial: true) { _, visible in
            presenter.areControlsVisible = visible
        }
        .onChange(of: presenter.isVisible) { _, visible in
            // A button that goes away under the pointer reports no hover end.
            if !visible { isHovered = false }
        }
        .onChange(of: engine.currentTime) { _, time in
            update(at: time)
        }
        .onChange(of: engine.activeActionButton, initial: true) { _, _ in
            update(at: engine.currentTime)
        }
        .onChange(of: engine.loadGeneration) { _, _ in
            // New media: a span with the same id at the same position is still a new span.
            presenter.reset()
            update(at: engine.currentTime)
        }
    }

    private func actionButton(_ button: PlaybackActionButton) -> some View {
        Button {
            if let pressed = presenter.press() {
                engine.performActionButton(pressed)
            }
        } label: {
            Group {
                if button.isCard {
                    cardLabel(button)
                } else {
                    Text(button.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
            }
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 0)
        .help("\(button.title) (Return)")
    }

    /// "Up Next" card: the host's artwork beside the title and subtitle.
    private func cardLabel(_ button: PlaybackActionButton) -> some View {
        HStack(spacing: 12) {
            if let artworkURL = button.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        // Loading or failed: keep the card's size, so it doesn't jump when the picture arrives.
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(button.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                if let subtitle = button.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(button.artworkURL == nil ? 12 : 8)
        .padding(.trailing, 8)
    }

    private var dismissButton: some View {
        Button {
            presenter.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 0)
        .help("Dismiss (Esc)")
        .accessibilityLabel("Dismiss")
    }

    private func update(at time: Double) {
        let isPlaying = engine.isPlaying && !engine.isSeeking && engine.pendingSeekTime == nil
        if let button = presenter.update(active: engine.activeActionButton, at: time, isPlaying: isPlaying) {
            engine.performActionButton(button)
        }
    }
}
