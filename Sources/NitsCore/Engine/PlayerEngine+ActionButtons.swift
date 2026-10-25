import Foundation

extension PlayerEngine {
    /// Performs `button`: if `button.seeksToEnd` and it has an `end`, seeks to `end`; otherwise reports the press to
    /// the host (`onActionButton`), letting the host decide what to do (e.g. Next Episode).
    public func performActionButton(_ button: PlaybackActionButton) {
        guard actionButtons.contains(where: { $0.id == button.id }) else { return }
        AppLog.info(.engine, "Action button '\(button.id)' pressed at \(currentTime)s")
        if button.seeksToEnd, let end = button.end {
            seek(to: end)
        } else {
            onActionButton?(button.id)
        }
    }

    func updateActiveActionButton() {
        // A handful of buttons at most: a linear scan per tick is cheap. Write only on change, so observers of
        // `activeActionButton` don't re-render at the time update rate.
        // Not while loading: the new media's buttons against the previous media's position.
        let active = isLoaded ? PlaybackActionButton.active(in: actionButtons, at: currentTime) : nil
        if active != activeActionButton {
            activeActionButton = active
        }
    }
}
