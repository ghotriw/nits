import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
public final class OSDManager {
    public private(set) var currentEvent: OSDEvent?
    public private(set) var isVisible: Bool = false

    private var hideTask: Task<Void, Never>?

    public init() {}

    /// Presents an OSD event and schedules auto-hiding after `duration` seconds.
    public func show(_ event: OSDEvent, duration: Double = 1.3) {
        hideTask?.cancel()

        currentEvent = event

        if !isVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                isVisible = true
            }
        }

        let validDuration = duration.isFinite ? max(0.2, duration) : 1.3
        let nanoseconds = UInt64(validDuration * 1_000_000_000)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isVisible = false
            }
        }
    }

    /// Hides the current OSD notification immediately.
    public func hide() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            isVisible = false
            currentEvent = nil
        }
    }
}
