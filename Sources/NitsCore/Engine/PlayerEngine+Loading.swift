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
        if MediaDemuxer.isNetworkURL(path), let url = URL(string: path) {
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
        if MediaDemuxer.isNetworkURL(path) {
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
        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: explicitTitle)
        self.artworkData = artworkData
        self.artworkURL = artworkURL

        // Save progress for previously active media if present
        saveCurrentPlaybackProgress()

        // Reset playback tracking state so stale values from previous media do not leak
        self.currentPath = nil
        self.currentTime = 0
        self.duration = 0
        self.isLoaded = false
        self.isLoading = true

        let seekId = currentSeekId + 1
        currentSeekId = seekId
        activeSeekId.withLock { $0 = seekId }
        isSeeking = false
        chaseTargetTime = nil
        minStepFramePTS = nil
        chaseSettleTask?.cancel()
        chaseSettleTask = nil
        resumePlaybackAfterChase = false

        let loadID = UUID()
        self.currentLoadID = loadID

        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        demuxer?.cancel()
        demuxer = nil

        let interruptContext = MediaDemuxer.InterruptContext()
        self.currentInterruptContext = interruptContext

        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        clearVideoSurface()
        displayLink?.isPaused = true
        synchronizer.setRate(0.0, time: .zero)
        clockSettlingGuardLock.withLock { $0 = nil }
        isPlaying = false
        loadError = nil
        hasVideo = false
        playbackState = .loading

        return (loadID, interruptContext)
    }

    public func load(_ request: MediaLoadRequest) {
        let normalizedPath = Self.normalizeMediaPath(request.path)
        let isNetwork = MediaDemuxer.isNetworkURL(normalizedPath)
        let isRemoteOrMounted = MediaDemuxer.isRemoteOrMountedVolume(normalizedPath)

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
                    await self.loadAsync(request)
                } else {
                    self.isLoading = false
                }
            }
            return
        }

        var normalizedRequest = request
        normalizedRequest.path = normalizedPath

        // Immediately update mediaTitle and artwork so UI reflects loaded track synchronously
        self.mediaTitle = Self.resolveTitle(from: normalizedPath, explicitTitle: request.title)
        self.artworkData = request.artworkData
        self.artworkURL = request.artworkURL

        if isRemoteOrMounted {
            self.isLoading = true
            self.playbackState = .loading
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                await self?.loadAsync(normalizedRequest)
            }
        } else {
            loadSync(normalizedRequest)
        }
    }

    public func loadAsync(_ request: MediaLoadRequest) async {
        let path = request.path
        let (loadID, interruptContext) = resetPlaybackTrackingState(
            for: path,
            explicitTitle: request.title,
            artworkData: request.artworkData,
            artworkURL: request.artworkURL
        )

        AppLog.info(
            .engine,
            "Loading async: \(path) title: \(self.mediaTitle) with headers count: \(request.headers.count) startTime: \(String(describing: request.startTime))"
        )

        let isNetwork = MediaDemuxer.isNetworkURL(path)
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
        resetRelativeSeekBurst()
        let seekId = currentSeekId + 1
        currentSeekId = seekId
        activeSeekId.withLock { $0 = seekId }
        isSeeking = false
        chaseTargetTime = nil
        resumePlaybackAfterChase = false
        saveCurrentPlaybackProgress()
        loadingTask?.cancel()
        loadingTask = nil
        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        demuxer?.cancel()
        demuxer = nil
        stopPlaybackPipeline()
        clearVideoSurface()
        hasVideo = false
        videoWidth = 0
        videoHeight = 0
        nominalFrameDuration = 1.0 / 24.0
        nominalFrameDurationLock.withLock { $0 = 1.0 / 24.0 }
        sampleAspectRatio = .square
        videoCodecName = ""
        videoBitDepth = 8
        videoColorPrimaries = ""
        videoTransferFunction = ""
        videoDolbyVisionProfile = nil
        videoSourcePeakNits = 0
        currentMetrics = PlayerPerformanceMonitor.Metrics()
        dynamicToneMapLock.withLock {
            $0.basePeakNits = 1000.0
            $0.baseTargetNits = 203.0
            $0.smoothedPeakNits = 1000.0
            $0.smoothedTargetNits = 203.0
            $0.lastRenderModeName = "Metal SDR"
        }
        performanceMonitor.updateToneMapParams(
            PlayerPerformanceMonitor.ToneMapParams(mode: .none, peakNits: 0, targetNits: 203)
        )
        mediaTitle = ""
        artworkData = nil
        artworkURL = nil
        isLoaded = false
        currentPath = nil
        currentTime = 0
        duration = 0
        isLoading = false
        playbackState = .idle
        thumbnailManager.reset()
    }

    public func saveCurrentPlaybackProgress() {
        guard isLoaded, !isLoading, let path = currentPath, duration > 0 else { return }
        let progressTime = chaseTargetTime ?? currentTime
        AppLog.debug(.engine, "Saving playback progress for '\(path)' at \(progressTime)s / \(duration)s")
        if progressTime > 0 {
            historyStore.savePosition(
                for: path,
                position: progressTime,
                duration: duration,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio,
                audioTrackId: hasAudioTrackSelection ? selectedAudioTrackId : nil,
                subtitleTrackId: subtitleTrackIdForHistory
            )
        } else {
            historyStore.saveTrackSelection(
                for: path,
                duration: duration,
                audioTrackId: hasAudioTrackSelection ? selectedAudioTrackId : nil,
                subtitleTrackId: subtitleTrackIdForHistory
            )
        }
    }

    public enum SubtitleSelectionPreference: Equatable, Sendable {
        case disable
        case select(trackId: Int)
    }

    /// Subtitle selection to persist: `subtitlesOff` when disabled, `nil` for external files (not restorable).
    private var subtitleTrackIdForHistory: Int? {
        guard let id = selectedSubtitleTrackId else { return PlaybackRecord.subtitlesOff }
        if let track = subtitleTracks.first(where: { $0.id == id }), !track.isExternal {
            return id
        }
        return nil
    }

    private var hasAudioTrackSelection: Bool { selectedAudioTrackId >= 0 }

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
        if let streamIdx = parseStreamIndex(from: key),
            let match = tracks.first(where: { $0.streamIndex == streamIdx })
        {
            return .select(trackId: match.id)
        }

        // Direct numeric match: prioritize track.id, then fallback to container streamIndex
        if let id = Int(key) {
            if let byId = tracks.first(where: { $0.id == id }) { return .select(trackId: byId.id) }
            if let byStream = tracks.first(where: { $0.streamIndex == id }) { return .select(trackId: byStream.id) }
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
        self.currentPath = path
        self.currentHeaders = headers
        self.hasVideo = demuxer.hasVideo
        self.duration = demuxer.durationSeconds
        self.videoWidth = demuxer.width
        self.videoHeight = demuxer.height
        let frameDuration = demuxer.nominalFrameDuration
        self.nominalFrameDuration = frameDuration
        self.nominalFrameDurationLock.withLock { $0 = frameDuration }
        self.sampleAspectRatio = demuxer.sampleAspectRatio
        self.isHDRContent = demuxer.isHDR
        if self.mediaTitle.isEmpty {
            self.mediaTitle = Self.resolveTitle(from: path)
        }

        // Synchronize playlist with current media
        let isNetwork = MediaDemuxer.isNetworkURL(path)
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
        } else {
            thumbnailManager.reset()
        }
        // Fall back to embedded container artwork if no explicit artwork data was provided
        if self.artworkData == nil, let embedded = demuxer.embeddedArtworkData {
            self.artworkData = embedded
        }
        // Track selection priority chain (per kind):
        // 1. Explicit request (CLI, host app, deep link)
        // 2. PlaybackHistoryStore saved selection (if resume is enabled)
        // 3. Demuxer default
        let savedTracks =
            configuration.resumePlayback
            ? historyStore.savedTrackSelection(for: path)
            : nil

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
        }

        self.audioTracks = demuxer.audioTracks
        self.selectedAudioTrackId = demuxer.selectedAudioTrackIndex
        self.subtitleTracks = demuxer.subtitleTracks
        self.selectedSubtitleTrackId = nil
        self.activeSubtitleDocument = nil
        self.currentSubtitleCues.removeAll()
        self.loadedSubtitleDocuments.removeAll()
        self.lastObservedLiveSubtitleVersion = -1
        self.loadError = nil

        if let spec = requestedSubtitleTrack,
            let preference = Self.resolveSubtitleSelection(spec, in: demuxer.subtitleTracks)
        {
            switch preference {
            case .disable:
                selectSubtitleTrack(id: nil, persistHistory: false)
                AppLog.info(.subtitles, "Explicit subtitle selection: disabled")
            case .select(let trackId):
                selectSubtitleTrack(id: trackId, persistHistory: false)
                AppLog.info(.subtitles, "Using explicit subtitle track: \(trackId)")
            }
        } else if let saved = savedTracks?.subtitleTrackId {
            if saved == PlaybackRecord.subtitlesOff {
                selectSubtitleTrack(id: nil, persistHistory: false)
            } else if demuxer.subtitleTracks.contains(where: { $0.id == saved }) {
                selectSubtitleTrack(id: saved, persistHistory: false)
                AppLog.info(.subtitles, "Restored subtitle track from saved history: \(saved)")
            }
        }

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
            }

            self.metalRenderer?.updateUniforms { uniforms in
                uniforms.sourcePeakNits = demuxer.maxPeakNits
                uniforms.targetNits = effectiveTargetNits
                if autoShadowLift > 0.0 {
                    uniforms.outputShadowLift = autoShadowLift
                }
                if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                    uniforms.colorPrimaries = 1
                } else if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                    || demuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
                {
                    uniforms.colorPrimaries = 2
                } else {
                    uniforms.colorPrimaries = 0  // BT.2020
                }

                if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                    || demuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
                {
                    uniforms.transferFunction = 2  // SDR
                } else if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG {
                    uniforms.transferFunction = 1  // HLG
                } else {
                    uniforms.transferFunction = 0  // PQ
                }

                uniforms.bitDepth = UInt32(demuxer.bitDepth)
                uniforms.isFullRange = demuxer.isFullRange ? 1 : 0
                if demuxer.isDolbyVisionProfile5 {
                    uniforms.colorSpaceMode = 2  // Dolby Vision IPT / ICtCp
                } else if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                    uniforms.colorSpaceMode = 1  // BT.709
                } else {
                    uniforms.colorSpaceMode = 0  // Standard BT.2020 YCbCr
                }
            }

            // Update telemetry metadata
            let primariesStr: String = {
                if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 { return "BT.709" }
                if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                    || demuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
                {
                    return "DCI-P3"
                }
                return "BT.2020"
            }()
            let transferStr: String = {
                if demuxer.isDolbyVisionProfile5 { return "Dolby Vision (Profile 5 ICtCp)" }
                if let dvStr = demuxer.dolbyVisionProfileString {
                    return "Dolby Vision (Profile \(dvStr))"
                }
                if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                    || demuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
                {
                    return "BT.709 / SDR"
                }
                if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG { return "HLG" }
                return "PQ (ST 2084)"
            }()

            let dvProfileStr: String? = {
                if demuxer.isDolbyVisionProfile5 { return "Profile 5 (ICtCp)" }
                if let dvStr = demuxer.dolbyVisionProfileString {
                    if demuxer.dolbyVisionProfile == 8 {
                        if demuxer.dolbyVisionCompatibilityId == 1 { return "Profile 8.1 (HDR10 Base)" }
                        if demuxer.dolbyVisionCompatibilityId == 4 { return "Profile 8.4 (HLG Base)" }
                    }
                    return "Profile \(dvStr)"
                }
                return nil
            }()

            let codecDisplay: String =
                switch demuxer.codec {
                case .hevc: "HEVC"
                case .h264: "H.264"
                case .av1: "AV1"
                case .vp9: "VP9"
                case .wmv1: "WMV1"
                case .wmv2: "WMV2"
                case .wmv3: "WMV3"
                case .vc1: "VC-1"
                case .unknown: "Unknown"
                }
            self.videoCodecName = codecDisplay
            self.videoBitDepth = demuxer.bitDepth
            self.videoColorPrimaries = primariesStr
            self.videoTransferFunction = transferStr
            self.videoDolbyVisionProfile = dvProfileStr
            self.videoSourcePeakNits = demuxer.maxPeakNits

            self.performanceMonitor.updateStreamMetadata(
                resolution: "\(demuxer.width)x\(demuxer.height)",
                codecName: codecDisplay,
                bitDepth: demuxer.bitDepth,
                colorPrimaries: primariesStr,
                transferFunction: transferStr,
                sourcePeakNits: demuxer.maxPeakNits,
                targetNits: effectiveTargetNits,
                dolbyVisionProfile: dvProfileStr
            )

            let initialToneMode: PlayerPerformanceMonitor.ToneMapEngineMode
            if self.activeRenderMode == .system {
                initialToneMode = .appleXDR
            } else if demuxer.isDolbyVisionProfile5 || demuxer.dolbyVisionProfile != nil {
                initialToneMode = .doviL2Trim
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
            "Loaded successfully. Duration: \(self.duration)s, peakNits: \(demuxer.maxPeakNits), formatDesc: \(String(describing: demuxer.formatDescription))"
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
            self.decoder = videoDecoder
            let queue = self.frameQueue
            self.decoder.setOutputHandler { frame in
                if !frame.doNotDisplay {
                    queue.push(frame)
                }
            }
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
            _ = self.sampleBufferRenderer.perform(Self.flushSelector)
        }
        self.audioReceiver.flush()
        self.audioDecoder?.flush()

        // Determine effective start time using the priority chain:
        // 1. Explicit requestedStartTime (CLI, host app, deep link)
        // 2. PlaybackHistoryStore saved position (if resume is enabled)
        // 3. Fallback to 0.0
        let effectiveStartTime: Double
        if let explicit = requestedStartTime, explicit > 0 {
            effectiveStartTime = min(explicit, max(0.0, self.duration - 1.0))
            AppLog.info(.engine, "Using explicit start time: \(effectiveStartTime)s (ignoring history)")
        } else if configuration.resumePlayback,
            let saved = historyStore.savedPosition(
                for: path,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio
            )
        {
            effectiveStartTime = min(saved, max(0.0, self.duration - 1.0))
            AppLog.info(.engine, "Resuming playback from saved history: \(effectiveStartTime)s")
        } else {
            effectiveStartTime = 0.0
        }

        if effectiveStartTime > 0 {
            demuxer.seek(to: effectiveStartTime)
            demuxer.purgeAudio(beforeSeconds: effectiveStartTime)
        }

        self.currentTime = effectiveStartTime
        self.isLoaded = true
        self.isLoading = false

        // Synchronously re-anchor clock and reset FrameQueue so any subsequent play() or display tick
        // observes the clean timeline start and cannot drop initial frames with stale clock from previous media
        let targetCMTime = CMTime(seconds: effectiveStartTime, preferredTimescale: 60000)
        self.startSynchronizerClock(at: targetCMTime, rate: 0.0, armGuard: false)
        self.frameQueue.clear(resetDroppedFrames: true)

        let decoder = self.decoder
        let hasVideo = demuxer.hasVideo
        let loadID = self.currentLoadID
        let seekId = self.currentSeekId
        self.feedQueue.async { [weak self] in
            if hasVideo {
                decoder.flush()
            }
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.currentLoadID == loadID else { return }
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
                        self.startSynchronizerClock(at: targetCMTime, rate: currentRate)
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
