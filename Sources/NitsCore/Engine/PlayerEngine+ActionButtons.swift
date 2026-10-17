import Foundation

extension PlayerEngine {
    /// Reports a press of `button` to the host (`onActionButton`); what the press does is up to the host.
    public func performActionButton(_ button: PlaybackActionButton) {
        guard actionButtons.contains(where: { $0.id == button.id }) else { return }
        AppLog.info(.engine, "Action button '\(button.id)' pressed at \(currentTime)s")
        onActionButton?(button.id)
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
