import Foundation
import os

/// A DASH manifest (MPD) told to the client as HLS playlists (`PlaylistSource`): its pictures as the variants of a
/// multivariant playlist, the best sound of each language as an audio rendition, each representation's segments as a media
/// playlist. The client plays them as it plays HLS's (`StreamingInput`); see `.agents/dash-client/PLAN.md`.
///
/// **Addresses.** The playlists are named by keys of the source's own (`nits-dash://<source>/…`), never fetched: the
/// manifest (inline, from a site's extractor, or at `address`) is read once and every playlist is answered from it. What the
/// keys stand for stays here, so no lane's address carries a manifest.
///
/// **One file.** A representation that is one MP4 file (`SegmentBase`) has its segments told by its index (`sidx`),
/// read when its playlist is first asked for (the opening asks for every rung's side by side), once for every caller,
/// as the manifest is. An index it cannot read refuses that representation with the reason; one that does not load is
/// a failure of its playlist, as a playlist's load is.
///
/// **Numbers.** An ordinary switch between variants is by time (`StreamingLane.catchUp`). A download given up is taken
/// over by the same segment number of the new variant (`StreamingInput.joinSegment`), which HLS promises a ladder and
/// DASH does not (`startNumber`, timelines per representation, each resolution in a set of its own). So the pictures
/// that may switch with each other (one codec and range, as `StreamingInput.ladder(of:)` groups them) are numbered by
/// time, from the segments of the best of them. A picture whose segments do not start where the best one's do (within
/// half a frame) stays in the ladder with numbers of its own (`MediaPlaylist.hasOwnNumbers`): a switch by time lands on
/// the first segment after the position whatever its boundaries, the demuxer cuts at a keyframe, and a download given up
/// is taken over to or from it by the segment that starts at the same time (DASH's durations are exact), and only where
/// the boundaries meet (`JoinRefusal.noBoundary` elsewhere). For one file that is known once both indexes are read.
///
/// A `static` manifest of several periods plays as one timeline, each period a discontinuity; what is not played yet is refused (`PlaylistSourceError.unsupported`) with
/// the reason.
package struct DASHPlaylists: PlaylistSource {
    /// The scheme of the keys.
    static let scheme = "nits-dash"

    /// The key of the multivariant playlist: what `StreamingInput` opens.
    let multivariantURL: URL
    /// Where the manifest came from (after redirects; an inline one tells none): its relative addresses are
    /// relative to it, and the requests' headers are scoped by it.
    package let address: URL
    /// What of the manifest is played, as the address told (`DASHSelection`).
    let selection: DASHSelection
    private let id: String
    let inline: Data?
    private let manifest = Store<Built>()
    /// The host's clock (replaced in tests): a live manifest's edge is read off it, with the server's offset.
    let clock: @Sendable () -> Date
    /// What a live manifest keeps between asks (`DASHLive.swift`).
    let live = LiveState()
    /// How many callers wait for a read of the manifest another one is making (tests).
    var waitingReaders: Int { manifest.waiting }
    /// Why the stream was refused (`PlaylistSourceError.unsupported`): what the client does not play yet, which may
    /// be opened otherwise. The manifest's refusal, or that of the index of a picture or sound the stream is not played
    /// without (`Entry.isEssential`), which the opening may have gone on without (the default sound's): asked after an
    /// opening that succeeded too. Nil before a read, after one that played or failed otherwise.
    var refusal: String? {
        if let reason = manifest.refusal { return reason }
        guard let built = manifest.current else { return nil }
        return built.entries.lazy.filter(\.isEssential).compactMap { $0.index?.refusal }.first
    }

    /// Its segments may be local files: a manifest read from a file.
    package let allowsFiles: Bool
    /// A live stream's history, when the manifest is one (`DASHHistory`): its playlists list up to the head.
    let history: DASHHistory?
    /// What a manifest of keys (`StreamAddresses`) is given its files' signed addresses by; nil: its addresses are real.
    let addresses: (any StreamAddressSource)?

    /// The manifest at `address` (or `inline`, a copy of it), playing what `selection` names.
    package init(
        address: URL, inline: Data? = nil, selection: DASHSelection = DASHSelection(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let id = UUID().uuidString.lowercased()
        self.init(id: id, address: address, inline: inline, selection: selection, clock: clock)
    }

    /// An inline manifest whose address is not told (one built from what a site lists): its addresses are absolute, and
    /// the relative ones fail, as relative to the multivariant's key.
    package init(inline: Data) {
        let id = UUID().uuidString.lowercased()
        self.init(id: id, address: URL(string: "\(Self.scheme)://\(id)/")!, inline: inline, clock: { Date() })
    }

    private init(
        id: String, address: URL, inline: Data?, selection: DASHSelection = DASHSelection(),
        clock: @escaping @Sendable () -> Date, history: DASHHistory? = nil,
        addresses: (any StreamAddressSource)? = nil
    ) {
        self.clock = clock
        self.history = history
        self.addresses = addresses
        self.selection = selection
        self.id = id
        self.address = address
        self.inline = inline
        multivariantURL = URL(string: "\(Self.scheme)://\(id)/")!
        allowsFiles = inline == nil && address.isFileURL
    }

    /// The manifest a demuxer is asked to open at `path`: an inline one (`StreamingURL.inlineDASHManifest`), or one at an
    /// address whose name ends in `.mpd` (a file's or the network's; Unified Streaming's is `…/.mpd`). Nil for any other,
    /// unless `assumingManifest`: the address was found to serve a manifest by its bytes (`SniffedPlaylist`), whatever
    /// its name.
    package init?(
        media path: String, history liveHistory: StreamHistory? = nil, addresses: (any StreamAddressSource)? = nil,
        assumingManifest: Bool = false
    ) {
        if let inline = StreamingURL.inlineDASHManifestContents(path) {
            let clock: @Sendable () -> Date = { Date() }
            let history = liveHistory?.source.map {
                DASHHistory(source: $0, head: liveHistory?.headNumber ?? 0, clock: clock)
            }
            let id = UUID().uuidString.lowercased()
            self.init(
                id: id, address: URL(string: "\(Self.scheme)://\(id)/")!, inline: inline,
                selection: DASHSelection(fragment: StreamingURL.inlineDASHManifestFragment(path)), clock: clock,
                history: history, addresses: addresses)
            return
        }
        // A history is a manifest of keys the resolver made, never an address.
        guard liveHistory == nil else { return nil }
        let normalized = StreamingURL.normalizeMediaPath(path)
        let isNetwork = StreamingURL.isNetworkURL(normalized)
        guard var address = isNetwork ? URL(string: normalized) : URL(fileURLWithPath: normalized),
            assumingManifest || address.lastPathComponent.lowercased().hasSuffix(".mpd")
        else { return nil }
        // `HTTPS://`: the client's requests know a network address by its scheme in lower case. The fragment is the
        // choice (`DASHSelection`), not a part of the address the requests go to.
        var selection = DASHSelection()
        if isNetwork, var components = URLComponents(url: address, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme?.lowercased()
            selection = DASHSelection(fragment: components.percentEncodedFragment)
            components.fragment = nil
            address = components.url ?? address
        }
        self.init(address: address, selection: selection)
    }

    /// The client's input for this manifest, or nil with the reason recorded on `interrupt` (the opening's error). An
    /// opening that went on without what the stream is not played without (the default sound, whose index the source
    /// refused) is refused too: not played silent. Asked of the source itself, not read off the interrupt's last error,
    /// which another failure (or an earlier attempt on the same context) may have written.
    package func makeInput(headers: [String: String], interrupt: FFmpegInterrupt) -> StreamingInput? {
        let input = StreamingInput(
            multivariant: multivariantURL, playlists: self, source: address.absoluteString, allowsFiles: allowsFiles,
            headers: headers, interrupt: interrupt, streamingName: "DASH")
        guard let input else { return nil }
        guard let refusal else { return input }
        input.close()
        interrupt.recordError(
            code: PlaylistSourceError.unsupported(refusal).code,
            message: "DASH: not played by the client: \(refusal)")
        return nil
    }

    package func playlist(at url: URL, variables: [String: String], loader: SegmentLoader)
        throws(PlaylistSourceError)
        -> StreamingPlaylist
    {
        guard url.scheme == Self.scheme, url.host == id else { throw .load(.notServed(url, reason: .unknownAddress)) }
        let built = try manifest.value(loader: loader) { loader throws(PlaylistSourceError) in
            try read(loader: loader)
        }
        if url.path.isEmpty || url.path == "/" {
            if let multivariant = built.multivariant { return .multivariant(multivariant) }
            return .media(try mediaPlaylist(0, of: built, loader: loader))
        }
        guard let index = url.pathComponents.dropFirst().first.flatMap({ Int($0) }),
            built.entries.indices.contains(index)
        else { throw .load(.notServed(url, reason: .unknownAddress)) }
        return .media(try mediaPlaylist(index, of: built, loader: loader))
    }

    /// A live stream's history names its segments by key and number; the signed address is the source's, as it is now.
    package func address(of url: URL) -> URL? {
        if let addresses, let key = StreamAddresses.key(of: url) { return addresses.address(forKey: key) }
        guard let history, let segment = StreamHistory.segment(named: url) else { return url }
        return history.source.url(for: segment.key, number: segment.number)
    }

    package func renewAddresses(shouldAbort: () -> Bool) -> Bool {
        if let addresses { return addresses.renewAddresses(shouldAbort: shouldAbort) }
        return history?.source.renewSignature(shouldAbort: shouldAbort) ?? false
    }

    /// The entry `url` names is the default sound (`Entry.isEssential`), which has no other to stand in for it. Not a
    /// picture: another rung plays in its place, and a refused index of the one the others are numbered on is
    /// `refusal`'s already.
    package func isEssential(_ url: URL) -> Bool {
        guard url.scheme == Self.scheme, url.host == id, let built = manifest.current,
            let index = url.pathComponents.dropFirst().first.flatMap({ Int($0) }),
            built.entries.indices.contains(index)
        else { return false }
        let entry = built.entries[index]
        return entry.isEssential && entry.representation.kind == .audio
    }

    private func read(loader: SegmentLoader) throws(PlaylistSourceError) -> Built {
        let data: Data
        let servedFrom: URL
        if let inline {
            (data, servedFrom) = (inline, address)
        } else {
            do {
                (data, servedFrom) = try loader.playlist(address)
            } catch {
                throw .load(error)
            }
        }
        var presentation = try self.presentation(data, servedFrom: servedFrom, now: clock())
        if let timing = presentation.live {
            // The server's clock, once; the manifest read now is the first of the fetches the reloads go on from.
            let offset = try clockOffset(of: timing.timings, loader: loader)
            live.begin(
                Fetched(data: data, servedFrom: servedFrom, at: clock(), generation: 0), offset: offset,
                updatePeriod: inline == nil ? timing.minimumUpdatePeriod : nil, location: timing.location,
                periodStart: timing.periodStart)
            if offset != 0 {
                presentation = try self.presentation(
                    data, servedFrom: servedFrom, now: clock().addingTimeInterval(offset))
            }
        }
        return try DASHPlaylists.build(presentation, id: id, selection: selection)
    }

    // MARK: - Building

    /// The playlists of a presentation: the multivariant (nil with no picture: the stream is the one sound's playlist, the
    /// first entry's), and an entry for each representation played, at its index in the keys.
    package struct Built: Sendable {
        var multivariant: MultivariantPlaylist?
        var entries: [Entry]
        /// The period's length, when told: the segments an index lists end with it.
        var periodDuration: Double?
        /// The manifest is dynamic: its playlists are listed at the clock of each ask (`livePlaylist`), none built here.
        var isLive = false
        /// The playlists told by the manifest alone, at their index; nil for one file, told by its index once read.
        var media: [MediaPlaylist?] { entries.map(\.playlist) }
    }

    /// A representation played.
    package struct Entry: Sendable {
        var representation: DASHPresentation.Representation
        var numbering: Numbering
        /// Its playlist, when the manifest tells its segments.
        var playlist: MediaPlaylist?
        /// The read of its index, for one file (`DASHPresentation.Representation.index`).
        var index: Store<[DASHPresentation.Segment]>?
        /// Its playlist built from the index once (or why it is refused), for one file.
        var indexed: Store<MediaPlaylist>?
        /// The stream is not played without it: a picture numbered as its manifest says (a ladder's best, one alone), the
        /// default sound. A rung of the ladder or another language is left out instead.
        var isEssential: Bool
    }

    /// The numbers an entry's segments take.
    package enum Numbering: Sendable, Equatable {
        /// As its manifest says.
        case own
        /// Those of the ladder's best picture, known with the manifest.
        case ladder([Int])
        /// Those of the ladder's best picture, the entry at `reference`, for one of them whose segments an index tells.
        case on(reference: Int, tolerance: Double)
        /// As its manifest says, for a picture of a ladder whose segments do not start where the best picture's do: it
        /// plays in the ladder, but its numbers are no place in the others' (`MediaPlaylist.hasOwnNumbers`: its timeline is
        /// not placed by them).
        case offGrid
    }

    /// The numbers a picture's segments take, as `numberedPictures` tells them: the reference by itself.
    package enum PictureNumbering: Sendable, Equatable {
        case own
        case ladder([Int])
        case on(DASHPresentation.Representation, tolerance: Double)
        case offGrid
    }

    /// One representation of the manifest: its id and its set.
    static func isSame(_ a: DASHPresentation.Representation, _ b: DASHPresentation.Representation) -> Bool {
        a.id == b.id && a.set == b.set
    }

    /// How far apart two segments' starts may be and still be one boundary, with no frame rate told.
    static let boundaryTolerance = 0.01

    /// The pictures a choice plays: the one named and those that switch with it (one codec, supplemental codec and
    /// range, each with a bitrate told; a ladder of two or more), else it alone. All of them without a choice.
    static func pictures(
        of videos: [DASHPresentation.Representation], selection: DASHSelection
    ) throws(PlaylistSourceError) -> [DASHPresentation.Representation] {
        guard let id = selection.video else {
            // The manifest as it is, but one container: the ladder is built from the pictures' codecs, which a WebM and an
            // MP4 share, and its rungs must not switch across containers (the best picture's is kept).
            guard let best = videos.max(by: { $0.bandwidth < $1.bandwidth }) else { return videos }
            return videos.filter { $0.isWebM == best.isWebM }
        }
        guard let chosen = videos.first(where: { $0.id == id }) else {
            throw .unsupported("the picture '\(id)' the address names is not in the manifest")
        }
        let family = { (video: DASHPresentation.Representation) in
            [video.codecs.flatMap(CodecFamily.video(in:)), video.supplementalCodecs.flatMap(CodecFamily.video(in:))]
        }
        let rungs = videos.filter {
            family($0) == family(chosen) && $0.videoRange == chosen.videoRange && $0.isWebM == chosen.isWebM
                && $0.bandwidth > 0
        }
        return chosen.bandwidth > 0 && rungs.count > 1 ? rungs : [chosen]
    }

    static func build(
        _ presentation: DASHPresentation, id: String, selection: DASHSelection = DASHSelection()
    ) throws(PlaylistSourceError) -> Built {
        var videos = presentation.representations.filter { $0.kind == .video }
        var sounds = bestSounds(
            presentation.representations.filter { $0.kind == .audio },
            order: selection.audioCodecs.isEmpty ? CodecFamily.audioFamilies : selection.audioCodecs)
        if let audio = selection.audio {
            // A sound alone: the manifest's other streams are the picture's file, or another sound's.
            guard let chosen = presentation.representations.first(where: { $0.kind == .audio && $0.id == audio })
            else { throw .unsupported("the sound '\(audio)' the address names is not in the manifest") }
            (videos, sounds) = ([], [chosen])
        } else {
            videos = try pictures(of: videos, selection: selection)
        }
        let isLive = presentation.live != nil
        let pictures = numberedPictures(videos, isLive: isLive)
        let played = pictures.map(\.representation) + sounds
        guard !played.isEmpty else { throw .unsupported("no picture or sound it can play") }
        if let first = played.first,
            let other = played.first(where: { abs($0.presentationTimeOffset - first.presentationTimeOffset) > 0.001 })
        {
            throw .unsupported(
                "presentation time offsets that differ (\(first.id): \(first.presentationTimeOffset) s, "
                    + "\(other.id): \(other.presentationTimeOffset) s)")
        }

        var entries: [Entry] = []
        func entry(
            _ representation: DASHPresentation.Representation, numbering: Numbering, isEssential: Bool
        ) -> Entry {
            let numbers: [Int]? = if case .ladder(let numbers) = numbering { numbers } else { nil }
            let isOneFile = representation.index != nil
            return Entry(
                representation: representation, numbering: numbering,
                playlist: isOneFile || isLive
                    ? nil : mediaPlaylist(representation, numbers: numbers, hasOwnNumbers: numbering == .offGrid),
                index: isOneFile ? Store() : nil, indexed: isOneFile ? Store() : nil, isEssential: isEssential)
        }
        func key(_ representation: DASHPresentation.Representation) -> URL {
            let escaped =
                representation.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
                ?? ""
            return URL(string: "\(scheme)://\(id)/\(entries.count)/\(escaped)")!
        }

        if pictures.isEmpty, let sound = sounds.first {
            // Sound alone: its playlist is the stream (the other languages wait for the multivariant to carry them).
            return Built(
                multivariant: nil, entries: [entry(sound, numbering: .own, isEssential: true)],
                periodDuration: presentation.periodDuration, isLive: isLive)
        }
        var multivariant = MultivariantPlaylist()
        multivariant.hasIndependentSegments = true
        for sound in sounds {
            let url = key(sound)
            entries.append(entry(sound, numbering: .own, isEssential: multivariant.renditions.isEmpty))
            multivariant.renditions.append(
                PlaylistRendition(
                    type: .audio, groupID: "a", name: sound.language ?? "audio \(multivariant.renditions.count + 1)",
                    url: url,
                    language: sound.language, isDefault: multivariant.renditions.isEmpty, autoselect: true))
        }
        // A picture numbered on another's is told the entry of that one: the pictures' entries follow the sounds' in
        // their order.
        let firstPicture = entries.count
        for picture in pictures {
            let representation = picture.representation
            let numbering: Numbering
            switch picture.numbering {
            case .own: numbering = .own
            case .ladder(let numbers): numbering = .ladder(numbers)
            case .offGrid: numbering = .offGrid
            case .on(let reference, let tolerance):
                guard let position = pictures.firstIndex(where: { Self.isSame($0.representation, reference) }) else {
                    StreamingLog.warning("DASH: \(representation.id) is left out: its ladder's best is not played")
                    continue
                }
                numbering = .on(reference: firstPicture + position, tolerance: tolerance)
            }
            let url = key(representation)
            let isEssential = if case .own = numbering { true } else { false }
            entries.append(entry(representation, numbering: numbering, isEssential: isEssential))
            multivariant.variants.append(
                PlaylistVariant(
                    url: url, bandwidth: representation.bandwidth, codecs: representation.codecs,
                    supplementalCodecs: representation.supplementalCodecs,
                    resolution: representation.width.flatMap { width in
                        representation.height.map { VideoResolution(width: width, height: $0) }
                    },
                    frameRate: representation.frameRate, videoRange: representation.videoRange,
                    audioGroup: sounds.isEmpty ? nil : "a"))
        }
        return Built(
            multivariant: multivariant, entries: entries, periodDuration: presentation.periodDuration, isLive: isLive)
    }

    /// Segments as a finished media playlist; `numbers`: those the ladder gave them, else their own. A segment's size,
    /// when it is a byte range, is its range's: no `bitrate` (`EXT-X-BITRATE` is for segments without one).
    static func mediaPlaylist(
        _ representation: DASHPresentation.Representation, segments: [DASHPresentation.Segment]? = nil,
        numbers: [Int]?, hasOwnNumbers: Bool = false
    ) -> MediaPlaylist {
        let segments = segments ?? representation.segments
        var playlist = MediaPlaylist(targetDuration: (segments.map(\.duration).max() ?? 0).rounded(.up))
        playlist.hasOwnNumbers = hasOwnNumbers
        playlist.type = .vod
        playlist.hasEnded = true
        playlist.hasIndependentSegments = true
        playlist.segments = segments.enumerated().map { index, segment in
            MediaSegment(
                url: segment.url, duration: segment.duration, sequence: numbers?[index] ?? segment.number,
                discontinuitySequence: segment.period, byteRange: segment.byteRange,
                initSection: segment.isGap ? nil : segment.initSection ?? representation.initSection,
                isGap: segment.isGap)
        }
        playlist.mediaSequence = playlist.segments.first?.sequence ?? 0
        return playlist
    }

    /// The playlist of the entry at `index`: told by the manifest, or by the index of its file, read now if no caller
    /// has (and the index of the picture it is numbered on), and built once.
    private func mediaPlaylist(
        _ index: Int, of built: Built, loader: SegmentLoader
    ) throws(PlaylistSourceError) -> MediaPlaylist {
        if built.isLive { return try livePlaylist(index, of: built, loader: loader) }
        let entry = built.entries[index]
        if let history, let playlist = entry.playlist {
            return history.listing(of: playlist, shouldAbort: { loader.isAborted })
        }
        if let playlist = entry.playlist { return playlist }
        guard let indexed = entry.indexed else { throw .load(.notServed(multivariantURL, reason: .noSegments)) }
        return try indexed.value(loader: loader) { loader throws(PlaylistSourceError) in
            try Self.indexedPlaylist(of: entry, in: built, loader: loader)
        }
    }

    private static func indexedPlaylist(
        of entry: Entry, in built: Built, loader: SegmentLoader
    ) throws(PlaylistSourceError) -> MediaPlaylist {
        let segments = try Self.segments(of: entry, periodDuration: built.periodDuration, loader: loader)
        var numbers: [Int]?
        var hasOwnNumbers = false
        switch entry.numbering {
        case .own: break
        case .offGrid: hasOwnNumbers = true
        case .ladder(let ladder): numbers = ladder
        case .on(let referenceIndex, let tolerance):
            let reference = built.entries[referenceIndex]
            let referenceSegments = try Self.segments(
                of: reference, periodDuration: built.periodDuration, loader: loader)
            if let matched = Self.numbers(of: segments, on: referenceSegments, tolerance: tolerance) {
                numbers = matched
            } else {
                let video = entry.representation
                StreamingLog.warning(
                    "DASH: \(video.id) (\(video.bandwidth) bit/s) is numbered on its own: its index's segments do "
                        + "not start where \(reference.representation.id)'s do")
                hasOwnNumbers = true
            }
        }
        return Self.mediaPlaylist(
            entry.representation, segments: segments, numbers: numbers, hasOwnNumbers: hasOwnNumbers)
    }

    /// The segments of `entry`: the manifest's, or those of its file's index, read once for every caller.
    private static func segments(
        of entry: Entry, periodDuration: Double?, loader: SegmentLoader
    ) throws(PlaylistSourceError) -> [DASHPresentation.Segment] {
        guard let store = entry.index, let location = entry.representation.index else {
            return entry.representation.segments
        }
        let representation = entry.representation
        return try store.value(loader: loader) { loader throws(PlaylistSourceError) in
            var location = location
            var found: Located?
            if location.range == nil {
                // The manifest tells no index range: the file's start does (`SingleFileLayout`).
                let located = try locate(location, loader: loader)
                location.range = located.index
                found = located
            }
            let initSection = representation.initSection ?? found?.initSection
            let index = try readIndex(
                location, initSection: initSection, prefix: found?.prefix ?? Data(), loader: loader)
            // A switch or a seek lands on a segment's start: a picture's must be a keyframe. A sound's index may leave
            // it unsaid.
            if representation.kind == .video && !index.startsWithSAP {
                throw .unsupported("an index whose segments do not all start with a keyframe")
            }
            var segments = DASHPresentation.segments(
                from: index, of: representation, periodDuration: periodDuration)
            guard !segments.isEmpty else { throw .unsupported("an index of no segments in the period") }
            // The initialization the start told is the segments' (the representation tells none).
            if representation.initSection == nil, let initSection {
                for position in segments.indices { segments[position].initSection = initSection }
            }
            return segments
        }
    }

    /// What the start of a file told of it (`locate`): its initialization, its index, and the bytes read to find them.
    private struct Located {
        var initSection: InitSection
        var index: ByteRange
        /// The file's first bytes, the initialization and often the index among them (they are not asked for again).
        var prefix: Data
    }

    /// The initialization and the index of a file whose manifest tells where neither is: its first bytes, as many as the
    /// walk of its boxes needs (`SingleFileLayout.firstRead` to begin), then the index when it was not among them.
    /// Init and index are adjacent in the files of this profile: one request reads both.
    private static func locate(
        _ location: DASHPresentation.IndexLocation, loader: SegmentLoader
    ) throws(PlaylistSourceError) -> Located {
        var prefix = Data()
        var length = SingleFileLayout.firstRead
        var found: SingleFileLayout.Found?
        var rounds = 0
        while found == nil {
            rounds += 1
            guard rounds <= 8 else { throw .unsupported("a file whose start does not tell where its index is") }
            // The part not read yet; a file shorter than asked for answers with fewer bytes.
            let more = try indexBytes(
                of: location, offset: Int64(prefix.count), length: length - Int64(prefix.count), loader: loader)
            guard !more.isEmpty else { throw .unsupported("a file that ends before its index") }
            prefix += more
            let reading: SingleFileLayout.Reading
            do throws(SegmentIndex.Failure) {
                reading =
                    location.format == .webm
                    ? try MatroskaCues.locate(in: prefix) : try SegmentIndex.locate(in: prefix)
            } catch {
                throw Self.refusal(error)
            }
            switch reading {
            case .found(let layout):
                found = layout
            case .needsStart(let upTo):
                guard upTo <= SingleFileLayout.startLimit else {
                    throw .unsupported("a start of more than \(SingleFileLayout.startLimit) bytes")
                }
                length = min(max(upTo, Int64(prefix.count) * 2), SingleFileLayout.startLimit)
                guard length > Int64(prefix.count) else {
                    throw .unsupported("a start of more than \(SingleFileLayout.startLimit) bytes")
                }
            case .needsCuesHeader(let offset, let initEnd):
                let header = try indexBytes(of: location, offset: offset, length: 16, loader: loader)
                do throws(SegmentIndex.Failure) {
                    found = try MatroskaCues.cues(atHeader: header, offset: offset, initEnd: initEnd)
                } catch {
                    throw Self.refusal(error)
                }
            }
        }
        guard let layout = found else { throw .unsupported("a file whose start does not tell where its index is") }
        guard layout.initialization.length <= Int64(prefix.count) else {
            throw .unsupported(
                "an initialization of \(layout.initialization.length) bytes past the \(prefix.count) read")
        }
        guard layout.index.length <= SegmentIndex.sizeLimit else {
            throw .unsupported("an index of more than \(SegmentIndex.sizeLimit) bytes")
        }
        // The index follows the bytes read (or begins inside them): the rest of it comes with one request.
        if layout.index.offset <= Int64(prefix.count), layout.index.range.upperBound > Int64(prefix.count) {
            prefix += try indexBytes(
                of: location, offset: Int64(prefix.count),
                length: layout.index.range.upperBound - Int64(prefix.count), loader: loader)
        }
        let section = InitSection(url: location.media, byteRange: layout.initialization)
        loader.keep(section, data: prefix.prefix(Int(layout.initialization.length)))
        return Located(initSection: section, index: layout.index, prefix: prefix)
    }

    /// `length` bytes of the index's file from `offset`, from `prefix` (the file's start already read) when they are in it.
    private static func indexBytes(
        of location: DASHPresentation.IndexLocation, offset: Int64, length: Int64, loader: SegmentLoader,
        prefix: Data = Data()
    ) throws(PlaylistSourceError) -> Data {
        guard let range = ByteRange(offset: offset, length: length) else {
            throw .unsupported("an index past the end of what a file holds")
        }
        if !location.isExternal, range.range.upperBound <= Int64(prefix.count) {
            return prefix.subdata(in: Int(range.offset)..<Int(range.range.upperBound))
        }
        do {
            return try loader.bytes(of: location.url, range: range)
        } catch {
            throw .load(error)
        }
    }

    private static func refusal(_ error: SegmentIndex.Failure) -> PlaylistSourceError {
        switch error {
        case .unreadable(let reason): .unsupported("an index it cannot read: \(reason)")
        }
    }

    /// The index of a WebM file: its `Cues` (the index range), read with the file's start (`initSection`, from its first
    /// byte), which tells where the Segment's data is, from where the cues' positions count.
    private static func readCues(
        _ location: DASHPresentation.IndexLocation, range: ByteRange, initSection: InitSection?, prefix: Data,
        loader: SegmentLoader
    ) throws(PlaylistSourceError) -> SegmentIndex {
        guard let initSection else { throw .unsupported("a WebM file without its initialization") }
        let cues = try indexBytes(
            of: location, offset: range.offset, length: range.length, loader: loader, prefix: prefix)
        let header: Data
        do { header = try loader.initSection(initSection) } catch { throw .load(error) }
        do throws(SegmentIndex.Failure) {
            return try MatroskaCues.read(
                header: header, cues: cues, cuesOffset: location.isExternal ? nil : range.offset)
        } catch {
            throw refusal(error)
        }
    }

    /// The index at `location`: its range, then each box a reference points to outside the bytes read, as many as
    /// `SegmentIndex.requestLimit` allows and `SegmentIndex.sizeLimit` bytes in all.
    static func readIndex(
        _ location: DASHPresentation.IndexLocation, initSection: InitSection?, prefix: Data = Data(),
        loader: SegmentLoader
    ) throws(PlaylistSourceError) -> SegmentIndex {
        guard let range = location.range else { throw .unsupported("one file without an index range") }
        if location.format == .webm {
            return try readCues(
                location, range: range, initSection: initSection, prefix: prefix, loader: loader)
        }
        func bytes(_ offset: Int64, _ length: Int64) throws(PlaylistSourceError) -> Data {
            try indexBytes(of: location, offset: offset, length: length, loader: loader, prefix: prefix)
        }
        var chunks = [(offset: range.offset, data: try bytes(range.offset, range.length))]
        var total = Int64(chunks[0].data.count)
        var asked: Set<Int64> = []
        while true {
            let reading: SegmentIndex.Reading
            do throws(SegmentIndex.Failure) {
                reading = try SegmentIndex.read(chunks, external: location.isExternal)
            } catch {
                throw Self.refusal(error)
            }
            switch reading {
            case .index(let index): return index
            case .needs(let offset, let length):
                // Asked for once: bytes that hold no box there are no index.
                guard asked.insert(offset).inserted else { throw .unsupported("an index that points to no sidx") }
                guard asked.count <= SegmentIndex.requestLimit else {
                    throw .unsupported("an index of more than \(SegmentIndex.requestLimit) parts past its range")
                }
                var data = try bytes(offset, length)
                // A box larger than the probe: the rest of it.
                if let size = SegmentIndex.boxSize(in: data), total + size <= SegmentIndex.sizeLimit {
                    data += try bytes(offset + Int64(data.count), size - Int64(data.count))
                }
                total += Int64(data.count)
                guard total <= SegmentIndex.sizeLimit else {
                    throw .unsupported("an index of more than \(SegmentIndex.sizeLimit) bytes")
                }
                chunks.append((offset, data))
            }
        }
    }

    /// The best sound of each language, the main one's first: the main track over one without a role over a commentary
    /// or a description, then a codec told to be decoded over one not told, then more channels (one that tells none counts as stereo),
    /// then the codec `order` prefers (a
    /// bitrate says nothing of the quality across codecs: Opus at 116 kbit/s is no worse than AAC at 129), then the higher
    /// bitrate. Sounds the build cannot decode (AC-4, MPEG-H) are left out.
    static func bestSounds(
        _ sounds: [DASHPresentation.Representation], order: [String] = CodecFamily.audioFamilies
    ) -> [DASHPresentation.Representation] {
        var best: [String: (sound: DASHPresentation.Representation, rank: [Int])] = [:]
        var languages: [String] = []
        for sound in sounds {
            let decodable = sound.codecs.flatMap(CodecFamily.canDecodeAudio(in:))
            guard decodable != false else { continue }
            let rank = [
                sound.roleRank, decodable == true ? 1 : 0, sound.channels == 0 ? 2 : sound.channels,
                -CodecFamily.audioRank(of: sound.codecs, in: order),
                sound.bandwidth,
            ]
            let language = sound.language ?? ""
            if let held = best[language] {
                if held.rank.lexicographicallyPrecedes(rank) { best[language] = (sound, rank) }
            } else {
                best[language] = (sound, rank)
                languages.append(language)
            }
        }
        let ordered = languages.compactMap { best[$0] }
        return ordered.filter { $0.sound.roleRank == 2 }.map(\.sound)
            + ordered.filter { $0.sound.roleRank != 2 }.map(\.sound)
    }

    /// The pictures that are played, each with the numbers of its segments: in each group that switches together (codec,
    /// Dolby Vision's supplemental codec, range) those of the best picture (the highest bitrate), for the pictures whose
    /// segments start where its own do. The others of the group are `.offGrid`: played, numbered as their manifest says,
    /// and taken over from only where their boundaries meet (`StreamingInput.joinSegment`). `.own`: the best picture, or one alone in its group, numbered as its
    /// manifest says. `.on`: a picture or its reference is one file, whose segments are told
    /// once its index is read (`mediaPlaylist(_:of:loader:)`).
    static func numberedPictures(
        _ videos: [DASHPresentation.Representation], isLive: Bool = false
    ) -> [(representation: DASHPresentation.Representation, numbering: PictureNumbering)] {
        struct Group: Hashable {
            var codec: String?
            var supplemental: String?
            var range: VideoRange?
        }
        // `StreamingInput.ladder(of:)` keeps every variant as one ladder when one of those with a picture (a size or a picture's
        // codec told; all, when none is) tells no codec it knows: then all the pictures are numbered as one group, or a
        // ladder would join variants numbered apart.
        let knowsCodec = { (video: DASHPresentation.Representation) in
            video.codecs.flatMap(CodecFamily.video(in:)) != nil
        }
        let withPicture = videos.filter { ($0.width != nil && $0.height != nil) || knowsCodec($0) }
        let isOneLadder = (withPicture.isEmpty ? videos : withPicture).contains { !knowsCodec($0) }
        func group(of video: DASHPresentation.Representation) -> Group {
            guard !isOneLadder else { return Group() }
            return Group(
                codec: video.codecs.flatMap(CodecFamily.video(in:)),
                supplemental: video.supplementalCodecs.flatMap(CodecFamily.video(in:)), range: video.videoRange)
        }
        var references: [Group: DASHPresentation.Representation] = [:]
        for (key, members) in Dictionary(grouping: videos, by: group(of:)) where members.count > 1 {
            references[key] = members.max { $0.bandwidth < $1.bandwidth }
        }
        var result: [(DASHPresentation.Representation, PictureNumbering)] = []
        for video in videos {
            guard let reference = references[group(of: video)], !isSame(video, reference) else {
                result.append((video, .own))
                continue
            }
            let tolerance = reference.frameRate.map { 0.5 / max($0, 1) } ?? boundaryTolerance
            if isLive {
                // Numbered by time at each listing (`livePlaylist`); a picture whose boundaries are not the best one's
                // where the windows overlap is numbered on its own.
                guard
                    numbers(
                        of: video.segments, byTimeOn: reference.segments, numbers: reference.segments.map(\.number),
                        tolerance: tolerance, isStrict: true) != nil
                else {
                    StreamingLog.warning(
                        "DASH: \(video.id) (\(video.bandwidth) bit/s) is numbered on its own: its segments do not "
                            + "start where \(reference.id)'s do")
                    result.append((video, .offGrid))
                    continue
                }
                result.append((video, .on(reference, tolerance: tolerance)))
                continue
            }
            if video.index != nil || reference.index != nil {
                result.append((video, .on(reference, tolerance: tolerance)))
                continue
            }
            guard let numbers = numbers(of: video.segments, on: reference.segments, tolerance: tolerance) else {
                StreamingLog.warning(
                    "DASH: \(video.id) (\(video.bandwidth) bit/s) is numbered on its own: its segments do not start "
                        + "where \(reference.id)'s do")
                result.append((video, .offGrid))
                continue
            }
            result.append((video, .ladder(numbers)))
        }
        return result
    }

    /// The numbers `segments` take from `reference`'s: the same count, each starting where the reference's of the same
    /// place does (within `tolerance` seconds). Nil when they don't.
    static func numbers(
        of segments: [DASHPresentation.Segment], on reference: [DASHPresentation.Segment], tolerance: Double
    ) -> [Int]? {
        guard segments.count == reference.count else { return nil }
        var numbers: [Int] = []
        numbers.reserveCapacity(segments.count)
        for (own, theirs) in zip(segments, reference) {
            guard abs(own.start - theirs.start) <= tolerance else { return nil }
            numbers.append(theirs.number)
        }
        return numbers
    }
}

extension DASHPlaylists {
    /// A value read once for every caller (the manifest, a file's index): the opening's side-by-side requests and the
    /// lanes ask for it at once. The read is made by the first caller that needs it, through its own loader; the others
    /// wait for it (in steps, each giving way to its own abort). A read that gave way to its caller's abort is no answer:
    /// those waiting for it read again themselves. A real failure is the answer of those that waited for it.
    package final class Store<Value: Sendable>: @unchecked Sendable {
        private struct State {
            var value: Value?
            /// The read going on, by its number.
            var reading: Int?
            var reads = 0
            var failure: (read: Int, error: PlaylistSourceError)?
            var waiting = 0
        }
        private enum Step {
            case done(Value)
            case failed(PlaylistSourceError)
            case read(Int)
            case wait(Int)
        }
        private let state: OSAllocatedUnfairLock<State>
        private let changed = DispatchSemaphore(value: 0)
        /// How often a waiter checks its abort.
        static var waitStep: DispatchTimeInterval { .milliseconds(50) }

        var waiting: Int { state.withLock { $0.waiting } }

        /// The value, once read.
        var current: Value? { state.withLock { $0.value } }

        package init() {
            state = OSAllocatedUnfairLock(initialState: State())
        }

        /// A store whose value is already known (what the caller that opened the stream read).
        package init(value: Value) {
            state = OSAllocatedUnfairLock(initialState: State(value: value))
        }

        /// The reason of the last read's refusal (`PlaylistSourceError.unsupported`).
        var refusal: String? {
            state.withLock { state in
                guard case .unsupported(let reason) = state.failure?.error else { return nil }
                return reason
            }
        }

        func value(
            loader: SegmentLoader, read: (SegmentLoader) throws(PlaylistSourceError) -> Value
        ) throws(PlaylistSourceError) -> Value {
            var waitingFor: Int?
            while true {
                let waited = waitingFor
                let step: Step = state.withLock { state in
                    if let value = state.value { return .done(value) }
                    if let failure = state.failure {
                        // A refusal is the answer for good (the same bytes say the same); another failure is that of
                        // the read waited for, and the next caller reads again.
                        if case .unsupported = failure.error { return .failed(failure.error) }
                        if let read = waited, failure.read == read { return .failed(failure.error) }
                    }
                    if let read = state.reading { return .wait(read) }
                    state.reads += 1
                    state.reading = state.reads
                    return .read(state.reads)
                }
                switch step {
                case .done(let value): return value
                case .failed(let error): throw error
                case .wait(let read):
                    if loader.isAborted { throw .load(.interrupted) }
                    waitingFor = read
                    state.withLock { $0.waiting += 1 }
                    _ = changed.wait(timeout: .now() + Self.waitStep)
                    state.withLock { $0.waiting -= 1 }
                case .read(let number):
                    let outcome: Result<Value, PlaylistSourceError>
                    do throws(PlaylistSourceError) {
                        outcome = .success(try read(loader))
                    } catch {
                        outcome = .failure(error)
                    }
                    let waiters = state.withLock { state in
                        state.reading = nil
                        switch outcome {
                        case .success(let value): state.value = value
                        case .failure(.load(.interrupted)): break
                        case .failure(let error): state.failure = (number, error)
                        }
                        return state.waiting
                    }
                    for _ in 0..<waiters { changed.signal() }
                    return try outcome.get()
                }
            }
        }
    }
}
