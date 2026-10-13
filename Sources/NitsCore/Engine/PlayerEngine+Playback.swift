@preconcurrency import AVFoundation
import AppKit
@preconcurrency import CoreMedia
import Foundation

extension PlayerEngine {
    public func play() {
        resetRelativeSeekBurst()
        guard isLoaded else { return }

        // If video reached the end or is in completed state, restart from the beginning
        if playbackState == .completed || (duration > 0 && currentTime >= (duration - 0.25)) {
            seek(to: 0.0)
        }

        // If a chase seek is currently in flight or queued, record intent to play once seeking finishes
        if isSeeking || chaseTargetTime != nil {
            resumePlaybackAfterChase = true
            return
        }

        let feedingActive = isFeeding.withLock { $0 }
        if !feedingActive {
            startFeeding()
        }
        startSynchronizerClock(at: synchronizer.currentTime(), rate: playbackRate, armGuard: false)
        displayLink?.isPaused = !hasVideo
        isPlaying = true
        playbackState = .playing
        performanceMonitor.handlePlaybackStateChange(isPlaying: true)
    }

    public func pause() {
        resetRelativeSeekBurst()
        if isSeeking || chaseTargetTime != nil {
            resumePlaybackAfterChase = false
        }
        stopPlaybackPipeline()
        playbackState = .paused
        saveCurrentPlaybackProgress()
    }

    /// Halts clock synchronization and feeders without altering user-facing isPlaying or playbackState.
    func haltPlaybackPipeline() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        displayLink?.isPaused = true
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        seekTask?.cancel()
        seekTask = nil
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        clockSettlingGuardLock.withLock { $0 = nil }
    }

    /// Stops audio/video feeding and halts the clock, marking playback as paused.
    func stopPlaybackPipeline() {
        haltPlaybackPipeline()
        isPlaying = false
        performanceMonitor.handlePlaybackStateChange(isPlaying: false)
    }

    /// Safely starts or re-anchors the synchronizer master clock.
    ///
    /// - Parameters:
    ///   - targetTime: Target timeline position for CoreAudio synchronizer.
    ///   - rate: Target playback rate.
    ///   - armGuard: If `true`, arms `ClockSettlingGuard` to hold video frames while hardware clock settles to new target.
    func startSynchronizerClock(at targetTime: CMTime, rate: Double, armGuard: Bool = true) {
        if armGuard, targetTime.isNumeric {
            let targetSec = targetTime.seconds
            clockSettlingGuardLock.withLock {
                $0 = ClockSettlingGuard(
                    targetSeconds: targetSec,
                    setHostTime: CACurrentMediaTime(),
                    rate: rate
                )
            }
        }
        synchronizer.setRate(Float(rate), time: targetTime)
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func stepVolume(by delta: Float) {
        volume = max(0.0, min(1.0, volume + delta))
    }

    public func toggleMute() {
        isMuted.toggle()
    }

    public func setPlaybackRate(_ rate: Double) {
        let rounded = (rate * 100).rounded() / 100.0
        let clamped = max(0.5, min(rounded, 4.0))
        guard clamped != playbackRate else { return }
        playbackRate = clamped
        AppLog.info(.engine, "Playback rate changed to \(playbackRate)x")
    }

    public func stepPlaybackRate(by delta: Double) {
        let target = ((playbackRate + delta) * 10).rounded() / 10.0
        setPlaybackRate(target)
    }

    public func resetPlaybackRate() {
        setPlaybackRate(1.0)
    }

    public func toggleDebugHUD() {
        showDebugHUD.toggle()
    }

    /// Loads and begins playback of a playlist item.
    public func load(item: PlaylistItem) {
        let pathString = item.url.isFileURL ? item.url.standardizedFileURL.path : item.url.absoluteString
        self.load(
            path: pathString,
            title: item.title,
            artworkData: nil,
            artworkURL: nil,
            headers: item.customHeaders,
            startTime: item.startTime,
            audioTrack: nil,
            subtitleTrack: nil
        )
    }

    /// Advances to and loads the next item in the playlist.
    public func playNext() {
        if let item = playlist.playNext(isUserAction: true) {
            load(item: item)
        }
    }

    /// Returns to previous playlist item or restarts current track if played past 3 seconds.
    public func playPrevious() {
        let (item, shouldRestart) = playlist.playPrevious(
            restartThresholdSeconds: 3.0,
            currentPlaybackTime: currentTime
        )
        if shouldRestart {
            seek(to: 0)
            play()
        } else if let item {
            load(item: item)
        }
    }

    /// Selects and plays a specific item from the playlist by UUID.
    public func playPlaylistItem(id: UUID) {
        // If clicking on the currently active item, just ensure it plays without restarting
        if let currentItem = playlist.currentItem, currentItem.id == id, isLoaded {
            if !isPlaying {
                play()
            }
            return
        }

        if let item = playlist.selectItem(id: id) {
            load(item: item)
        }
    }

    /// Removes an item from the playlist. If the removed item was currently playing,
    /// stops playback or advances to the next remaining item.
    public func removePlaylistItem(id: UUID) {
        let isRemovingCurrent = (playlist.currentItem?.id == id)
        playlist.remove(id: id)

        if isRemovingCurrent {
            if let nextItem = playlist.currentItem {
                load(item: nextItem)
            } else {
                stop()
            }
        }
    }
}
