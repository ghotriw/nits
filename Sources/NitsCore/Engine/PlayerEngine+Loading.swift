@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import os

extension PlayerEngine {
    /// Reporting format passed down the loading pipeline to notify `onMediaLoaded`.
    enum LoadReporting: Sendable {
        case media(MediaLoadRequest)
        /// A playlist file and the item of it played.
        case playlist(MediaLoadRequest, item: MediaLoadRequest)
    }

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
            // `lastPathComponent` is already decoded: decoding again turns a literal `%41` into `A`.
            return last
        }
        return URL(fileURLWithPath: MediaURL.normalizeMediaPath(path)).lastPathComponent
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
        actionButtons.mediaWillLoad()

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
        resolvedSource = nil
        resetRelativeSeekBurst()
        chaseSettling.reset()
        seekGeneration.advance()
        isSeeking = false
        isLoadStartPending = false
        chase = nil
        resumePlaybackAfterChase = false
        decoderStallRecoveries = 0
        frameStep.reset()

        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        inputs?.cancel()
        inputs = nil
        stopPlaybackPipeline()
        playbackClock.setRate(0.0, time: .zero)
        audioLagDetector = AudioLagDetector()
        audioOutputInterruptionLock.withLock { $0.reset() }
        clearVideoSurface()

        currentPath = nil
        currentHistoryKey = nil
        currentSourcePath = nil
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
        toneMapping.reset()
        thumbnailManager.reset()
        audioDelay = 0
        audioSink.setDelay(.zero)
        playbackRate = playbackRateMemory.reset(current: playbackRate, carries: configuration.carriesPlaybackRate)
        // The file's aspect override and crop, zoom and pan; the scaling lasts the session.
        restoreVideoGeometry(from: nil)

        // A report already held back by a deferral this runs in is the outer one's to make, either way.
        let reportWasDeferred = hasDeferredTracksChange
        beginDeferringTracksChanged()
        audioTracks = []
        selectedAudioTrackId = -1
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
        var normalizedRequest = request
        normalizedRequest.path = MediaURL.normalizeMediaPath(request.path)
        load(normalizedRequest, reporting: .media(normalizedRequest))
    }

    func load(
        _ request: MediaLoadRequest,
        reporting: LoadReporting?
    ) {
        // Now, not in the reset: a load in the background sets `isLoading` first, and nothing is saved while loading.
        saveCurrentPlaybackProgress()
        let normalizedPath = MediaURL.normalizeMediaPath(request.path)
        let isNetwork = MediaURL.isNetworkURL(normalizedPath)
        // A network audio file of the request is opened with the media: off the main actor too.
        let isRemoteOrMounted =
            MediaURL.isRemoteOrMountedVolume(normalizedPath) || request.audioFiles.contains { !$0.url.isFileURL }
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
            var currentTask: Task<Void, Never>?
            currentTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.playlist.setIsLoading(false)
                    if Task.isCancelled && self.loadingTask == currentTask {
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
                        let playlistRequest: MediaLoadRequest? =
                            switch reporting {
                            case .media(let req), .playlist(let req, _): req
                            case nil: nil
                            }
                        self.load(item: firstItem, reportingPlaylistRequest: playlistRequest)
                    } else {
                        self.isLoading = false
                        if !self.isLoaded {
                            self.playbackState = .idle
                        }
                    }
                } else if isNetwork {
                    // Fallback to loading via demuxer as HLS/stream if parsing yielded no separate items
                    await self.loadAsyncKeepingHostState(
                        normalizedRequest, reporting: reporting)
                } else if await PlaylistParser.isHLSManifest(fileAt: playlistURL), !Task.isCancelled {
                    // A saved HLS manifest lists no tracks either: the demuxer plays it. An empty playlist doesn't.
                    await self.loadAsyncKeepingHostState(
                        normalizedRequest, reporting: reporting)
                } else {
                    self.isLoading = false
                    if !self.isLoaded {
                        self.playbackState = .idle
                    }
                }
            }
            self.loadingTask = currentTask
            return
        }

        // Immediately update mediaTitle and artwork so UI reflects loaded track synchronously
        self.mediaTitle = Self.resolveTitle(from: normalizedPath, explicitTitle: request.title)
        self.artworkData = request.artworkData
        self.artworkURL = request.artworkURL

        let shouldLoadAsync = isRemoteOrMounted || !configuration.synchronousLocalLoads
        if shouldLoadAsync {
            self.isLoading = true
            self.playbackState = .loading
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                await self?.loadAsyncKeepingHostState(
                    normalizedRequest, reporting: reporting)
            }
        } else {
            loadSync(normalizedRequest, reporting: reporting)
        }
    }

    /// Waits for a load left running in the background (asynchronous local loads, files on network volumes, playlist
    /// files), including the one it hands on to, such as a playlist's first item. Returns at once after a synchronous load.
    public func waitForPendingLoad() async {
        while let task = loadingTask {
            await task.value
            if loadingTask == task { break }
        }
    }

    public func loadAsync(_ request: MediaLoadRequest) async {
        var normalizedRequest = request
        normalizedRequest.path = MediaURL.normalizeMediaPath(request.path)
        applyHostState(of: normalizedRequest)
        await loadAsyncKeepingHostState(normalizedRequest, reporting: .media(normalizedRequest))
    }

    /// Takes the request's action buttons and track navigation. Now, not when a background load resets the rest
    /// (`resetMediaState`): the previous media's host state must not apply to this one while the load prepares, and
    /// any updates the host sets right after calling `load` must survive the asynchronous load reset.
    private func applyHostState(of request: MediaLoadRequest) {
        actionButtons.reset(host: request.actionButtons)
        trackNavigation = request.trackNavigation
    }

    /// `loadAsync` for loads `load(_:)` started: it already applied the request's host state (`applyHostState`), and
    /// the host may have replaced it since.
    ///
    /// - Parameters:
    ///   - preResolved: The page's streams already found (`selectVideoFormat`): the resolver isn't asked again.
    ///   - startsPaused: The load ends paused, on its first frame.
    ///   - reporting: Top-level request reported to `onMediaLoaded` once the demuxer is applied.
    func loadAsyncKeepingHostState(
        _ request: MediaLoadRequest,
        preResolved: ResolvedMedia? = nil,
        startsPaused: Bool = false,
        reporting: LoadReporting? = nil
    ) async {
        let path = request.path
        let (loadID, interruptContext) = resetPlaybackTrackingState(
            for: path,
            explicitTitle: request.title,
            artworkData: request.artworkData,
            artworkURL: request.artworkURL
        )
        if startsPaused { playbackState = .paused }
        // However the load ends without new tracks (a failure, a cancel), the cleared ones are reported; unless
        // another load replaced it, which reports its own.
        defer {
            if currentLoadID == loadID { reportClearedTracksIfOwed() }
        }

        AppLog.info(
            .engine,
            "Loading async: \(path) title: \(self.mediaTitle) with headers count: \(request.headers.count) startTime: \(String(describing: request.startTime))"
        )

        /// Whether another load replaced this one or it was cancelled: it then ends here, idle if still the current.
        func endIfSuperseded() -> Bool {
            guard currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled else { return false }
            AppLog.warning(.engine, "Loading was superseded or cancelled for: \(path)")
            if currentLoadID == loadID {
                isLoading = false
                playbackState = .idle
            }
            return true
        }

        func fail(_ errorDetail: String, logging message: String) {
            AppLog.error(.engine, message)
            isLoading = false
            loadError = errorDetail
            playbackState = .failed(errorDetail)
        }

        // What opens: the request's path, or the streams `mediaResolver` finds in the page it names, asked before the
        // path opens or once it failed to (`MediaResolutionOrder`). The rest of the load (history, playlist,
        // `currentPath`) keeps to the page, its history to the resolver's name for it.
        var source = request
        var historyKey = path
        var resolvedTitle: String?
        var chaptersFromResolver: [MediaChapter] = []
        var buttonsFromResolver: [PlaybackActionButton] = []
        let resolver = mediaResolver
        let pageURL = MediaURL.isNetworkURL(path) ? URL(string: path) : nil
        let order =
            preResolved != nil ? MediaResolutionOrder.beforeOpening : pageURL.flatMap { resolver?.order(for: $0) }
        // The streams given are used until they fail to open: they may have expired since they were found, and the
        // resolver is then asked, for the picture that was chosen.
        var known = preResolved
        let wantedFormat = preResolved?.selectedVideoFormatID

        enum Resolution { case resolved, declined, ended }
        /// Asks the resolver for the page's streams; those open from here on. A resolver's error fails the load.
        func resolve() async -> Resolution {
            if known == nil, resolver == nil || pageURL == nil { return .declined }
            let resolved: ResolvedMedia?
            do {
                if let known {
                    resolved = known
                } else if let resolver, let pageURL {
                    let found = try await resolver.resolve(pageURL, headers: request.headers)
                    resolved = found.map { media in wantedFormat.flatMap(media.selecting(videoFormat:)) ?? media }
                } else {
                    resolved = nil
                }
            } catch {
                if endIfSuperseded() { return .ended }
                // Asked once the URL failed to open, a resolver that only failed to read it as well (yt-dlp's generic
                // extractor: an HTTP error, a timeout) found no page: the demuxer's reason is shown.
                if order == .afterOpeningFails, (error as? MediaResolutionError)?.isAboutPage != true {
                    AppLog.info(.engine, "No page in '\(path)' either: \(error)")
                    return .declined
                }
                let errorDetail = (error as? MediaResolutionError)?.message ?? error.localizedDescription
                fail(errorDetail, logging: "Found nothing to play in '\(path)': \(errorDetail)")
                return .ended
            }
            if endIfSuperseded() { return .ended }
            guard let resolved else { return .declined }
            resolvedSource = ResolvedSource(request: request, media: resolved)
            source.path = MediaURL.normalizeMediaPath(resolved.path)
            source.headers = resolved.headers
            source.httpRequestSize = resolved.httpRequestSize
            // The request's own files are read with its headers and request size, not the page's streams' (0: the
            // rest of the file in one request, not the page's size).
            source.audioFiles =
                resolved.audioFiles
                + request.audioFiles.map { file in
                    var file = file
                    file.headers = file.headers ?? request.headers
                    file.httpRequestSize = file.httpRequestSize ?? request.httpRequestSize ?? 0
                    return file
                }
            source.subtitleFiles =
                resolved.subtitleFiles
                + request.subtitleFiles.map { file in
                    var file = file
                    file.headers = file.headers ?? request.headers
                    return file
                }
            historyKey = resolved.historyKey ?? path
            chaptersFromResolver = resolved.chapters
            buttonsFromResolver = resolved.actionButtons
            if request.title?.isEmpty ?? true, let title = resolved.title, !title.isEmpty {
                mediaTitle = title
                resolvedTitle = title
            }
            AppLog.info(
                .engine,
                "Resolved '\(path)': \(resolved.audioFiles.count) audio stream(s), "
                    + "\(resolved.subtitleFiles.count) subtitle track(s) of its own")
            return .resolved
        }

        /// Opens `source` as media, again on a transient network failure; `nil` when it can't be (or the load ended).
        func openSource() async -> MediaDemuxer? {
            let (sourcePath, sourceHeaders, requestSize) = (source.path, source.headers, source.httpRequestSize)
            // A saved manifest of network media is read to tell: off the main thread, as a stalled volume would hang it.
            var isNetwork = MediaURL.isNetworkURL(sourcePath)
            if !isNetwork {
                isNetwork = await Task.detached(priority: .userInitiated) {
                    MediaURL.isHLSManifestWithRemoteMedia(atPath: sourcePath)
                }.value
            }
            let maxAttempts = isNetwork ? Self.networkOpenAttempts : 1
            for attempt in 1...maxAttempts {
                if currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled { return nil }
                let opened = await Task.detached(priority: .userInitiated) { () -> MediaDemuxer? in
                    guard !Task.isCancelled, !interruptContext.isCancelled else { return nil }
                    return MediaDemuxer(
                        url: sourcePath, headers: sourceHeaders, httpRequestSize: requestSize,
                        interruptContext: interruptContext)
                }.value
                if let opened { return opened }
                if currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled { return nil }
                guard let err = interruptContext.lastError, Self.isTransientNetworkError(err.code),
                    attempt < maxAttempts
                else { return nil }
                AppLog.warning(
                    .engine,
                    "Transient network failure (\(err.message), code \(err.code)) opening '\(sourcePath)' on attempt \(attempt)/\(maxAttempts). Retrying in \(attempt * 250)ms..."
                )
                try? await Task.sleep(for: .milliseconds(attempt * 250))
            }
            return nil
        }

        if order == .beforeOpening, await resolve() == .ended { return }
        var newDemuxer = await openSource()
        if endIfSuperseded() { return }
        // A stream the resolver gave that didn't open (expired since `preResolved`, or a CDN session that didn't
        // answer on the first resolution) is asked for once more.
        if newDemuxer == nil, resolvedSource != nil, resolver != nil, pageURL != nil,
            !(interruptContext.lastError.map { Self.isTransientNetworkError($0.code) } ?? false)
        {
            AppLog.info(.engine, "The streams of '\(path)' didn't open: asking the resolver again")
            known = nil
            switch await resolve() {
            case .ended: return
            case .declined: break
            case .resolved:
                newDemuxer = await openSource()
                if endIfSuperseded() { return }
            }
        }
        // Not when it couldn't even reach the host: the resolver couldn't either, and would only add its own timeout.
        if newDemuxer == nil, order == .afterOpeningFails,
            !(interruptContext.lastError.map { Self.isTransientNetworkError($0.code) } ?? false)
        {
            AppLog.info(.engine, "'\(path)' didn't open as media: asking the resolver for a page in it")
            switch await resolve() {
            case .ended: return
            case .declined: break
            case .resolved:
                newDemuxer = await openSource()
                if endIfSuperseded() { return }
            }
        }

        guard let demuxer = newDemuxer else {
            let errorDetail: String
            if let err = interruptContext.lastError {
                errorDetail = "\(err.message) (code \(err.code))"
            } else {
                errorDetail = "Failed to open stream or media file."
            }
            fail(errorDetail, logging: "Failed to open file or network stream '\(source.path)': \(errorDetail)")
            return
        }

        // The audio files that go with it, opened with it: their tracks are chosen from with the media's.
        // Off the main actor: listing a network volume's folder can take seconds.
        let saved = historyStore.savedPreferences(
            for: MediaHistoryIdentity(historyKey: historyKey, path: path, sourcePath: source.path))
        let lookup = externalAudioLookup(for: path, source: source, saved: saved, demuxer: demuxer)
        // The subtitle files, read alongside: listing the folder, opening and parsing each. Given up with the load.
        let subtitleLookup = subtitleFilesLookup(for: path, files: source.subtitleFiles, saved: saved)
        let subtitleRead = Task.detached(priority: .userInitiated) {
            MediaSubtitleFiles.read(subtitleLookup, isCancelled: { interruptContext.isCancelled })
        }
        var externalAudio = await Task.detached(priority: .userInitiated) {
            Self.openExternalAudio(lookup, interrupt: interruptContext)
        }.value
        if endIfSuperseded() { return }
        // A network file of the request's that didn't open is tried again (twice, briefly: one that never opens
        // holds the load), as the media is.
        for attempt in 1...2 {
            let missing = lookup.requested.filter { file in
                !file.isLazy && !file.url.isFileURL && !externalAudio.contains { $0.file.url == file.url }
            }
            guard !missing.isEmpty else { break }
            AppLog.warning(.audio, "Opening \(missing.count) audio file(s) again in \(attempt * 250)ms")
            try? await Task.sleep(for: .milliseconds(attempt * 250))
            if endIfSuperseded() { return }
            let retry = ExternalAudioLookup(
                requested: missing, headers: lookup.headers, httpRequestSize: lookup.httpRequestSize)
            externalAudio += await Task.detached(priority: .userInitiated) {
                Self.openExternalAudio(retry, interrupt: interruptContext)
            }.value
            if endIfSuperseded() { return }
        }
        let subtitleFiles = await subtitleRead.value
        if endIfSuperseded() { return }
        // The request's files first, as they were asked for.
        let rank = { (opened: OpenedAudioFile) in
            lookup.requested.firstIndex { $0.url == opened.file.url } ?? lookup.requested.count
        }
        externalAudio = externalAudio.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        if let lost = lookup.requested.first(where: { file in
            file.isRequired && !externalAudio.contains { $0.file.url == file.url }
        }) {
            for opened in externalAudio { opened.demuxer.cancel() }
            demuxer.cancel()
            fail(
                "Can't read the media's audio from \(lost.url.host ?? lost.url.absoluteString)",
                logging: "Failed to open the audio of '\(path)': \(lost.url.absoluteString)")
            return
        }
        let inputs = Self.makeInputs(main: demuxer, requested: lookup.requested, opened: externalAudio)
        // The track to start with may be in a file only declared: opened before the media starts, as it is the one heard.
        if let url = inputs.unopenedFileToStartWith(
            requested: request.audioTrack, saved: saved, languages: configuration.trackLanguages.audioLanguages)
        {
            // Aborted with the load (`interruptContext`), as the media's own opening is.
            if await inputs.openExternalAudio(url: url, interrupt: interruptContext).isEmpty {
                inputs.dropUnopenedFile(at: url)
            }
            if endIfSuperseded() {
                inputs.cancel()
                return
            }
        }

        applyLoadedDemuxer(
            demuxer,
            inputs: inputs,
            path: path,
            sourcePath: source.path,
            historyKey: historyKey,
            headers: source.headers,
            httpRequestSize: source.httpRequestSize,
            subtitleFiles: source.subtitleFiles,
            saved: saved,
            readSubtitleFiles: subtitleFiles,
            requestedStartTime: request.startTime,
            requestedAudioTrack: request.audioTrack,
            requestedSubtitleTrack: request.subtitleTrack,
            resolvedTitle: resolvedTitle,
            resolvedChapters: chaptersFromResolver,
            resolvedActionButtons: buttonsFromResolver,
            reporting: reporting
        )
    }

    /// How many times a network source is opened at most, the first included.
    static let networkOpenAttempts = 5

    /// Darwin/POSIX socket errors a later attempt may not meet: EHOSTUNREACH, ECONNREFUSED, ENETUNREACH, ETIMEDOUT,
    /// EHOSTDOWN, ECONNRESET, ENETDOWN (negated, as FFmpeg returns them).
    nonisolated static func isTransientNetworkError(_ code: Int32) -> Bool {
        [-65, -61, -51, -60, -64, -54, -50].contains(code)
    }

    func loadSync(
        _ request: MediaLoadRequest,
        reporting: LoadReporting? = nil
    ) {
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

        guard
            let demuxer = MediaDemuxer(
                url: path, headers: request.headers, httpRequestSize: request.httpRequestSize,
                interruptContext: interruptContext)
        else {
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

        // Opened with the media: there is no waiting for a file in a synchronous load.
        let saved = historyStore.savedPreferences(
            for: MediaHistoryIdentity(historyKey: path, path: path, sourcePath: path))
        var lookup = externalAudioLookup(for: path, source: request, saved: saved, demuxer: demuxer)
        for index in lookup.requested.indices { lookup.requested[index].declaredStream = nil }
        applyLoadedDemuxer(
            demuxer,
            inputs: Self.makeInputs(
                main: demuxer, requested: lookup.requested,
                opened: Self.openExternalAudio(lookup, interrupt: interruptContext)),
            path: path,
            sourcePath: path,
            historyKey: path,
            headers: request.headers,
            httpRequestSize: request.httpRequestSize,
            subtitleFiles: request.subtitleFiles,
            saved: saved,
            readSubtitleFiles: MediaSubtitleFiles.read(
                subtitleFilesLookup(for: path, files: request.subtitleFiles, saved: saved)),
            requestedStartTime: request.startTime,
            requestedAudioTrack: request.audioTrack,
            requestedSubtitleTrack: request.subtitleTrack,
            reporting: reporting
        )
    }

    public func stop() {
        loadingTask?.cancel()
        loadingTask = nil
        resetMediaState(reportingTracks: true)
        subtitles.discardDownloadedDocuments()
        mediaTitle = ""
        artworkData = nil
        artworkURL = nil
        actionButtons.reset()
        trackNavigation = TrackNavigation()
        isLoading = false
        playbackState = .idle
    }

    public func saveCurrentPlaybackProgress() {
        guard isLoaded, !isLoading, let path = currentHistoryKey, media.duration > 0 else { return }

        let identity = MediaHistoryIdentity(historyKey: path, path: currentPath, sourcePath: currentSourcePath)
        let progressTime = chase?.seconds ?? currentTime
        AppLog.debug(.engine, "Saving playback progress for '\(path)' at \(progressTime)s / \(media.duration)s")
        if progressTime > 0 {
            historyStore.savePosition(
                for: identity,
                position: progressTime,
                duration: media.duration,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio,
                preferences: preferencesForHistory
            )
        } else {
            historyStore.savePreferences(
                for: identity,
                duration: media.duration,
                preferencesForHistory
            )
        }
    }

    public enum SubtitleSelectionPreference: Equatable, Sendable {
        case disable
        case select(trackId: Int)
    }

    /// Track selection, delays, the speed chosen for the media and the picture's aspect override and crop to persist.
    /// The audio and subtitle tracks are written by their owners (`PlaybackInputs.writeAudioPreferences`,
    /// `SubtitleController.writePreferences`).
    private var preferencesForHistory: PlaybackPreferences {
        var preferences = PlaybackPreferences(
            audioDelay: audioDelay,
            playbackRate: playbackRateMemory.preference(for: playbackRate),
            videoAspectRatio: videoGeometry.aspectRatio ?? PlaybackPreferences.noGeometryOverride,
            videoCrop: videoGeometry.crop ?? PlaybackPreferences.noGeometryOverride
        )
        inputs?.writeAudioPreferences(into: &preferences)
        subtitles.writePreferences(into: &preferences)
        return preferences
    }

    /// Plays the media at the speed saved for it, unless one was chosen while it loaded; without either it keeps the
    /// speed `resetMediaState` left.
    private func restorePlaybackRate(from saved: PlaybackPreferences?) {
        let rate = playbackRateMemory.restore(saved: saved?.playbackRate, current: playbackRate)
        guard rate != playbackRate else { return }
        playbackRate = rate
        AppLog.info(.engine, "Restored playback rate from saved history: \(playbackRate)x")
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

    /// What to look for when opening the audio files that go with a media (`openExternalAudio`).
    struct ExternalAudioLookup: Sendable {
        /// The request's files (`MediaLoadRequest.audioFiles`), and the headers and request size a network one is
        /// read with.
        var requested: [MediaLoadRequest.AudioFile] = []
        var headers: [String: String] = [:]
        var httpRequestSize: Int?
        /// The media's path, next to which files named as it are tracks of it; `nil` for none: media without a
        /// picture (`song.mp3` next to `song.flac` is another copy, not its audio) or a network URL.
        var sidecarsOf: String?
        /// The file the history saved for the media, when one of its tracks was chosen.
        var savedPath: String?
    }

    /// An audio file `openExternalAudio` could read, with how it is to be listed.
    typealias OpenedAudioFile = (file: MediaLoadRequest.AudioFile, demuxer: MediaDemuxer)

    /// What the media at `path`, its streams `source` (the request, or what a resolver found) just opened by `demuxer`,
    /// takes audio files from, with `saved` its preferences in the history. The folder is listed by
    /// `openExternalAudio`, which may run off the main actor.
    private func externalAudioLookup(
        for path: String, source: MediaLoadRequest, saved: PlaybackPreferences?, demuxer: MediaDemuxer
    ) -> ExternalAudioLookup {
        ExternalAudioLookup(
            requested: source.audioFiles.map { file in
                var file = file
                if file.url.isFileURL { file.url = file.url.standardizedFileURL }
                return file
            },
            headers: source.headers,
            httpRequestSize: source.httpRequestSize,
            sidecarsOf: demuxer.hasVideo && !MediaURL.isNetworkURL(path) ? path : nil,
            savedPath: saved?.audioTrackId == PlaybackRecord.externalAudio ? saved?.externalAudioPath : nil)
    }

    /// Finds and opens the audio files `lookup` tells of, for their audio alone: the request's, those named as the
    /// media next to it (`SidecarAudio`), then the one saved for it when it is elsewhere; those that can't be read are
    /// left out. Opens them side by side, as each opening reads (a network: seconds); blocks, so off the main actor for
    /// one. The load's `interrupt` aborts them with it.
    nonisolated static func openExternalAudio(
        _ lookup: ExternalAudioLookup, interrupt: MediaDemuxer.InterruptContext
    ) -> [OpenedAudioFile] {
        var files: [MediaLoadRequest.AudioFile] = []
        // A file declared (`MediaLoadRequest.AudioFile.declaredStream`) opens when its track is selected.
        for file in lookup.requested where !file.isLazy && !files.contains(where: { $0.url == file.url }) {
            files.append(file)
        }
        if let mediaPath = lookup.sidecarsOf {
            let mediaURL = URL(string: mediaPath).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: mediaPath)
            for url in SidecarAudio.urls(for: mediaURL).map(\.standardizedFileURL)
            where !files.contains(where: { $0.url == url }) {
                files.append(MediaLoadRequest.AudioFile(url: url))
            }
        }
        if let savedPath = lookup.savedPath, FileManager.default.fileExists(atPath: savedPath) {
            let url = URL(fileURLWithPath: savedPath).standardizedFileURL
            if !files.contains(where: { $0.url == url }) { files.append(MediaLoadRequest.AudioFile(url: url)) }
        }
        guard !files.isEmpty else { return [] }

        let opened = OSAllocatedUnfairLock(initialState: [Int: MediaDemuxer]())
        DispatchQueue.concurrentPerform(iterations: files.count) { [files] index in
            guard !interrupt.isCancelled else { return }
            let file = files[index]
            guard
                let demuxer = PlaybackInputs.openAudioFile(
                    file.url, headers: file.headers ?? lookup.headers,
                    httpRequestSize: file.httpRequestSize ?? lookup.httpRequestSize, interrupt: interrupt)
            else {
                if !interrupt.isCancelled {
                    AppLog.warning(
                        .audio, "Can't read audio file \(file.url.isFileURL ? file.url.path : file.url.absoluteString)")
                }
                return
            }
            opened.withLock { $0[index] = demuxer }
        }
        let demuxers = opened.withLock { $0 }
        return files.indices.compactMap { index in demuxers[index].map { (files[index], $0) } }
    }

    /// What `MediaSubtitleFiles.read` reads for the media at `path`: `files` (the request's or page's), those next to
    /// it, and the one `saved` selected.
    private func subtitleFilesLookup(
        for path: String, files: [MediaLoadRequest.SubtitleFile], saved: PlaybackPreferences?
    ) -> MediaSubtitleFiles.Lookup {
        MediaSubtitleFiles.Lookup(
            requested: files,
            sidecarsOf: MediaURL.isNetworkURL(path) ? nil : path,
            savedPath: saved?.subtitleTrackId == PlaybackRecord.externalSubtitle ? saved?.externalSubtitlePath : nil,
            encoding: subtitles.settings.encoding)
    }

    /// The inputs of a media just opened: the audio files in the order asked for (those declared listed, the rest
    /// opened), then those found next to it.
    static func makeInputs(
        main demuxer: MediaDemuxer, requested: [MediaLoadRequest.AudioFile], opened: [OpenedAudioFile]
    ) -> PlaybackInputs {
        let inputs = PlaybackInputs(main: demuxer)
        var rest = opened
        let attach = { (file: OpenedAudioFile) in
            let added = inputs.attachExternalAudio(
                file.demuxer, url: file.file.url, title: file.file.title, language: file.file.language)
            AppLog.info(.audio, "Found \(added.count) audio track(s) in \(file.file.url.lastPathComponent)")
        }
        for file in requested {
            if file.isLazy {
                inputs.declareExternalAudio(file)
            } else if let index = rest.firstIndex(where: { $0.file.url == file.url }) {
                attach(rest.remove(at: index))
            }
        }
        rest.forEach(attach)
        return inputs
    }

    func applyLoadedDemuxer(
        _ demuxer: MediaDemuxer, inputs: PlaybackInputs, path: String, sourcePath: String, historyKey: String,
        headers: [String: String],
        httpRequestSize: Int? = nil, subtitleFiles: [MediaLoadRequest.SubtitleFile] = [],
        saved savedTracks: PlaybackPreferences?, readSubtitleFiles: MediaSubtitleFiles,
        requestedStartTime: Double?,
        requestedAudioTrack: String?, requestedSubtitleTrack: String?,
        resolvedTitle: String? = nil,
        resolvedChapters: [MediaChapter] = [],
        resolvedActionButtons: [PlaybackActionButton] = [],
        reporting: LoadReporting? = nil
    ) {
        resetRelativeSeekBurst()
        self.inputs = inputs
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
        self.currentHistoryKey = historyKey
        self.currentSourcePath = sourcePath
        self.currentHeaders = headers
        self.media = MediaInfo(demuxer: demuxer, fallbackChapters: resolvedChapters)
        actionButtons.setResolved(resolvedActionButtons)
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
            // A page's item, in the playlist before its title was known, shows it from now on.
            if let resolvedTitle { playlist.updateCurrentItemTitle(resolvedTitle) }
        }
        if demuxer.hasVideo {
            thumbnailManager.prepareThumbnails(
                for: sourcePath,
                duration: demuxer.durationSeconds,
                headers: headers,
                httpRequestSize: httpRequestSize,
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
        let mediaIdentity = MediaHistoryIdentity(historyKey: historyKey, path: path, sourcePath: sourcePath)
        // Track selection priority chain (per kind):
        // 1. Explicit request (CLI, host app, deep link)
        // 2. PlaybackHistoryStore saved selection (`savedTracks`; always: `resumePlayback` governs only the position)
        // 3. `TrackAutoSelection` by the language settings and the tracks' flags
        inputs.selectAudioTrackOnLoad(
            requested: requestedAudioTrack, saved: savedTracks, languages: configuration.trackLanguages.audioLanguages)

        // The new tracks and the selection below are reported once, when the load is applied, even when they equal
        // the previous media's.
        beginDeferringTracksChanged()
        defer { endDeferringTracksChanged() }
        hasDeferredTracksChange = true
        self.audioTracks = inputs.audioTracks
        self.selectedAudioTrackId = inputs.selectedAudioTrackId
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
        restorePlaybackRate(from: savedTracks)
        restoreVideoGeometry(from: savedTracks)
        self.loadError = nil
        subtitles.mediaDidLoad(
            tracks: demuxer.subtitleTracks, subtitleFiles: subtitleFiles, defaultHeaders: headers,
            readFiles: readSubtitleFiles, saved: savedTracks, requestedTrack: requestedSubtitleTrack,
            audioLanguage: audioTracks.first { $0.id == selectedAudioTrackId }?.language)

        if demuxer.hasVideo {
            toneMapping.mediaDidLoad(demuxer)
            let video = media.video
            self.performanceMonitor.updateStreamMetadata(
                resolution: "\(video.width)x\(video.height)",
                codecName: video.codecName,
                bitDepth: video.bitDepth,
                colorPrimaries: video.colorPrimaries,
                transferFunction: video.transferFunction,
                sourcePeakNits: video.sourcePeakNits,
                targetNits: toneMapping.targetNits,
                dolbyVisionProfile: video.dolbyVisionProfile
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
        if let input = inputs.audioSource?.audioDecoderInput() {
            let decoder = FFAudioDecoder(codecParameters: input.parameters, timebase: input.timebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            AppLog.info(
                .audio,
                "Audio decoder initialized: \(String(describing: self.audioDecoder != nil)), channels: \(input.parameters.pointee.ch_layout.nb_channels), rate: \(input.parameters.pointee.sample_rate)"
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
                for: mediaIdentity,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio
            )
        {
            effectiveStartTime = min(saved, max(0.0, self.media.duration - 1.0))
            AppLog.info(.engine, "Resuming playback from saved history: \(effectiveStartTime)s")
        } else {
            effectiveStartTime = 0.0
        }

        setExactSeekDisplayFloor(effectiveStartTime > 0 ? effectiveStartTime : nil)

        self.currentTime = effectiveStartTime
        self.isLoaded = true
        self.isLoading = false

        // Re-anchor the clock (read at once through `PlaybackClock`) and reset FrameQueue so any subsequent play() or display tick
        // observes the clean timeline start and cannot drop initial frames with stale clock from previous media
        let targetCMTime = CMTime(seconds: effectiveStartTime, preferredTimescale: 60000)
        self.startSynchronizerClock(at: targetCMTime, rate: 0.0)
        self.frameQueue.clear(resetDroppedFrames: true)

        let decoder = self.stallGuardedDecoder(for: "the post-load flush")
        let hasVideo = demuxer.hasVideo
        let loadID = self.currentLoadID
        let seekId = self.seekGeneration.current
        let interrupt = self.currentInterruptContext
        let seekGeneration = self.seekGeneration
        let seekQueue = self.seekQueue
        let externalAudio = inputs.selectedExternal
        let audioDelay = self.audioDelay
        // Once the description above is read: from here on a variant switch's splice rewrites it on the reading thread
        // (`MediaDemuxer.readingDescription`). Before the feeders start, as they then only take from the queues; here,
        // not after the start position below, so that what the main actor does right after the load (a host's
        // `onMediaLoaded`, a track or variant switch) finds the demuxer reading ahead. Held until it is positioned
        // there, not to read from the start of the input first.
        let holdsReadAhead = readsAhead && effectiveStartTime > 0
        if readsAhead {
            demuxer.startReadAhead(held: holdsReadAhead)
        }
        // The start position and this flush, on the seek queue as any seek: ordered before a seek issued right after
        // load (whose preview decode the flush would otherwise flush from under it), and off the main thread, as
        // `av_seek_frame` reads (a network request, a search through a file without an index) under the input's lock.
        // `play()` waits for it (`isLoadStartPending`).
        isLoadStartPending = true
        self.seekQueue.async { [weak self] in
            // Not for a demuxer a newer load or a stop closed meanwhile, nor when a seek since issued positions it.
            var isPositioned = false
            if interrupt?.isCancelled != true, seekGeneration.isCurrent(seekId) {
                if effectiveStartTime > 0 {
                    demuxer.seek(to: effectiveStartTime, audioDelay: audioDelay)
                    isPositioned = true
                    demuxer.setTargetAudioPts(seconds: effectiveStartTime - audioDelay)
                    demuxer.purgeAudio(beforeSeconds: effectiveStartTime - audioDelay)
                }
                // A file's track chosen at load starts where the picture does, on its own input (a file just opened is
                // at 0).
                if let externalAudio, effectiveStartTime - audioDelay > 0 {
                    externalAudio.seek(to: effectiveStartTime - audioDelay)
                }
            }
            // Positioned here, the seek released it (`MediaDemuxer.seek`). Otherwise the seek since issued, next on this
            // queue, does, before it reads: released now, it would read a packet (a segment) from the start first. Last
            // on the queue in case none comes.
            if holdsReadAhead, !isPositioned {
                seekQueue.async { demuxer.releaseReadAhead() }
            }
            if hasVideo {
                decoder.flush()
            }
            guard let self else { return }
            DispatchQueue.main.async {
                // Not after a stop, which keeps the load's id but clears the flag.
                guard self.currentLoadID == loadID, self.isLoadStartPending else { return }
                self.isLoadStartPending = false
                // Paused since the load (a host's "load, then pause"): it stays paused, on its first frame. Starting
                // here would play from under the pause. Its seek shows the cues there when it lands.
                if self.playbackState == .paused {
                    if self.seekGeneration.isCurrent(seekId) { self.seek(to: effectiveStartTime, exact: true) }
                    return
                }
                // The cues on screen at the start, once the demuxer is there: a window read before its seek would be
                // dropped by it. A seek since issued shows and reads its own when it lands.
                if self.seekGeneration.isCurrent(seekId) {
                    self.subtitles.timeDidChange(to: effectiveStartTime, .mediaStarted)
                }
                // A seek issued right after load (e.g. a host's "load, then seek") owns the pipeline: its
                // preview is reading the demuxer on `seekQueue`, and starting the feeders here would race it
                // for packets, leaving the seek on a keyframe. Hand it the autoplay intent instead; the
                // chase-settle path starts feeding and the clock at the seek target.
                if !self.seekGeneration.isCurrent(seekId) {
                    if self.isSeeking || self.chase != nil {
                        self.resumePlaybackAfterChase = true
                    } else {
                        // A `play()` while the start ran only said so (`isLoadStartPending`).
                        if !self.isFeeding.withLock({ $0 }) { self.isPlaying = false }
                        self.play()
                    }
                    return
                }
                // Not started by a `play()` meanwhile, which only reported playing (`isLoadStartPending`).
                let alreadyStarted = self.isFeeding.withLock { $0 }
                if !alreadyStarted {
                    self.frameQueue.clear(resetDroppedFrames: true)
                    self.startFeeding()
                    if self.seekGeneration.isCurrent(seekId) && self.chase == nil {
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
                    if !self.isPlaying { self.isPlaying = true }
                    if self.playbackState != .playing { self.playbackState = .playing }
                    self.performanceMonitor.handlePlaybackStateChange(isPlaying: true)
                }
            }
        }

        switch reporting {
        case .playlist(let request, let item):
            // The item, then the playlist file: the host hears of the file last.
            onMediaLoaded?(item, historyKey, self.mediaTitle, self.media.duration)
            let playlistTitle = Self.resolveTitle(from: request.path, explicitTitle: request.title)
            onMediaLoaded?(request, request.path, playlistTitle, 0)
        case .media(let request):
            onMediaLoaded?(request, historyKey, self.mediaTitle, self.media.duration)
        case nil:
            break
        }
    }
}
