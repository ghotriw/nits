import Foundation

// MARK: - Background reads

extension SubtitleController {
    /// Reads what the selected embedded track misses around `seconds` (playback time; the delay is applied here) from
    /// a secondary demuxer (`MediaDemuxer.subtitleWindow`, `EmbeddedSubtitleReader.readSubtitles`) and adds it to what
    /// playback collects. Called when the track is chosen, a load or seek has landed, and the delay changes, and from
    /// the time tick while a negative delay shows the track ahead of what playback has read; a newer request cancels
    /// the one running. What playback read of the track before it was chosen (`MediaDemuxer.takeStashedSubtitles`) is
    /// merged first, for every source, and the window is what it leaves out.
    func refreshEmbedded(around seconds: Double, of slot: MediaDemuxer.SubtitleSlot = .main) {
        let trackId = slot == .main ? selectedTrackId : secondary.selectedTrackId
        let delay = slot == .main ? self.delay : secondary.delay
        let reads = slot == .main ? mainReads : secondaryReads
        guard let host, let demuxer = host.demuxer, let path = host.currentSourcePath,
            let track = tracks.first(where: { $0.id == trackId }), !track.isExternal
        else { return }
        let selection = demuxer.subtitleSelection(of: slot)
        guard selection.streamIndex >= 0 else { return }
        if let stashed = demuxer.takeStashedSubtitles(of: slot) {
            let previous = reads.stashMerge
            reads.stashMerge = Task.detached(priority: .utility) { [weak self] in
                await previous?.value
                let decoded = EmbeddedSubtitleReader.decode(stashed.snapshot, captionField: selection.captionField)
                guard
                    demuxer.mergeStashed(
                        decoded, of: stashed.snapshot, selection: stashed.selection, span: stashed.span, of: slot)
                else { return }
                await MainActor.run {
                    guard let self, let host = self.host, host.demuxer === demuxer else { return }
                    self.updateShown(at: host.currentTime)
                }
            }
        }
        let time = max(0, seconds - delay)
        let isNetwork = demuxer.isNetworkSource
        // A rendition of an HLS stream is read through the client by a lane of its own: no file, no index.
        let hlsSource = demuxer.hlsSubtitleSource(streamIndex: selection.streamIndex)
        // Before the stash is merged the window may be larger than it will be, never smaller.
        guard
            Self.subtitleWindow(
                of: demuxer, slot: slot, around: time, streamIndex: selection.streamIndex, isNetwork: isNetwork,
                hls: hlsSource)
                != nil
        else { return }

        reads.window?.cancel()
        let headers = host.currentHeaders
        if hlsSource == nil, demuxer.needsSubtitleIndex, indexLoad == nil {
            let interrupt = FFmpegInterrupt()
            let task = Task.detached(priority: .utility) {
                let index = EmbeddedSubtitleReader.readIndex(url: path, headers: headers, interrupt: interrupt)
                guard !interrupt.isCancelled else { return }
                // A file whose index can't be read is read as one without: on a network source, once.
                demuxer.storeSubtitleIndex(index ?? [:])
            }
            indexLoad = Load(task: task, interrupt: interrupt)
        }
        let interrupt = FFmpegInterrupt()
        let pendingMerge = reads.stashMerge
        let pendingIndex = indexLoad?.task
        // The second track's window waits for the first's: two reads of the same file at once would take the bandwidth
        // playback refills with twice over after a seek.
        let pendingMain = slot == .secondary ? mainReads.window?.task : nil
        // Below playback's own reads, which refill the buffer after a seek from the same file.
        let task = Task.detached(priority: .utility) { [weak self] in
            await pendingMerge?.value
            await pendingIndex?.value
            await pendingMain?.value
            guard !Task.isCancelled,
                let (range, starts) = Self.subtitleWindow(
                    of: demuxer, slot: slot, around: time, streamIndex: selection.streamIndex, isNetwork: isNetwork,
                    hls: hlsSource)
            else {
                await MainActor.run {
                    if reads.window?.interrupt === interrupt { reads.window = nil }
                }
                return
            }
            var merged = false
            var failed = false
            if starts?.isEmpty == true {
                merged = demuxer.mergeLiveSubtitles(
                    .init(), covering: range, selection: selection.id, span: selection.span, of: slot)
            } else if let hlsSource {
                // The picture of a start from a saved position or of a seek may not have anchored its sequence yet (the
                // cue on screen is what this read is for): wait for it a little, as the picture is read meanwhile.
                var read = EmbeddedSubtitleReader.readSubtitles(hls: hlsSource, in: range, interrupt: interrupt)
                var waits = 0
                while let attempt = read, attempt.covered == nil, waits < Self.anchorWaitSteps, !Task.isCancelled,
                    !interrupt.isCancelled
                {
                    try? await Task.sleep(for: .milliseconds(100))
                    waits += 1
                    read = EmbeddedSubtitleReader.readSubtitles(hls: hlsSource, in: range, interrupt: interrupt)
                }
                if let read {
                    if let covered = read.covered {
                        // Up to the first break the pictures have not anchored: the rest is playback's to read.
                        merged = demuxer.mergeLiveSubtitles(
                            read.packets, covering: covered, selection: selection.id, span: selection.span, of: slot)
                    } else {
                        // Nothing can be placed yet (the pictures anchored nothing of the window within the wait): playback
                        // reads the cues when it gets there. Left running, so the time tick doesn't ask again; the next
                        // seek, track switch or delay change replaces it.
                        failed = true
                    }
                } else {
                    failed = true
                    if !interrupt.isCancelled {
                        AppLog.warning(
                            .subtitles,
                            "Can't read subtitle rendition \(selection.streamIndex) from \(range.lowerBound) s to "
                                + "\(range.upperBound) s; what playback reads still shows")
                    }
                }
            } else if let packets = EmbeddedSubtitleReader.readSubtitles(
                url: path, headers: headers, streamIndex: selection.streamIndex,
                captionField: selection.captionField, in: (starts?.first ?? range.lowerBound)...range.upperBound,
                byteLimit: isNetwork ? EmbeddedSubtitleReader.networkWindowByteLimit : nil, interrupt: interrupt)
            {
                merged = demuxer.mergeLiveSubtitles(
                    packets, covering: range, selection: selection.id, span: selection.span, of: slot)
            } else {
                failed = true
                if !interrupt.isCancelled {
                    AppLog.warning(
                        .subtitles,
                        "Can't read subtitle stream \(selection.streamIndex) from \(range.lowerBound) s to "
                            + "\(range.upperBound) s; what playback reads still shows")
                }
            }
            await MainActor.run { [failed, merged] in
                guard let self, let host = self.host, host.demuxer === demuxer else { return }
                // A read that failed stays the running one, so the time tick (`updateShown`) doesn't try it again
                // twenty times a second; the next track switch, seek or delay change replaces it.
                if !failed, reads.window?.interrupt === interrupt { reads.window = nil }
                // Paused, no time tick would show what was read.
                if merged { self.updateShown(at: host.currentTime) }
            }
        }
        reads.window = Load(task: task, interrupt: interrupt)
    }

    /// The window of the selected track to read at `time` (`MediaDemuxer.subtitleWindow`), with the starts of the
    /// track's packets in it by the file's own index (`indexedSubtitleStarts`, `nil` when it doesn't list them or
    /// isn't read yet): a window with none is merged empty, unread, and a read starts at the first. A network source
    /// is read only where the index tells (Matroska Cues, an MP4 sample table), up to `networkWindowByteLimit`:
    /// elsewhere a window would read every stream of the file for seconds, against playback refilling after a seek.
    nonisolated private static func subtitleWindow(
        of demuxer: MediaDemuxer, slot: MediaDemuxer.SubtitleSlot, around time: Double, streamIndex: Int,
        isNetwork: Bool, hls: HLSSubtitleWindowSource?
    ) -> (range: ClosedRange<Double>, starts: [Double]?)? {
        // An HLS playlist is no file for a second demuxer to open: a VOD rendition is read through the client (`hls`,
        // whole window, no index), the rest of it (a live stream's) comes from playback's own reads.
        guard demuxer.canOpenAsFile || hls != nil, let range = demuxer.subtitleWindow(around: time, of: slot) else {
            return nil
        }
        if hls != nil { return (range, nil) }
        let starts = demuxer.indexedSubtitleStarts(of: streamIndex, in: range)
        // Until the index is read, the read that reads it decides.
        if isNetwork, starts == nil, !demuxer.needsSubtitleIndex { return nil }
        return (range, starts)
    }

    /// Reads a track's document off the main thread and shows it if the track is still selected. Selecting the track
    /// again while it is read waits for that read. `isCurrent` says whether the result still belongs to the tracks
    /// listed when it arrives.
    func loadDocument(
        trackId id: Int,
        read: @escaping @Sendable (FFmpegInterrupt) async -> SubtitleDocument?,
        isCurrent: @escaping @MainActor @Sendable (SubtitleController) -> Bool
    ) {
        guard loads[id] == nil else { return }
        let interrupt = FFmpegInterrupt()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let document = await read(interrupt)
            await MainActor.run {
                guard let self else { return }
                if self.loads[id]?.interrupt === interrupt { self.loads[id] = nil }
                guard !interrupt.isCancelled, !Task.isCancelled, isCurrent(self) else { return }
                guard let document else {
                    AppLog.warning(.subtitles, "Can't read subtitle track \(id)")
                    return
                }
                self.loadedDocuments[id] = document
                if let url = self.tracks.first(where: { $0.id == id })?.externalURL, !url.isFileURL {
                    self.remoteDocumentCache[url] = document
                }
                if document.assScript != nil, let index = self.tracks.firstIndex(where: { $0.id == id }),
                    self.tracks[index].format != .ass
                {
                    self.tracks[index] = self.tracks[index].with(format: .ass)
                }
                guard self.selectedTrackId == id else { return }
                self.activeDocument = document
                self.updateShown(at: self.host?.currentTime ?? 0)
            }
        }
        loads[id] = Load(task: task, interrupt: interrupt)
    }

    /// Cancels the background reads of tracks other than `kept`, and the window read of an embedded track, which a
    /// track switch replaces.
    func cancelLoads(except kept: Int? = nil) {
        for (id, load) in loads where id != kept {
            load.cancel()
            loads[id] = nil
        }
        mainReads.cancelWindow()
        secondaryReads.cancelWindow()
    }
}

extension SubtitleController {
    /// How many 100 ms steps a window read of an HLS rendition waits for the pictures to anchor their sequence.
    nonisolated static let anchorWaitSteps = 20
}
