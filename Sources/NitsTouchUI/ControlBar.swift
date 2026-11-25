#if os(iOS)
    import NitsCore
    import NitsTouchKit
    import SwiftUI

    /// The controls over the picture: a status row and the buttons (close, fit / fill, repeat, speed) at the top; at the
    /// bottom the audio menu, the timeline and a row with the lock and previous / play or pause / next.
    struct ControlBar: View {
        let session: TouchPlayerSession
        let network: NetworkKindMonitor?
        @Binding var isLocked: Bool
        @Binding var isChaptersOpen: Bool
        /// The controls were used in a way their own gestures do not see (a menu): keeps them on screen.
        var onTouch: () -> Void = {}
        @State private var dragFraction: Double?

        /// The height of the lock / transport row: the locked screen keeps the lock where it was by using the same one.
        static let transportHeight: CGFloat = 52

        private var engine: PlayerEngine { session.engine }

        var body: some View {
            VStack(spacing: 0) {
                top
                Spacer()
                bottom
            }
            .padding(.horizontal, 8)
            .foregroundStyle(.white)
            .background(alignment: .top) { scrim(.top) }
            .background(alignment: .bottom) { scrim(.bottom) }
        }

        private func scrim(_ edge: VerticalEdge) -> some View {
            LinearGradient(
                colors: [.black.opacity(0.6), .clear], startPoint: edge == .top ? .top : .bottom,
                endPoint: edge == .top ? .bottom : .top
            )
            .frame(height: 160)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        private var top: some View {
            VStack(spacing: 4) {
                StatusRow(title: engine.mediaTitle, network: network).padding(.horizontal, 4)
                HStack(spacing: 4) {
                    Button {
                        session.close()
                    } label: {
                        Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                    ScalingButton(engine: engine, onInteraction: onTouch)
                    RepeatButton(engine: engine, onInteraction: onTouch)
                    Spacer()
                    SpeedMenu(engine: engine, onInteraction: onTouch).equatable()
                }
            }
        }

        private var timeline: ScrubTimeline {
            let window = engine.live.isLive ? engine.live.window() : nil
            return ScrubTimeline(duration: engine.media.duration, liveWindow: window.map { ($0.start, $0.end) })
        }

        private var bottom: some View {
            let timeline = timeline
            let shown = dragFraction.map { timeline.time(at: $0) } ?? engine.currentTime
            return VStack(spacing: 0) {
                if AudioTrackLabel.isShown(trackCount: engine.audioTracks.count)
                    || ChapterPanelLogic.isButtonShown(chapterCount: engine.media.chapters.count)
                {
                    HStack {
                        Spacer()
                        ChaptersButton(engine: engine, isOpen: $isChaptersOpen, onInteraction: onTouch)
                        AudioTrackMenu(engine: engine, onInteraction: onTouch).equatable()
                    }
                }
                HStack(spacing: 10) {
                    Text(ScrubTimeline.clock(shown - timeline.start))
                        .font(.footnote.monospacedDigit())
                        .frame(minWidth: 44, alignment: .trailing)
                    ScrubBar(engine: engine, timeline: timeline, dragFraction: $dragFraction)
                    if engine.live.isLive {
                        LiveBadgeButton(engine: engine)
                    } else {
                        Text("-" + ScrubTimeline.clock(timeline.end - shown))
                            .font(.footnote.monospacedDigit())
                            .frame(minWidth: 44, alignment: .leading)
                    }
                }
                transport
            }
        }

        /// Lock at the left; previous, play / pause and next in the middle (the same width on both sides, so play
        /// stays centred when a track button is missing). Fits an iPhone SE's 304 pt: 3 × 44 + 56 and gaps.
        private var transport: some View {
            ZStack {
                HStack {
                    LockButton(isLocked: $isLocked, onInteraction: onTouch)
                    Spacer()
                }
                HStack(spacing: 24) {
                    trackButton("backward.end.fill", label: "Previous", isEnabled: engine.canPlayPrevious) {
                        engine.playPrevious()
                    }
                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30))
                            .frame(width: 56, height: Self.transportHeight)
                    }
                    .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                    trackButton("forward.end.fill", label: "Next", isEnabled: engine.canPlayNext) {
                        engine.playNext()
                    }
                }
            }
            .frame(height: Self.transportHeight)
        }

        /// A track button keeps its place (hidden, not removed) when there is no track to go to.
        private func trackButton(
            _ symbol: String, label: LocalizedStringKey, isEnabled: Bool, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: symbol).font(.title2).frame(width: 44, height: 44)
            }
            .opacity(isEnabled ? 1 : 0)
            .disabled(!isEnabled)
            .accessibilityHidden(!isEnabled)
            .accessibilityLabel(label)
        }
    }

    /// "LIVE" beside the timeline of a live stream: red at the live edge, grey behind it, where a tap goes back to the
    /// edge. The edge moves with real time while the picture may stand (paused), so it is read every second.
    struct LiveBadgeButton: View {
        let engine: PlayerEngine

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let isAtEdge = engine.live.isAtEdge(engine.currentTime)
                Button {
                    engine.seekToLiveEdge()
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(isAtEdge ? Color.red : Color.white.opacity(0.5)).frame(width: 8, height: 8)
                        Text("LIVE").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(isAtEdge ? 0.95 : 0.65))
                    }
                    .frame(minWidth: 52, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .disabled(isAtEdge)
                .accessibilityLabel(isAtEdge ? "Live" : "Go to live")
            }
        }
    }
#endif
