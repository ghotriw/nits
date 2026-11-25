#if os(iOS)
    import SwiftUI

    /// Locks the screen's controls and gestures, or unlocks them.
    struct LockButton: View {
        @Binding var isLocked: Bool
        var onInteraction: () -> Void = {}

        var body: some View {
            Button {
                isLocked.toggle()
                onInteraction()
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel(isLocked ? "Unlock controls" : "Lock controls")
        }
    }
#endif
