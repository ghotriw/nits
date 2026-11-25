#if os(iOS)
    import NitsCore
    import NitsTouchKit
    import SwiftUI

    /// The player: the video full screen, the controls over it, a spinner while it loads or buffers, an alert for an
    /// error, and the way to open something when nothing is loaded.
    public struct PlayerScreen: View {
        let session: TouchPlayerSession
        @Environment(\.scenePhase) private var scenePhase
        @State private var visibility = ControlsVisibility()
        @State private var surfaceWidth: CGFloat = 0
        @State private var isLocked = false
        @State private var isChaptersOpen = false
        /// Made on appear, one for both layouts of the status row.
        @State private var network: NetworkKindMonitor?

        public init(session: TouchPlayerSession) {
            self.session = session
        }

        private var engine: PlayerEngine { session.engine }

        private var hasMedia: Bool { engine.isLoaded || engine.isLoading }

        private var context: ControlsVisibility.Context {
            ControlsVisibility.Context(
                isLoaded: engine.isLoaded, isPlaying: engine.isPlaying, isScrubbing: engine.isScrubbing,
                isBuffering: engine.isBuffering || engine.isLoading, hasError: engine.loadError != nil,
                isVoiceOverRunning: UIAccessibility.isVoiceOverRunning, isPanelOpen: isChaptersOpen)
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
                        Group {
                            if isLocked {
                                // Locked: only the way out; the picture's gestures do nothing but show or hide it.
                                VStack {
                                    StatusRow(title: engine.mediaTitle, network: network).padding(.horizontal, 12)
                                    Spacer()
                                    HStack {
                                        LockButton(isLocked: $isLocked) { visibility.touch() }
                                        Spacer()
                                    }
                                    .frame(height: ControlBar.transportHeight)
                                    .padding(.horizontal, 8)
                                }
                                .foregroundStyle(.white)
                            } else {
                                ControlBar(
                                    session: session, network: network, isLocked: $isLocked,
                                    isChaptersOpen: $isChaptersOpen, onTouch: { visibility.touch() })
                            }
                        }
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                        .animation(.easeInOut(duration: 0.2), value: isVisible)
                        .simultaneousGesture(TapGesture().onEnded { visibility.touch() })
                        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in visibility.touch() })
                        ActionButtonView(session: session, areControlsVisible: isVisible, isLocked: isLocked) {
                            visibility.touch()
                        }
                        chaptersOverlay
                    } else {
                        EmptyStateView(session: session).foregroundStyle(.white)
                    }
                }
                .statusBarHidden(hasMedia)
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
            }
            .onAppear { if network == nil { network = NetworkKindMonitor() } }
            .onChange(of: scenePhase) { _, phase in session.scenePhaseChanged(HostScenePhase(phase)) }
            .onChange(of: engine.isLoaded) { _, _ in visibility.touch() }
            // Between two items `isLoaded` goes false but the media (`isLoading`) stays: the lock holds until it is closed.
            .onChange(of: hasMedia) { _, hasMedia in
                visibility.touch()
                if !hasMedia {
                    isLocked = false
                    isChaptersOpen = false
                }
            }
            // The list belongs to the media: another item (or none to choose from) closes it.
            .onChange(of: engine.media.chapters) { _, _ in isChaptersOpen = false }
            .onChange(of: isLocked) { _, isLocked in
                if isLocked { isChaptersOpen = false }
            }
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

        /// The chapters over everything: a tap outside closes it; the bottom sheet is swiped down by its handle.
        private var chaptersOverlay: some View {
            GeometryReader { geometry in
                let placement = ChapterPanelLogic.placement(for: geometry.size)
                let edge: Edge = placement == .bottom ? .bottom : .trailing
                ZStack(alignment: placement == .bottom ? .bottom : .trailing) {
                    if isChaptersOpen {
                        Color.black.opacity(0.35).contentShape(Rectangle())
                            .onTapGesture { isChaptersOpen = false }
                            .transition(.opacity)
                        ChapterPanel(
                            engine: engine, onInteraction: { visibility.touch() },
                            topInset: placement == .bottom ? Self.handleHeight : 0
                        )
                        .frame(
                            width: placement == .bottom ? nil : min(geometry.size.width * 0.4, 420),
                            height: placement == .bottom ? geometry.size.height * 0.55 : nil
                        )
                        // A drag on the list scrolls it, so the sheet is swiped down by its handle alone.
                        .overlay(alignment: .top) {
                            if placement == .bottom {
                                Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 5)
                                    .frame(maxWidth: .infinity, minHeight: Self.handleHeight)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 10).onEnded { value in
                                            if value.translation.height > 40 { isChaptersOpen = false }
                                        }
                                    )
                            }
                        }
                        .padding(8)
                        .transition(.move(edge: edge))
                        // A modal panel for VoiceOver: what is under it is not reached, and the escape gesture closes it.
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { isChaptersOpen = false }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeInOut(duration: 0.25), value: isChaptersOpen)
            // Closing it counts as a touch: the controls it held do not vanish with the panel.
            .onChange(of: isChaptersOpen) { _, _ in visibility.touch() }
        }

        /// The sheet's handle: the strip the swipe starts on, above the list.
        private static let handleHeight: CGFloat = 28

        private var singleTap: some Gesture {
            TapGesture().onEnded { visibility.toggle(context) }
        }

        /// Twice on the left third skips back, on the right third forward; the middle does nothing.
        private var doubleTap: some Gesture {
            SpatialTapGesture(count: 2).onEnded { value in
                guard !isLocked else { return }
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
                guard !isLocked else { return }
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

    extension HostScenePhase {
        init(_ phase: ScenePhase) {
            switch phase {
            case .active: self = .active
            case .inactive: self = .inactive
            case .background: self = .background
            @unknown default: self = .inactive
            }
        }
    }
#endif
