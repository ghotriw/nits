import NitsCore
import SwiftUI

/// "LIVE" beside the timeline of a live stream: red at the live edge, grey when the picture is behind it, where a click
/// goes back to the edge.
struct LiveBadge: View {
    let engine: PlayerEngine

    var body: some View {
        // The edge moves with real time while the picture may stand (paused): read every second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let isAtEdge = engine.live.isAtEdge(engine.currentTime)
            Button {
                engine.seekToLiveEdge()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isAtEdge ? Color.red : Color.white.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(isAtEdge ? 0.95 : 0.65))
                }
                .padding(.all, 7)
                .frame(minWidth: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAtEdge)
            .help(isAtEdge ? "Watching live" : "Go to Live")
            .accessibilityLabel(isAtEdge ? "Live" : "Go to live")
        }
    }
}
