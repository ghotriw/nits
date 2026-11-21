#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The controls over the picture: close and title at the top, skip back / play or pause / skip forward in the
    /// middle, a row of selectors (the speed) over the timeline at the bottom.
    struct ControlBar: View {
        let session: TouchPlayerSession
        /// The controls were used in a way their own gestures do not see (a menu): keeps them on screen.
        var onTouch: () -> Void = {}
        @State private var dragFraction: Double?

        private var engine: PlayerEngine { session.engine }
        private static let skipSeconds = 10.0

        var body: some View {
            ZStack {
                VStack {
                    top
                    Spacer()
                }
                center
                VStack {
                    Spacer()
                    bottom
                }
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
            .frame(height: 140)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        private var top: some View {
            HStack(spacing: 12) {
                Button {
                    session.close()
                } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Text(engine.mediaTitle).font(.headline).lineLimit(1)
                Spacer()
            }
        }

        private var center: some View {
            // Narrower with the track buttons: 44 + 56 + 72 + 56 + 44 pt and four gaps is 296 pt, inside an iPhone SE's 304 pt (320 less the 8 pt margins) in portrait.
            HStack(spacing: engine.canPlayPrevious || engine.canPlayNext ? 6 : 36) {
                if engine.canPlayPrevious {
                    Button {
                        engine.playPrevious()
                    } label: {
                        Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Previous")
                }
                Button {
                    engine.seekRelative(by: -Self.skipSeconds)
                } label: {
                    Image(systemName: "gobackward.10").font(.title).frame(width: 56, height: 56)
                }
                .accessibilityLabel("Back 10 seconds")
                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40))
                        .frame(width: 72, height: 72)
                }
                .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                Button {
                    engine.seekRelative(by: Self.skipSeconds)
                } label: {
                    Image(systemName: "goforward.10").font(.title).frame(width: 56, height: 56)
                }
                .accessibilityLabel("Forward 10 seconds")
                if engine.canPlayNext {
                    Button {
                        engine.playNext()
                    } label: {
                        Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Next")
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
            return VStack(spacing: 4) {
                selectors
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
            }
        }

        /// A row of selector buttons over the timeline: speed now; audio, subtitles and the rest go here later.
        private var selectors: some View {
            HStack(spacing: 8) {
                SpeedMenu(engine: engine, onInteraction: onTouch)
                Spacer()
            }
            .padding(.leading, 4)
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
