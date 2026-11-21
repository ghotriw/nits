#if os(iOS)
    import MediaPlayer
    import NitsCore
    import UIKit

    /// What the system's Now Playing knows of the player: the lock screen and Control Center card, and the remote
    /// commands that reach the app from AirPods, the lock screen and the car (play, pause, the stem press, skips, Next
    /// and Previous, the scrubber).
    ///
    /// A `PlayerSessionSink` of `TouchPlayerSession`, the counterpart of `NitsKit`'s `NowPlayingController` on macOS. It
    /// tells the system the position and the rate and lets it count the time itself, so it writes on a change of state,
    /// a seek or a heartbeat (`NowPlayingThrottler`), not on every tick of the engine's clock.
    ///
    /// The commands are enabled only while media is loaded: with none, the system sends them to the app that played
    /// last, and a press of the stem would not reach Nits when it is the one playing.
    @MainActor
    final class TouchNowPlaying: PlayerSessionSink {
        private let engine: PlayerEngine
        private let center: MPNowPlayingInfoCenter
        private let commands: MPRemoteCommandCenter
        private var targets: [(command: MPRemoteCommand, target: Any)] = []
        private var throttler = NowPlayingThrottler()
        private let artwork = NowPlayingArtwork()
        private var isActive = false

        init(
            engine: PlayerEngine, center: MPNowPlayingInfoCenter = .default(),
            commands: MPRemoteCommandCenter = .shared()
        ) {
            self.engine = engine
            self.center = center
            self.commands = commands
            setUpCommands()
            // A load finishes after the update that started it.
            artwork.onLoaded = { [weak self] in
                guard let self, self.isActive else { return }
                self.publish(
                    title: self.throttler.lastReportedTitle, currentTime: self.engine.currentTime,
                    isPlaying: self.engine.isPlaying)
            }
        }

        isolated deinit {
            for item in targets { item.command.removeTarget(item.target) }
        }

        // MARK: - PlayerSessionSink

        func timeUpdated(current: Double, duration: Double) {
            update(currentTime: current, isPlaying: engine.isPlaying)
        }

        func stateChanged(_ state: PlaybackState) {
            switch state {
            case .playing:
                update(currentTime: engine.currentTime, isPlaying: true)
            case .paused:
                update(currentTime: engine.currentTime, isPlaying: false)
            case .idle, .failed, .completed:
                clear()
            case .loading:
                break
            }
        }

        func trackNavigationChanged() {
            updateTrackCommands()
        }

        func sessionClosing() {
            clear()
        }

        // MARK: - Now Playing info

        private func update(currentTime: Double, isPlaying: Bool) {
            let title = engine.mediaTitle
            guard !title.isEmpty else {
                clear()
                return
            }
            let artworkChanged = artwork.resolve(data: engine.artworkData, url: engine.artworkURL)
            updateTrackCommands()
            guard
                (artworkChanged && isActive)
                    || throttler.shouldUpdate(
                        title: title, currentTime: currentTime, duration: engine.media.duration,
                        isPlaying: isPlaying, playbackRate: engine.playbackRate)
            else { return }
            publish(title: title, currentTime: currentTime, isPlaying: isPlaying)
        }

        private func publish(title: String, currentTime: Double, isPlaying: Bool) {
            if !isActive {
                isActive = true
                setCommandsEnabled(true)
            }
            let rate = engine.playbackRate
            throttler.forceRecord(title: title, currentTime: currentTime, isPlaying: isPlaying, playbackRate: rate)

            var info = [String: Any]()
            info[MPMediaItemPropertyTitle] = title
            let duration = engine.media.duration
            // A live stream has a window, not a duration: no scrubber to show.
            if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
            if let data = artwork.data, let image = UIImage(data: data) {
                info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
            }
            center.nowPlayingInfo = info
            center.playbackState = isPlaying ? .playing : .paused
        }

        /// Made outside the main actor on purpose: MediaPlayer calls the handler on its own queue, and a closure
        /// written in a `@MainActor` method inherits the isolation and traps there (`dispatch_assert_queue`).
        private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
            MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
        }

        private func clear() {
            // The centers are shared by every session: one that never published has nothing of its own to take down.
            guard isActive else { return }
            isActive = false
            setCommandsEnabled(false)
            artwork.clear()
            throttler.reset()
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        // MARK: - Remote commands

        private func setUpCommands() {
            add(commands.togglePlayPauseCommand) { engine, _ in engine.togglePlayPause() }
            add(commands.playCommand) { engine, _ in engine.play() }
            add(commands.pauseCommand) { engine, _ in engine.pause() }
            commands.skipForwardCommand.preferredIntervals = [10]
            commands.skipBackwardCommand.preferredIntervals = [10]
            add(commands.skipForwardCommand) { engine, event in
                engine.seekRelative(by: Self.interval(of: event))
            }
            add(commands.skipBackwardCommand) { engine, event in
                engine.seekRelative(by: -Self.interval(of: event))
            }
            add(commands.nextTrackCommand) { engine, _ in engine.playNext() }
            add(commands.previousTrackCommand) { engine, _ in engine.playPrevious() }
            let position = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, let event = event as? MPChangePlaybackPositionCommandEvent
                    else { return .noActionableNowPlayingItem }
                    self.engine.seek(to: event.positionTime)
                    // At once, so the scrubber does not jump back until the next tick.
                    self.publish(
                        title: self.throttler.lastReportedTitle, currentTime: event.positionTime,
                        isPlaying: self.engine.isPlaying)
                    return .success
                }
            }
            targets.append((commands.changePlaybackPositionCommand, position))
        }

        private func add(
            _ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerEngine, MPRemoteCommandEvent) -> Void
        ) {
            let target = command.addTarget { [weak self] event in
                // Remote commands arrive on the main thread (the handlers' contract).
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return .noActionableNowPlayingItem }
                    action(self.engine, event)
                    return .success
                }
            }
            targets.append((command, target))
        }

        private static func interval(of event: MPRemoteCommandEvent) -> Double {
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return interval > 0 ? interval : 10
        }

        private func setCommandsEnabled(_ enabled: Bool) {
            commands.togglePlayPauseCommand.isEnabled = enabled
            commands.playCommand.isEnabled = enabled
            commands.pauseCommand.isEnabled = enabled
            commands.changePlaybackPositionCommand.isEnabled = enabled
            commands.skipForwardCommand.isEnabled = enabled
            commands.skipBackwardCommand.isEnabled = enabled
            updateTrackCommands()
        }

        /// Writes only on change: `update` calls it at the time update rate.
        private func updateTrackCommands() {
            let next = isActive && engine.canPlayNext
            if commands.nextTrackCommand.isEnabled != next { commands.nextTrackCommand.isEnabled = next }
            let previous = isActive && engine.canPlayPrevious
            if commands.previousTrackCommand.isEnabled != previous {
                commands.previousTrackCommand.isEnabled = previous
            }
        }
    }
#endif
