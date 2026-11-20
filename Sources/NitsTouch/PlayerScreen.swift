#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The player: the video full screen, the controls over it, a spinner while it loads or buffers, an alert for an
    /// error, and the way to open something when nothing is loaded.
    public struct PlayerScreen: View {
        let session: TouchPlayerSession
        @Environment(\.scenePhase) private var scenePhase
        @State private var visibility = ControlsVisibility()
        @State private var surfaceWidth: CGFloat = 0

        public init(session: TouchPlayerSession) {
            self.session = session
        }

        private var engine: PlayerEngine { session.engine }

        private var hasMedia: Bool { engine.isLoaded || engine.isLoading }

        private var context: ControlsVisibility.Context {
            ControlsVisibility.Context(
                isLoaded: engine.isLoaded, isPlaying: engine.isPlaying, isScrubbing: engine.isScrubbing,
                isBuffering: engine.isBuffering || engine.isLoading, hasError: engine.loadError != nil,
                isVoiceOverRunning: UIAccessibility.isVoiceOverRunning)
        }

        public var body: some View {
            // Re-evaluated every quarter second, as the controls hide by time.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let isVisible = visibility.isVisible(context)
                ZStack {
                    Color.black.ignoresSafeArea()
                    if hasMedia {
                        VideoSurface(engine: engine)
                            .ignoresSafeArea()
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.width
                            } action: {
                                surfaceWidth = $0
                            }
                            .contentShape(Rectangle())
                            .gesture(doubleTap.exclusively(before: singleTap))
                            .gesture(pinch)
                        if engine.isBuffering || engine.isLoading {
                            ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.6)
                                .allowsHitTesting(false)
                        }
                        ControlBar(session: session)
                            .opacity(isVisible ? 1 : 0)
                            .allowsHitTesting(isVisible)
                            .animation(.easeInOut(duration: 0.2), value: isVisible)
                            .simultaneousGesture(TapGesture().onEnded { visibility.touch() })
                            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in visibility.touch() })
                    } else {
                        EmptyStateView(session: session).foregroundStyle(.white)
                    }
                }
                .statusBarHidden(hasMedia && !isVisible)
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
            }
            .onChange(of: scenePhase) { _, phase in session.scenePhaseChanged(phase) }
            .onChange(of: engine.isLoaded) { _, _ in visibility.touch() }
            .onChange(of: engine.isPlaying) { _, _ in visibility.touch() }
            .alert(
                "Can't Play",
                isPresented: Binding(get: { engine.loadError != nil }, set: { if !$0 { engine.loadError = nil } })
            ) {
                Button("Close") { session.close() }
            } message: {
                Text(engine.loadError ?? "")
            }
        }

        private var singleTap: some Gesture {
            TapGesture().onEnded { visibility.toggle(context) }
        }

        /// Twice on the left third skips back, on the right third forward; the middle does nothing.
        private var doubleTap: some Gesture {
            SpatialTapGesture(count: 2).onEnded { value in
                visibility.touch()
                let width = surfaceWidth
                if value.location.x < width / 3 {
                    engine.seekRelative(by: -10)
                } else if value.location.x > width * 2 / 3 {
                    engine.seekRelative(by: 10)
                }
            }
        }

        /// Spreading fingers fills the screen (the picture's edges cut), pinching in fits the picture inside it.
        private var pinch: some Gesture {
            MagnifyGesture().onEnded { value in
                if value.magnification > 1 {
                    engine.setVideoScaling(.fill)
                } else if value.magnification < 1 {
                    engine.setVideoScaling(.fit)
                }
            }
        }
    }

    #Preview("Nothing loaded") {
        PlayerScreen(session: TouchPlayerSession())
    }
#endif
