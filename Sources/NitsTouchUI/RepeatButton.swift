#if os(iOS)
    import NitsCore
    import SwiftUI

    /// Symbol and spoken label of a repeat mode.
    enum RepeatIcon {
        static func symbol(for mode: PlaylistRepeatMode) -> String {
            mode == .one ? "repeat.1" : "repeat"
        }

        static func label(for mode: PlaylistRepeatMode) -> String {
            switch mode {
            case .off: "Repeat off"
            case .all: "Repeat all"
            case .one: "Repeat current"
            }
        }
    }

    /// Cycles off, all, one; dimmed while off.
    struct RepeatButton: View {
        let engine: PlayerEngine
        var onInteraction: () -> Void = {}

        var body: some View {
            let mode = engine.playlist.repeatMode
            Button {
                engine.playlist.cycleRepeatMode()
                onInteraction()
            } label: {
                Image(systemName: RepeatIcon.symbol(for: mode)).font(.title3)
                    .opacity(mode == .off ? 0.55 : 1)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(RepeatIcon.label(for: mode))
        }
    }
#endif
