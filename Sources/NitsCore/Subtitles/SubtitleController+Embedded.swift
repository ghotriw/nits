import Foundation

// MARK: - Background reads

extension SubtitleController {
    /// Reads what the selected embedded track misses around `seconds` (playback time; the delay is applied here) from
    /// a secondary demuxer (`MediaDemuxer.subtitleWindow`, `EmbeddedSubtitleReader.readSubtitles`) and adds it to what
    /// playback collects. Called when the track is chosen, a load or seek has landed, and the delay changes, and from
    /// the time tick while a negative delay shows the track ahead of what playback has read; a newer request cancels
    /// the one running. What playback read of the track before it was chosen (`MediaDemuxer.takeStashedSubtitles`) is
    /// merged first, for every source, and the window is what it leaves out.
    func refreshEmbedded(around seconds: Double) {
        guard let host, let demuxer = host.demuxer, let path = host.currentSourcePath,
            let track = tracks.first(where: { $0.id == selectedTrackId }), !track.isExternal
        else { return }
        let selection = demuxer.liveSubtitleSelection
        guard selection.streamIndex >= 0 else { return }
        if let stashed = demuxer.takeStashedSubtitles() {
            let previous = stashMerge
            stashMerge = Task.detached(priority: .utility) { [weak self] in
                await previous?.value
                let decoded = EmbeddedSubtitleReader.decode(stashed.snapshot, captionField: selection.captionField)
                guard
                    demuxer.mergeStashed(
                        decoded, of: stashed.snapshot, selection: stashed.selection, span: stashed.span)
                else { return }
                await MainActor.run {
                    guard let self, let host = self.host, host.demuxer === demuxer else { return }
                    self.updateShown(at: host.currentTime)
                }
            }
        }
        let time = max(0, seconds - delay)
        let isNetwork = demuxer.isNetworkSource
        // Before the stash is merged the window may be larger than it will be, never smaller.
        guard
            Self.subtitleWindow(of: demuxer, around: time, streamIndex: selection.streamIndex, isNetwork: isNetwork)
                != nil
        else { return }

        windowRead?.cancel()
        let headers = host.currentHeaders
        if demuxer.needsSubtitleIndex, indexLoad == nil {
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
        let pendingMerge = stashMerge
        let pendingIndex = indexLoad?.task
        // Below playback's own reads, which refill the buffer after a seek from the same file.
        let task = Task.detached(priority: .utility) { [weak self] in
            await pendingMerge?.value
            await pendingIndex?.value
            guard !Task.isCancelled,
                let (range, starts) = Self.subtitleWindow(
                    of: demuxer, around: time, streamIndex: selection.streamIndex, isNetwork: isNetwork)
            else {
                await MainActor.run {
                    if self?.windowRead?.interrupt === interrupt { self?.windowRead = nil }
                }
                return
            }
            var merged = false
            var failed = false
            if starts?.isEmpty == true {
                merged = demuxer.mergeLiveSubtitles(
                    .init(), covering: range, selection: selection.id, span: selection.span)
            } else if let packets = EmbeddedSubtitleReader.readSubtitles(
                url: path, headers: headers, streamIndex: selection.streamIndex,
                captionField: selection.captionField, in: (starts?.first ?? range.lowerBound)...range.upperBound,
                byteLimit: isNetwork ? EmbeddedSubtitleReader.networkWindowByteLimit : nil, interrupt: interrupt)
            {
                merged = demuxer.mergeLiveSubtitles(
                    packets, covering: range, selection: selection.id, span: selection.span)
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
                if !failed, self.windowRead?.interrupt === interrupt { self.windowRead = nil }
                // Paused, no time tick would show what was read.
                if merged { self.updateShown(at: host.currentTime) }
            }
        }
        windowRead = Load(task: task, interrupt: interrupt)
    }

    /// The window of the selected track to read at `time` (`MediaDemuxer.subtitleWindow`), with the starts of the
    /// track's packets in it by the file's own index (`indexedSubtitleStarts`, `nil` when it doesn't list them or
    /// isn't read yet): a window with none is merged empty, unread, and a read starts at the first. A network source
    /// is read only where the index tells (Matroska Cues, an MP4 sample table), up to `networkWindowByteLimit`:
    /// elsewhere a window would read every stream of the file for seconds, against playback refilling after a seek.
    nonisolated private static func subtitleWindow(
        of demuxer: MediaDemuxer, around time: Double, streamIndex: Int, isNetwork: Bool
    ) -> (range: ClosedRange<Double>, starts: [Double]?)? {
        guard let range = demuxer.subtitleWindow(around: time) else { return nil }
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
        read: @escaping @Sendable (FFmpegInterrupt) -> SubtitleDocument?,
        isCurrent: @escaping @MainActor @Sendable (SubtitleController) -> Bool
    ) {
        guard loads[id] == nil else { return }
        let interrupt = FFmpegInterrupt()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let document = read(interrupt)
            await MainActor.run {
                guard let self else { return }
                if self.loads[id]?.interrupt === interrupt { self.loads[id] = nil }
                guard !interrupt.isCancelled, isCurrent(self) else { return }
                guard let document else {
                    AppLog.warning(.subtitles, "Can't read subtitle track \(id)")
                    return
                }
                self.loadedDocuments[id] = document
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
        windowRead?.cancel()
        windowRead = nil
    }
}
