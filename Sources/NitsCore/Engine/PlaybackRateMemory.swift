/// Tells the speed a media plays at: the one chosen for it, which is saved with it, or for a media without one, 1× or
/// the previous media's (`PlayerConfiguration.carriesPlaybackRate`), which isn't.
struct PlaybackRateMemory {
    /// Whether the speed was chosen for the current media, or restored from its history; only a chosen speed is saved.
    private(set) var isChosen = false

    /// The user chose the speed, the one already in effect included: it is the media's from now on.
    mutating func choose() {
        isChosen = true
    }

    /// Forgets the media: returns the speed the next one starts at until its history is read.
    mutating func reset(current: Double, carries: Bool) -> Double {
        isChosen = false
        return carries ? current : 1.0
    }

    /// Returns the speed of the loaded media: the one saved for it, unless one was chosen while it loaded.
    mutating func restore(saved: Double?, current: Double) -> Double {
        guard !isChosen, let saved, saved.isFinite else { return current }
        isChosen = true
        return saved
    }

    /// The speed to save with the media: `nil`, which keeps the saved one, unless it was chosen.
    func preference(for rate: Double) -> Double? {
        isChosen ? rate : nil
    }
}
