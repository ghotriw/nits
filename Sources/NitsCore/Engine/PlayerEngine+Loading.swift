@preconcurrency import AVFoundation
import AppKit
@preconcurrency import CoreMedia
import Foundation

extension PlayerEngine {
    /// Resolves the user-facing media title from a file/stream path, falling back to
    /// URL host or file name if no explicit title is provided.
    nonisolated public static func resolveTitle(from path: String, explicitTitle: String? = nil) -> String {
        if let explicitTitle, !explicitTitle.isEmpty {
            return explicitTitle
        }
        if MediaURL.isNetworkURL(path), let url = URL(string: path) {
            let last = url.lastPathComponent
            if last.isEmpty || last == "/" {
                return url.host ?? path
            }
            return last.removingPercentEncoding ?? last
        }
        let localPath: String
        if path.lowercased().hasPrefix("file://") {
            localPath = URL(string: path)?.path ?? String(path.dropFirst("file://".count))
        } else {
            localPath = path
        }
        let decoded = localPath.removingPercentEncoding ?? localPath
        return URL(fileURLWithPath: decoded).lastPathComponent
    }

    /// Normalizes an input path: strips file:// scheme if present and decodes percent-encoded characters for local files.
    nonisolated public static func normalizeMediaPath(_ path: String) -> String {
        if MediaURL.isNetworkURL(path) {
            return path
        }
        let localPath: String
        if path.lowercased().hasPrefix("file://") {
            localPath = URL(string: path)?.path ?? String(path.dropFirst("file://".count))
        } else {
            localPath = path
        }
        return localPath.removingPercentEncoding ?? localPath
    }

    /// Resets all internal playback, demuxing, feeding and clock tracking state before loading new media.
    private func resetPlaybackTrackingState(
        for path: String, explicitTitle: String?, artworkData: Data?, artworkURL: URL?
    ) -> (loadID: UUID, interruptContext: MediaDemuxer.InterruptContext) {
        resetMediaState(reportingTracks: false)
        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: explicitTitle)
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        self.isLoading = true
        loadGeneration += 1

        let loadID = UUID()
        self.currentLoadID = loadID
        let interruptContext = MediaDemuxer.InterruptContext()
        self.currentInterruptContext = interruptContext
        playbackState = .loading

        return (loadID, interruptContext)
    }

    /// Forgets the media played until now: saves its progress, ends its seeks, steps and pipeline, closes its demuxer
    /// and clears its tracks, stream properties, picture and display timing. `stop()` and every load go through here,
    /// so nothing of one media outlives it on either path, a load that fails included: clear new per-media state here.
    /// - Parameter reportingTracks: Whether to report the cleared tracks now. A load doesn't: it reports them once,
    ///   with the new media's or when it fails.
    private func resetMediaState(reportingTracks: Bool) {
        // First: it saves the selected tracks and a seek's target, both cleared below.
        saveCurrentPlaybackProgress()
        resetRelativeSeekBurst()
        let seekId = currentSeekId + 1
        currentSeekId = seekId
        activeSeekId.withLock { $0 = seekId }
        isSeeking = false
        chaseTargetTime = nil
        resumePlaybackAfterChase = false
        minStepFramePTS = nil
        decoderStallRecoveries = 0
        stepDecodeContiguous = false
        isStepPumping = false
        didStepSincePause = false
        stepFrameCache.clear()

        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        demuxer?.cancel()
        demuxer = nil
        stopPlaybackPipeline()
        synchronizer.setRate(0.0, time: .zero)
        audioLagDetector = AudioLagDetector()
        clearVideoSurface()

        currentPath = nil
        currentHeaders = [:]
        isLoaded = false
        currentTime = 0
        media = MediaInfo()
        loadError = nil
        nominalFrameDuration = 1.0 / 24.0
        nominalFrameDurationLock.withLock { $0 = 1.0 / 24.0 }
        videoStartTimeLock.withLock { $0 = 0 }
        // Display timing of the previous media must not leak into the new one's cadence reports or phase lock.
        frameCadenceLock.withLock { $0 = FrameCadenceStats() }
        displayClockSmootherLock.withLock { $0 = DisplayClockSmoother() }
        tickDiagnosticsLock.withLock { $0 = TickDiagnostics() }
        currentMetrics = PlayerPerformanceMonitor.Metrics()
        dynamicToneMapLock.withLock {
            $0.basePeakNits = 1000.0
            $0.baseTargetNits = 203.0
            $0.smoothedPeakNits = 1000.0
            $0.smoothedTargetNits = 203.0
            $0.lastRenderModeName = "Metal SDR"
            $0.lastDoviMetadata = nil
        }
        performanceMonitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(mode: .none, peakNits: 0, targetNits: 203)
        )
        thumbnailManager.reset()
        audioDelay = 0
        audioSink.setDelay(.zero)
        // The file's aspect override and crop, zoom and pan; the scaling lasts the session.
        restoreVideoGeometry(from: nil)

        // A report already held back by a deferral this runs in is the outer one's to make, either way.
        let reportWasDeferred = hasDeferredTracksChange
        beginDeferringTracksChanged()
        audioTracks = []
        selectedAudioTrackId = -1
        audioSelectionIsAutomatic = false
        variants = []
        selectedVariantId = nil
        isVariantAutomatic = false
        canSelectAutomaticVariant = false
        pendingVariantChanges = []
        subtitles.reset()
        if !reportingTracks {
            if hasDeferredTracksChange, !reportWasDeferred { tracksClearedUnreported = true }
            hasDeferredTracksChange = reportWasDeferred
        } else if tracksClearedUnreported {
            // A load before cleared them; stopping it ends that load.
            hasDeferredTracksChange = true
        }
        endDeferringTracksChanged()
    }

    public func load(_ request: MediaLoadRequest) {
        // Now, not in the reset: a load in the background sets `isLoading` first, and nothing is saved while loading.
        saveCurrentPlaybackProgress()
        let normalizedPath = Self.normalizeMediaPath(request.path)
        let isNetwork = MediaURL.isNetworkURL(normalizedPath)
        let isRemoteOrMounted = MediaURL.isRemoteOrMountedVolume(normalizedPath)
        var normalizedRequest = request
        normalizedRequest.path = normalizedPath
        applyHostState(of: request)

        // If the path represents a playlist file (.m3u, .m3u8, .pls, .xspf, .cue), parse and load it into the playlist
        if PlaylistParser.isPlaylistFile(path: normalizedPath),
            let playlistURL = isNetwork ? URL(string: normalizedPath) : URL(fileURLWithPath: normalizedPath)
        {
            self.isLoading = true
            self.playlist.setIsLoading(true)
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.playlist.setIsLoading(false)
                    if Task.isCancelled {
                        self.isLoading = false
                    }
                }
                let parsedItems = await PlaylistParser.parseAsync(url: playlistURL)
                guard !Task.isCancelled else { return }
                if !parsedItems.isEmpty {
                    AppLog.info(
                        .playlist,
                        "Opening playlist '\(playlistURL.lastPathComponent)' with \(parsedItems.count) track(s)"
                    )
                    self.playlist.replaceAll(items: parsedItems)
                    if let firstItem = self.playlist.currentItem {
                        self.load(item: firstItem)
                    } else {
                        self.isLoading = false
                    }
                } else if isNetwork {
                    // Fallback to loading via demuxer as HLS/stream if parsing yielded no separate items
                    await self.loadAsyncKeepingHostState(normalizedRequest)
                } else if await PlaylistParser.isHLSManifest(fileAt: playlistURL), !Task.isCancelled {
                    // A saved HLS manifest lists no tracks either: the demuxer plays it. An empty playlist doesn't.
                    await self.loadAsyncKeepingHostState(normalizedRequest)
                } else {
                    self.isLoading = false
                }
            }
            return
        }

        // Immediately update mediaTitle and artwork so UI reflects loaded track synchronously
        self.mediaTitle = Self.resolveTitle(from: normalizedPath, explicitTitle: request.title)
        self.artworkData = request.artworkData
        self.artworkURL = request.artworkURL

        if isRemoteOrMounted {
            self.isLoading = true
            self.playbackState = .loading
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                await self?.loadAsyncKeepingHostState(normalizedRequest)
            }
        } else {
            loadSync(normalizedRequest)
        }
    }

    /// Waits for a load `load(_:)` left running in the background (files on network volumes, playlist files), including
    /// the one it hands on to, such as a playlist's first item. Returns at once after a synchronous load.
    public func waitForPendingLoad() async {
        while let task = loadingTask {
            await task.value
            if loadingTask == task { break }
        }
    }

    public func loadAsync(_ request: MediaLoadRequest) async {
        applyHostState(of: request)
        await loadAsyncKeepingHostState(request)
    }

    /// Takes the request's action buttons and track navigation. Now, not when a background load resets the rest: the
    /// previous media's must not apply to this one, and what the host sets right after `load` must survive that reset.
    private func applyHostState(of request: MediaLoadRequest) {
        actionButtons = request.actionButtons
        trackNavigation = request.trackNavigation
    }

    /// `loadAsync` for loads `load(_:)` started: it already applied the request's host state (`applyHostState`), and
    /// the host may have replaced it since.
    private func loadAsyncKeepingHostState(_ request: MediaLoadRequest) async {
        let path = request.path
        let (loadID, interruptContext) = resetPlaybackTrackingState(
            for: path,
            explicitTitle: request.title,
            artworkData: request.artworkData,
            artworkURL: request.artworkURL
        )
        // However the load ends without new tracks (a failure, a cancel), the cleared ones are reported; unless
        // another load replaced it, which reports its own.
        defer {
            if currentLoadID == loadID { reportClearedTracksIfOwed() }
        }

        AppLog.info(
            .engine,
            "Loading async: \(path) title: \(self.mediaTitle) with headers count: \(request.headers.count) startTime: \(String(describing: request.startTime))"
        )

        // A saved manifest of network media is read to tell: off the main thread, as a stalled volume would hang it.
        var isNetwork = MediaURL.isNetworkURL(path)
        if !isNetwork {
            isNetwork = await Task.detached(priority: .userInitiated) {
                MediaURL.isHLSManifestWithRemoteMedia(atPath: path)
            }.value
        }
        let maxAttempts = isNetwork ? 5 : 1
        var newDemuxer: MediaDemuxer? = nil

        for attempt in 1...maxAttempts {
            if self.currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled {
                break
            }

            let task = Task.detached(priority: .userInitiated) { () -> MediaDemuxer? in
                guard !Task.isCancelled, !interruptContext.isCancelled else { return nil }
                return MediaDemuxer(url: path, headers: request.headers, interruptContext: interruptContext)
            }

            newDemuxer = await task.value
            if newDemuxer != nil {
                break
            }

            // If another load was started or this task was cancelled, break immediately
            if self.currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled {
                break
            }

            // Check if failure is a transient socket/network error
            if let err = interruptContext.lastError {
                let code = err.code
                // Transient Darwin/POSIX network socket error codes:
                // -65 (EHOSTUNREACH), -61 (ECONNREFUSED), -51 (ENETUNREACH), -60 (ETIMEDOUT),
                // -64 (EHOSTDOWN), -54 (ECONNRESET), -50 (ENETDOWN)
                let transientCodes: Set<Int32> = [-65, -61, -51, -60, -64, -54, -50]
                let isTransient = transientCodes.contains(code)
                if isTransient && attempt < maxAttempts {
                    AppLog.warning(
                        .engine,
                        "Transient network failure (\(err.message), code \(code)) opening '\(path)' on attempt \(attempt)/\(maxAttempts). Retrying in \(attempt * 250)ms..."
                    )
                    try? await Task.sleep(nanoseconds: UInt64(attempt * 250_000_000))
                    continue
                }
            }
            break
        }

        // Prevent race condition: if another load started or task was cancelled, discard result
        if self.currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled {
            AppLog.warning(.engine, "Loading was superseded or cancelled for: \(path)")
            if self.currentLoadID == loadID {
                self.isLoading = false
                self.playbackState = .idle
            }
            return
        }

        guard let demuxer = newDemuxer else {
            let errorDetail: String
            if let err = interruptContext.lastError {
                errorDetail = "\(err.message) (code \(err.code))"
            } else {
                errorDetail = "Failed to open stream or media file."
            }
            AppLog.error(.engine, "Failed to open file or network stream '\(path)': \(errorDetail)")
            self.isLoading = false
            self.loadError = errorDetail
            self.playbackState = .failed(errorDetail)
            return
        }

        applyLoadedDemuxer(
            demuxer,
            path: path,
            headers: request.headers,
            requestedStartTime: request.startTime,
            requestedAudioTrack: request.audioTrack,
            requestedSubtitleTrack: request.subtitleTrack
        )
    }

    func loadSync(_ request: MediaLoadRequest) {
        loadingTask?.cancel()
        loadingTask = nil

        let path = request.path
        let (_, interruptContext) = resetPlaybackTrackingState(
            for: path,
            explicitTitle: request.title,
            artworkData: request.artworkData,
            artworkURL: request.artworkURL
        )
        // However the load ends without new tracks (it fails), the cleared ones are reported.
        defer { reportClearedTracksIfOwed() }

        AppLog.info(
            .engine,
            "Loading sync: \(path) title: \(self.mediaTitle) startTime: \(String(describing: request.startTime))"
        )

        guard let demuxer = MediaDemuxer(url: path, headers: request.headers, interruptContext: interruptContext) else {
            let errorDetail: String
            if let err = interruptContext.lastError {
                errorDetail = "\(err.message) (code \(err.code))"
            } else {
                errorDetail = "Failed to open media file."
            }
            AppLog.error(.engine, "Failed to open file '\(path)': \(errorDetail)")
            self.loadError = errorDetail
            self.isLoading = false
            self.playbackState = .failed(errorDetail)
            return
        }

        applyLoadedDemuxer(
            demuxer,
            path: path,
            headers: request.headers,
            requestedStartTime: request.startTime,
            requestedAudioTrack: request.audioTrack,
            requestedSubtitleTrack: request.subtitleTrack
        )
    }

    public func stop() {
        loadingTask?.cancel()
        loadingTask = nil
        resetMediaState(reportingTracks: true)
        mediaTitle = ""
        artworkData = nil
        artworkURL = nil
        actionButtons = []
        trackNavigation = TrackNavigation()
        isLoading = false
        playbackState = .idle
    }

    public func saveCurrentPlaybackProgress() {
        guard isLoaded, !isLoading, let path = currentPath, media.duration > 0 else { return }
        let progressTime = chaseTargetTime ?? currentTime
        AppLog.debug(.engine, "Saving playback progress for '\(path)' at \(progressTime)s / \(media.duration)s")
        if progressTime > 0 {
            historyStore.savePosition(
                for: path,
                position: progressTime,
                duration: media.duration,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio,
                preferences: preferencesForHistory
            )
        } else {
            historyStore.savePreferences(for: path, duration: media.duration, preferencesForHistory)
        }
    }

    public enum SubtitleSelectionPreference: Equatable, Sendable {
        case disable
        case select(trackId: Int)
    }

    /// Track selection, delays and the picture's aspect override and crop to persist. A selection made on load by
    /// `TrackAutoSelection` isn't saved; the subtitles write theirs (`SubtitleController.writePreferences`).
    private var preferencesForHistory: PlaybackPreferences {
        var preferences = PlaybackPreferences(
            audioTrackId: selectedAudioTrackId >= 0 && !audioSelectionIsAutomatic ? selectedAudioTrackId : nil,
            audioDelay: audioDelay,
            videoAspectRatio: videoGeometry.aspectRatio ?? PlaybackPreferences.noGeometryOverride,
            videoCrop: videoGeometry.crop ?? PlaybackPreferences.noGeometryOverride
        )
        subtitles.writePreferences(into: &preferences)
        return preferences
    }

    /// Extracts an explicit stream index from strings formatted as `stream:N` or `s:N`.
    private nonisolated static func parseStreamIndex(from key: String) -> Int? {
        if key.hasPrefix("stream:") {
            return Int(key.dropFirst("stream:".count))
        } else if key.hasPrefix("s:") {
            return Int(key.dropFirst("s:".count))
        }
        return nil
    }

    /// Resolves an audio track spec to a track id.
    public nonisolated static func resolveAudioTrackId(_ spec: String, in tracks: [MediaDemuxer.AudioTrack]) -> Int? {
        let key = spec.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        // Explicit "stream:N" or "s:N" prefix (matching container stream index, e.g. from host app / FFmpeg)
        if let streamIdx = parseStreamIndex(from: key),
            let match = tracks.first(where: { $0.streamIndex == streamIdx })
        {
            return match.id
        }

        // Direct numeric match: prioritize track.id (0, 1, 2...), then fallback to container streamIndex
        if let id = Int(key) {
            if let byId = tracks.first(where: { $0.id == id }) { return byId.id }
            if let byStream = tracks.first(where: { $0.streamIndex == id }) { return byStream.id }
        }

        if let byLang = tracks.first(where: { matchesLanguage($0.language, key) }) {
            return byLang.id
        }
        return tracks.first(where: { matchesTitle($0.title, key) })?.id
    }

    /// Resolves a subtitle spec to a selection preference. Returns nil if unresolved.
    public nonisolated static func resolveSubtitleSelection(_ spec: String, in tracks: [SubtitleTrack])
        -> SubtitleSelectionPreference?
    {
        let key = spec.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if ["off", "none", "no", "disabled"].contains(key) { return .disable }

        // Explicit "stream:N" or "s:N" prefix (matching container stream index, e.g. from host app / FFmpeg)
        // Closed captions in the video's pictures have no stream of their own: its index names the video.
        let byStream = { (index: Int) in tracks.first { $0.streamIndex == index && !$0.captionsInVideo } }
        if let streamIdx = parseStreamIndex(from: key), let match = byStream(streamIdx) {
            return .select(trackId: match.id)
        }

        // Direct numeric match: prioritize track.id, then fallback to container streamIndex
        if let id = Int(key) {
            if let byId = tracks.first(where: { $0.id == id }) { return .select(trackId: byId.id) }
            if let match = byStream(id) { return .select(trackId: match.id) }
        }

        if let byLang = tracks.first(where: { matchesLanguage($0.language, key) }) {
            return .select(trackId: byLang.id)
        }
        if let byTitle = tracks.first(where: { matchesTitle($0.title, key) }) {
            return .select(trackId: byTitle.id)
        }
        return nil
    }

    private nonisolated static func matchesLanguage(_ language: String, _ key: String) -> Bool {
        let lang = language.lowercased().trimmingCharacters(in: .whitespaces)
        return !lang.isEmpty && lang != "und" && (lang == key || lang.hasPrefix(key + "-") || key.hasPrefix(lang + "-"))
    }

    private nonisolated static func matchesTitle(_ title: String, _ key: String) -> Bool {
        let lowerTitle = title.lowercased()
        if key.count < 3 {
            let words = lowerTitle.components(separatedBy: CharacterSet.alphanumerics.inverted)
            return words.contains(key)
        }
        return lowerTitle.contains(key)
    }

    /// Computes the optimal target reference white (nits) for ITU-R BT.2390 tone mapping
    /// on standard SDR displays, adapting to content peak and frame-average luminance.
    public nonisolated static func computeAdaptiveTargetNits(
        baseTargetNits: Float = 203.0,
        maxPeakNits: Float,
        maxFallNits: Float = 0.0
    ) -> Float {
        // If content is high-peak mastering (>= 950 nits) and not extremely dark, keep ITU reference (203.0)
        if maxPeakNits >= 950.0 && (maxFallNits == 0 || maxFallNits >= 120.0) {
            return baseTargetNits
        }

        // Scale reference white down smoothly for lower-peak mastering (300...1000 -> 100...baseTargetNits)
        var target = 100.0 + (baseTargetNits - 100.0) * max(min((maxPeakNits - 300.0) / 700.0, 1.0), 0.0)

        // If the scene average (MaxFALL) is known and low (< 100 nits, e.g. low-key dark drama),
        // adjust the target white to prevent crushing midtones and shadows
        if maxFallNits > 0 && maxFallNits < 100.0 {
            let fallFactor = max(maxFallNits / 100.0, 0.7)
            target = min(target, 100.0 + (target - 100.0) * fallFactor)
        }

        return max(min(target, baseTargetNits), 100.0)
    }

    func applyLoadedDemuxer(
        _ demuxer: MediaDemuxer, path: String, headers: [String: String], requestedStartTime: Double?,
        requestedAudioTrack: String?, requestedSubtitleTrack: String?
    ) {
        resetRelativeSeekBurst()
        self.demuxer = demuxer
        // In order (the main queue is FIFO; tasks aren't, at the different priorities of the reading thread and
        // `seekQueue`): a seek's change handled after the splice read past it would drop that splice.
        demuxer.onVariantChanged = { [weak self, weak demuxer] change in
            DispatchQueue.main.async {
                guard let self, let demuxer, self.demuxer === demuxer else { return }
                self.variantWillPlay(change)
            }
        }
        pendingVariantChanges = []
        // A network source is read ahead (started below), so that a slow network shows as buffering only once that
        // runs out.
        let readsAhead = demuxer.isNetworkSource || Self.readsAheadLocalFiles
        // Adaptive bitrate needs the read-ahead's throughput and margin.
        canSelectAutomaticVariant = readsAhead && demuxer.variants.count > 1
        isVariantAutomatic = canSelectAutomaticVariant && demuxer.isAdaptiveBitrateEnabled
        self.currentPath = path
        self.currentHeaders = headers
        self.media = MediaInfo(demuxer: demuxer)
        let frameDuration = demuxer.nominalFrameDuration
        self.nominalFrameDuration = frameDuration
        self.nominalFrameDurationLock.withLock { $0 = frameDuration }
        self.videoStartTimeLock.withLock { $0 = demuxer.videoStartTime }
        updateDisplayLinkFrameRate()
        if self.mediaTitle.isEmpty {
            self.mediaTitle = Self.resolveTitle(from: path)
        }

        // Synchronize playlist with current media
        let isNetwork = MediaURL.isNetworkURL(path)
        let mediaURL = isNetwork ? URL(string: path) : URL(fileURLWithPath: path)
        if let mediaURL {
            let matchesCurrent: Bool = {
                guard let currentURL = playlist.currentItem?.url else { return false }
                if currentURL.isFileURL && mediaURL.isFileURL {
                    return currentURL.standardizedFileURL.path == mediaURL.standardizedFileURL.path
                }
                return currentURL.absoluteString == mediaURL.absoluteString
            }()

            if !matchesCurrent {
                playlist.setInitialMedia(
                    url: mediaURL,
                    title: self.mediaTitle,
                    autoLoadFolder: configuration.autoLoadFolderMedia
                )
            }
            playlist.updateCurrentItemDuration(demuxer.durationSeconds)
        }
        if demuxer.hasVideo {
            thumbnailManager.prepareThumbnails(
                for: path,
                duration: demuxer.durationSeconds,
                headers: headers,
                networkPolicy: configuration.networkThumbnailPolicy
            )
        }
        // Fall back to embedded container artwork if no explicit artwork data was provided
        if self.artworkData == nil, let embedded = demuxer.embeddedArtworkData {
            self.artworkData = embedded
        }
        if !demuxer.chapters.isEmpty {
            AppLog.info(.demuxer, "Loaded \(demuxer.chapters.count) chapter(s)")
        }
        // Track selection priority chain (per kind):
        // 1. Explicit request (CLI, host app, deep link)
        // 2. PlaybackHistoryStore saved selection (always: `resumePlayback` governs only the position)
        // 3. `TrackAutoSelection` by the language settings and the tracks' flags
        let savedTracks = historyStore.savedPreferences(for: path)

        if let spec = requestedAudioTrack,
            let id = Self.resolveAudioTrackId(spec, in: demuxer.audioTracks)
        {
            demuxer.selectAudioTrack(trackId: id)
            AppLog.info(.audio, "Using explicit audio track: \(id)")
        } else if let saved = savedTracks?.audioTrackId,
            demuxer.audioTracks.contains(where: { $0.id == saved })
        {
            demuxer.selectAudioTrack(trackId: saved)
            AppLog.info(.audio, "Restored audio track from saved history: \(saved)")
        } else if let id = TrackAutoSelection.audioTrackId(
            in: demuxer.audioTracks, languages: configuration.trackLanguages.audioLanguages)
        {
            audioSelectionIsAutomatic = true
            if id != demuxer.selectedAudioTrackIndex {
                demuxer.selectAudioTrack(trackId: id)
                AppLog.info(.audio, "Selected audio track \(id) by language and default flag")
            }
        }

        // The new tracks and the selection below are reported once, when the load is applied, even when they equal
        // the previous media's.
        beginDeferringTracksChanged()
        defer { endDeferringTracksChanged() }
        hasDeferredTracksChange = true
        self.audioTracks = demuxer.audioTracks
        self.selectedAudioTrackId = demuxer.selectedAudioTrackIndex
        self.variants = demuxer.variants
        self.selectedVariantId = demuxer.selectedVariantId
        // Set directly: the pipeline is flushed below, so there is no queued audio to move.
        let savedAudioDelay = savedTracks?.audioDelay ?? 0
        self.audioDelay =
            savedAudioDelay.isFinite
            ? min(max(savedAudioDelay, Self.audioDelayRange.lowerBound), Self.audioDelayRange.upperBound) : 0
        audioSink.setDelay(CMTime(seconds: audioDelay, preferredTimescale: 1_000_000))
        if self.audioDelay != 0 {
            AppLog.info(.audio, "Restored audio delay from saved history: \(self.audioDelay)s")
        }
        restoreVideoGeometry(from: savedTracks)
        self.loadError = nil
        subtitles.mediaDidLoad(
            tracks: demuxer.subtitleTracks, path: path, saved: savedTracks, requestedTrack: requestedSubtitleTrack,
            audioLanguage: audioTracks.first { $0.id == selectedAudioTrackId }?.language)

        if demuxer.hasVideo {
            let baseAdaptive = Self.computeAdaptiveTargetNits(
                baseTargetNits: 203.0,
                maxPeakNits: demuxer.maxPeakNits,
                maxFallNits: demuxer.maxFallNits
            )
            self.baseAdaptiveTargetNits = baseAdaptive
            let effectiveTargetNits = max(min(baseAdaptive * self.targetNitsScale, 500.0), 80.0)
            self.metalTargetNits = effectiveTargetNits
            let autoShadowLift: Float =
                (demuxer.maxFallNits > 0 && demuxer.maxFallNits < 80.0 && self.metalShadowLift == 0.0) ? 0.008 : 0.0

            self.dynamicToneMapLock.withLock {
                $0.basePeakNits = demuxer.maxPeakNits
                $0.baseTargetNits = baseAdaptive
                $0.smoothedPeakNits = demuxer.maxPeakNits
                $0.smoothedTargetNits = effectiveTargetNits
                $0.lastRenderModeName = "Metal SDR"
                $0.lastDoviMetadata = nil
            }

            let primaries = ColorPrimariesClass(demuxer.colorPrimaries)
            self.metalRenderer?.updateUniforms { uniforms in
                uniforms.sourcePeakNits = demuxer.maxPeakNits
                uniforms.targetNits = effectiveTargetNits
                if autoShadowLift > 0.0 {
                    uniforms.outputShadowLift = autoShadowLift
                }
                uniforms.colorPrimaries = primaries.shaderIndex
                uniforms.transferFunction = TransferFunctionClass(demuxer.transferFunction).shaderIndex
                uniforms.bitDepth = UInt32(demuxer.bitDepth)
                uniforms.isFullRange = demuxer.isFullRange ? 1 : 0
                if demuxer.isDolbyVisionProfile5 {
                    uniforms.colorSpaceMode = 2  // Dolby Vision IPT / ICtCp
                } else if primaries == .bt709 {
                    uniforms.colorSpaceMode = 1  // BT.709
                } else {
                    uniforms.colorSpaceMode = 0  // Standard BT.2020 YCbCr
                }
            }

            let video = media.video
            self.performanceMonitor.updateStreamMetadata(
                resolution: "\(video.width)x\(video.height)",
                codecName: video.codecName,
                bitDepth: video.bitDepth,
                colorPrimaries: video.colorPrimaries,
                transferFunction: video.transferFunction,
                sourcePeakNits: video.sourcePeakNits,
                targetNits: effectiveTargetNits,
                dolbyVisionProfile: video.dolbyVisionProfile
            )

            let initialToneMode: PlayerPerformanceMonitor.ToneMapEngineMode
            if self.activeRenderMode == .system {
                initialToneMode = .appleXDR
            } else if demuxer.isDolbyVisionProfile5 || demuxer.dolbyVisionProfile != nil {
                initialToneMode = .doviL1Auto
            } else if demuxer.isHDR {
                initialToneMode = .bt2390
            } else {
                initialToneMode = .directSDR
            }
            self.performanceMonitor.updateToneMapParams(
                PlayerPerformanceMonitor.ToneMapParams(
                    mode: initialToneMode,
                    peakNits: demuxer.maxPeakNits,
                    targetNits: effectiveTargetNits
                )
            )
            self.currentMetrics = self.performanceMonitor.currentMetrics
        }

        AppLog.info(
            .engine,
            "Loaded successfully. Duration: \(self.media.duration)s, peakNits: \(demuxer.maxPeakNits), formatDesc: \(String(describing: demuxer.formatDescription))"
        )

        // Initialize video decoder if video stream is present
        if demuxer.hasVideo {
            guard let videoDecoder = VideoDecoderFactory.makeDecoder(for: demuxer.codec, demuxer: demuxer) else {
                let err = "Failed to initialize video decoder for \(demuxer.codec)."
                AppLog.error(.engine, err)
                self.loadError = err
                self.isLoading = false
                self.playbackState = .failed(err)
                return
            }
            installVideoDecoder(videoDecoder)
        }

        // Initialize audio decoder if audio stream is present
        if demuxer.hasAudio, let audioParams = demuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: audioParams, timebase: demuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            AppLog.info(
                .audio,
                "Audio decoder initialized: \(String(describing: self.audioDecoder != nil)), channels: \(demuxer.audioChannels), rate: \(demuxer.audioSampleRate)"
            )
        } else {
            self.audioDecoder = nil
            AppLog.warning(.audio, "No audio track found or failed to get codec parameters")
        }

        if !demuxer.hasVideo {
            clearVideoSurface()
        } else {
            flushDisplayLayer(removingDisplayedImage: false)
        }
        self.audioSink.flush()
        self.audioDecoder?.flush()

        // Determine effective start time using the priority chain:
        // 1. Explicit requestedStartTime (CLI, host app, deep link)
        // 2. PlaybackHistoryStore saved position (if resume is enabled)
        // 3. Fallback to 0.0
        let effectiveStartTime: Double
        if let explicit = requestedStartTime {
            effectiveStartTime = min(max(0.0, explicit), max(0.0, self.media.duration - 1.0))
            AppLog.info(.engine, "Using explicit start time: \(effectiveStartTime)s (ignoring history)")
        } else if configuration.resumePlayback,
            let saved = historyStore.savedPosition(
                for: path,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio
            )
        {
            effectiveStartTime = min(saved, max(0.0, self.media.duration - 1.0))
            AppLog.info(.engine, "Resuming playback from saved history: \(effectiveStartTime)s")
        } else {
            effectiveStartTime = 0.0
        }

        if effectiveStartTime > 0 {
            demuxer.seek(to: effectiveStartTime, audioDelay: audioDelay)
            demuxer.setTargetAudioPts(seconds: effectiveStartTime - audioDelay)
            demuxer.purgeAudio(beforeSeconds: effectiveStartTime - audioDelay)
        }
        // Once the description above is read: from here on a variant switch's splice rewrites it on the reading thread
        // (`MediaDemuxer.readingDescription`). Before the feeders start, as they then only take from the queues.
        if readsAhead {
            demuxer.startReadAhead()
        }
        setExactSeekDisplayFloor(effectiveStartTime > 0 ? effectiveStartTime : nil)

        self.currentTime = effectiveStartTime
        self.isLoaded = true
        self.isLoading = false
        // The track was chosen above, before the start time was applied.
        subtitles.timeDidChange(to: effectiveStartTime, .mediaStarted)

        // Synchronously re-anchor clock and reset FrameQueue so any subsequent play() or display tick
        // observes the clean timeline start and cannot drop initial frames with stale clock from previous media
        let targetCMTime = CMTime(seconds: effectiveStartTime, preferredTimescale: 60000)
        self.startSynchronizerClock(at: targetCMTime, rate: 0.0, armGuard: false)
        self.frameQueue.clear(resetDroppedFrames: true)

        let decoder = self.stallGuardedDecoder(for: "the post-load flush")
        let hasVideo = demuxer.hasVideo
        let loadID = self.currentLoadID
        let seekId = self.currentSeekId
        // On the seek queue so this flush is ordered with seeks: a seek issued right after load would
        // otherwise have its preview decode flushed from under it.
        self.seekQueue.async { [weak self] in
            if hasVideo {
                decoder.flush()
            }
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.currentLoadID == loadID else { return }
                // Paused since the load (a host's "load, then pause"): it stays paused, on its first frame. Starting
                // here would play from under the pause.
                if self.playbackState == .paused {
                    if self.currentSeekId == seekId { self.seek(to: effectiveStartTime, exact: true) }
                    return
                }
                // A seek issued right after load (e.g. a host's "load, then seek") owns the pipeline: its
                // preview is reading the demuxer on `seekQueue`, and starting the feeders here would race it
                // for packets, leaving the seek on a keyframe. Hand it the autoplay intent instead; the
                // chase-settle path starts feeding and the clock at the seek target.
                if self.currentSeekId != seekId {
                    if self.isSeeking || self.chaseTargetTime != nil {
                        self.resumePlaybackAfterChase = true
                    } else {
                        self.play()
                    }
                    return
                }
                let alreadyStarted = self.isPlaying
                if !alreadyStarted {
                    self.frameQueue.clear(resetDroppedFrames: true)
                    self.startFeeding()
                    if self.currentSeekId == seekId && self.chaseTargetTime == nil {
                        let targetCMTime = CMTime(seconds: effectiveStartTime, preferredTimescale: 60000)
                        self.currentTime = effectiveStartTime
                        let currentRate = self.playbackRate
                        AppLog.info(
                            .engine,
                            "Starting synchronizer clock: targetTime = \(String(format: "%.3f", effectiveStartTime))s, rate = \(currentRate)"
                        )
                        self.startSynchronizerClockAfterPreroll(at: targetCMTime)
                    }
                }
                self.displayLink?.isPaused = !hasVideo
                if !alreadyStarted {
                    self.isPlaying = true
                    self.playbackState = .playing
                    self.performanceMonitor.handlePlaybackStateChange(isPlaying: true)
                }
            }
        }
    }
}
