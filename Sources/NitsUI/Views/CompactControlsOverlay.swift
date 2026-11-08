import NitsCore
import SwiftUI

/// The controls of a player shown small (`PlayerUIState.isCompact`): play / pause in the middle of the picture and a
/// thin progress bar along its bottom edge, which a click or a drag seeks. No header strip, no time labels and no
/// thumbnail preview: in a mini player they would cover the picture they describe.
struct CompactControlsOverlay: View {
    let engine: PlayerEngine
    /// Whether the pointer is over the controls or the bar is being dragged: `ContentView` keeps them up meanwhile.
    @Binding var isInteracting: Bool

    @State private var isButtonHovered = false
    @State private var isBarHovered = false
    @State private var isDragging = false

    /// The play / pause button gives way to the loading spinner, which sits in the same place.
    private var showsPlayPause: Bool {
        engine.isLoaded && !engine.isLoading && !engine.isStartingPlayback && !engine.isBuffering
            && engine.loadError == nil
    }

    var body: some View {
        ZStack {
            // Keeps the bar readable over a bright picture.
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                .frame(height: 48)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            if showsPlayPause {
                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                .onHover { hovering in
                    isButtonHovered = hovering
                    updateInteraction()
                }
            }

            CompactProgressBar(engine: engine, isHovered: $isBarHovered, isDragging: $isDragging)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea()
        .onChange(of: isBarHovered) { _, _ in updateInteraction() }
        .onChange(of: isDragging) { _, _ in updateInteraction() }
    }

    private func updateInteraction() {
        isInteracting = isButtonHovered || isBarHovered || isDragging
    }
}

/// A thin progress bar without labels: of the duration, or of a live stream's window as the full timeline is. It grows
/// a little under the pointer; a click or a drag seeks where it ends.
private struct CompactProgressBar: View {
    let engine: PlayerEngine
    @Binding var isHovered: Bool
    @Binding var isDragging: Bool

    @State private var dragPosition: Double = 0

    private static let hitHeight: CGFloat = 16

    var body: some View {
        if engine.live.isLive && !engine.live.isEnded {
            // The window moves while the picture may stand (paused).
            TimelineView(.periodic(from: .now, by: 1)) { _ in bar }
        } else {
            bar
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let timeline = TimelineSpan(engine: engine)
            let progress = timeline.ratio(of: isDragging ? dragPosition : engine.currentTime)
            let height: CGFloat = isHovered || isDragging ? 6 : 4

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                if engine.media.isNetworkSource {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        let buffered = timeline.ratio(of: engine.bufferedTime)
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(width: geo.size.width * max(buffered, progress))
                    }
                }
                Capsule()
                    .fill(.tint)
                    .frame(width: geo.size.width * progress)
            }
            .frame(height: height)
            .animation(.easeInOut(duration: 0.12), value: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragPosition = timeline.time(atRatio: value.location.x / max(geo.size.width, 1))
                    }
                    .onEnded { value in
                        engine.seek(to: timeline.time(atRatio: value.location.x / max(geo.size.width, 1)))
                        isDragging = false
                    }
            )
            .disabled(!engine.isLoaded || timeline.length <= 0)
        }
        .frame(height: Self.hitHeight)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(TimelineSpan(engine: engine).positionText(engine.currentTime, engine: engine))
    }
}
