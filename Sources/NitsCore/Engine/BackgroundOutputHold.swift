import Foundation

/// Keeps the app awake while playback waits for media in the background: the route keeps its output running
/// (`AudioOutputRoute.keepOutputRunning`) for as long as buffering holds the clock there, up to `limit`.
///
/// Buffering stops the sound, and iOS suspends an app whose sound stopped about 5 s later; suspended, it cannot wait
/// for the network, nor read on once it is back. As in ExoPlayer (wake and Wi-Fi locks held while buffering with the
/// intent to play) and VLC (its output renders silence on an underrun), waiting for data is still playing. Past
/// `limit` (an outage that does not end) the output is let go and the system may suspend the app, until buffering ends
/// and begins again.
@MainActor
final class BackgroundOutputHold {
    /// How long one wait in the background may keep the app awake.
    static let limit: Duration = .seconds(300)

    private(set) var isHolding = false
    /// The current wait has used up `limit`: not held again until it ends.
    private var hasExpired = false
    private var limitTask: Task<Void, Never>?
    private let limitDuration: Duration

    init(limit: Duration = BackgroundOutputHold.limit) {
        limitDuration = limit
    }

    /// Holds the route's output while `waiting` (buffering in the background while playing), lets go when not.
    func update(waiting: Bool, route: any AudioOutputRoute) {
        guard waiting else {
            hasExpired = false
            release(route: route)
            return
        }
        guard !isHolding, !hasExpired else { return }
        isHolding = true
        route.keepOutputRunning(true)
        AppLog.info(.engine, "Buffering in the background: keeping the audio output running")
        let limit = limitDuration
        limitTask = Task { @MainActor [weak self, weak route] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.isHolding else { return }
            self.hasExpired = true
            if let route { self.release(route: route) }
            AppLog.warning(
                .engine, "Still buffering in the background after \(limit); letting the audio output go")
        }
    }

    private func release(route: any AudioOutputRoute) {
        limitTask?.cancel()
        limitTask = nil
        guard isHolding else { return }
        isHolding = false
        route.keepOutputRunning(false)
    }
}
