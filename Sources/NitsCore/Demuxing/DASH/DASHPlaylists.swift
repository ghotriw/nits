import Foundation
import os

/// A DASH manifest (MPD) told to the client as HLS playlists (`HLSPlaylistSource`): its pictures as the variants of a
/// master playlist, the best sound of each language as an audio rendition, each representation's segments as a media
/// playlist. The client plays them as it plays HLS's (`HLSInput`); see `.agents/dash-client/PLAN.md`.
///
/// **Addresses.** The playlists are named by keys of the source's own (`nits-dash://<source>/…`), never fetched: the
/// manifest (inline, from the resolver, or at `address`) is read once and every playlist is answered from it. What the
/// keys stand for stays here, so no lane's address carries a manifest.
///
/// **Numbers.** The client switches between variants by segment number (`HLSInput.canJoin(variant:sequence:)`), which
/// HLS promises a ladder and DASH does not (`startNumber`, timelines per representation, each resolution in a set of its
/// own). So the pictures that may switch with each other (one codec and range, as `HLSInput.ladder(of:)` groups them)
/// are numbered by time, from the segments of the best of them: a picture whose segments do not start where the best
/// one's do (within half a frame) is left out, as a switch to it could not land on a segment boundary.
///
/// One `static` period only, for now; what is not played yet is refused (`HLSPlaylistSourceError.unsupported`) with
/// the reason.
struct DASHPlaylists: HLSPlaylistSource {
    /// The scheme of the keys.
    static let scheme = "nits-dash"

    /// The key of the master playlist: what `HLSInput` opens.
    let masterURL: URL
    /// Where the manifest came from (after redirects, for an inline one the resolver's): its relative addresses are
    /// relative to it, and the requests' headers are scoped by it.
    let address: URL
    private let store: Store
    /// How many callers wait for a read of the manifest another one is making (tests).
    var waitingReaders: Int { store.waiting }

    /// The manifest at `address`, or `inline` (the resolver's, which came from `address`).
    init(address: URL, inline: Data? = nil) {
        self.address = address
        let id = UUID().uuidString.lowercased()
        masterURL = URL(string: "\(Self.scheme)://\(id)/")!
        store = Store(id: id, address: address, inline: inline)
    }

    func playlist(at url: URL, variables: [String: String], loader: HLSSegmentLoader) throws(HLSPlaylistSourceError)
        -> HLSPlaylist
    {
        guard url.scheme == Self.scheme, url.host == store.id else { throw .load(.notServed(url)) }
        let built = try store.built(loader: loader)
        if url.path.isEmpty || url.path == "/" { return built.master }
        guard let index = url.pathComponents.dropFirst().first.flatMap({ Int($0) }),
            built.media.indices.contains(index)
        else { throw .load(.notServed(url)) }
        return .media(built.media[index])
    }

    // MARK: - Building

    /// The playlists of a presentation: the master (or, with no picture, the one sound's media playlist), and a media
    /// playlist for each representation played, at its index in `media`.
    struct Built: Sendable {
        var master: HLSPlaylist
        var media: [HLSMediaPlaylist]
    }

    /// How far apart two segments' starts may be and still be one boundary, with no frame rate told.
    static let boundaryTolerance = 0.01

    static func build(_ presentation: DASHPresentation, id: String) throws(HLSPlaylistSourceError) -> Built {
        let videos = presentation.representations.filter { $0.kind == .video }
        let sounds = bestSounds(presentation.representations.filter { $0.kind == .audio })
        let pictures = numberedPictures(videos)
        let played = pictures.map(\.representation) + sounds
        guard !played.isEmpty else { throw .unsupported("no picture or sound it can play") }
        if let first = played.first,
            let other = played.first(where: { abs($0.presentationTimeOffset - first.presentationTimeOffset) > 0.001 })
        {
            throw .unsupported(
                "presentation time offsets that differ (\(first.id): \(first.presentationTimeOffset) s, "
                    + "\(other.id): \(other.presentationTimeOffset) s)")
        }

        var media: [HLSMediaPlaylist] = []
        func key(_ representation: DASHPresentation.Representation) -> URL {
            let escaped =
                representation.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
                ?? ""
            return URL(string: "\(scheme)://\(id)/\(media.count)/\(escaped)")!
        }

        if pictures.isEmpty, let sound = sounds.first {
            // Sound alone: its playlist is the stream (the other languages wait for the master to carry them).
            return Built(master: .media(mediaPlaylist(sound, numbers: nil)), media: [])
        }
        var master = HLSMasterPlaylist()
        master.hasIndependentSegments = true
        for sound in sounds {
            let url = key(sound)
            media.append(mediaPlaylist(sound, numbers: nil))
            master.renditions.append(
                HLSRendition(
                    type: .audio, groupID: "a", name: sound.language ?? "audio \(master.renditions.count + 1)",
                    url: url,
                    language: sound.language, isDefault: master.renditions.isEmpty, autoselect: true))
        }
        for picture in pictures {
            let representation = picture.representation
            let url = key(representation)
            media.append(mediaPlaylist(representation, numbers: picture.numbers))
            master.variants.append(
                HLSVariant(
                    url: url, bandwidth: representation.bandwidth, codecs: representation.codecs,
                    supplementalCodecs: representation.supplementalCodecs,
                    resolution: representation.width.flatMap { width in
                        representation.height.map { HLSResolution(width: width, height: $0) }
                    },
                    frameRate: representation.frameRate, videoRange: representation.videoRange,
                    audioGroup: sounds.isEmpty ? nil : "a"))
        }
        return Built(master: .master(master), media: media)
    }

    /// A representation's segments as a finished media playlist; `numbers`: those the ladder gave them, else their own.
    static func mediaPlaylist(_ representation: DASHPresentation.Representation, numbers: [Int]?) -> HLSMediaPlaylist {
        var playlist = HLSMediaPlaylist(
            targetDuration: (representation.segments.map(\.duration).max() ?? 0).rounded(.up))
        playlist.type = .vod
        playlist.hasEnded = true
        playlist.hasIndependentSegments = true
        playlist.segments = representation.segments.enumerated().map { index, segment in
            HLSSegment(
                url: segment.url, duration: segment.duration, sequence: numbers?[index] ?? segment.number,
                discontinuitySequence: 0, byteRange: segment.byteRange, initSection: representation.initSection)
        }
        playlist.mediaSequence = playlist.segments.first?.sequence ?? 0
        return playlist
    }

    /// The best sound of each language, the main one's first: the main track over one without a role over a commentary
    /// or a description, then a codec told to be decoded over one not told, then the higher bitrate. Sounds the build
    /// cannot decode (AC-4, MPEG-H) are left out.
    static func bestSounds(_ sounds: [DASHPresentation.Representation]) -> [DASHPresentation.Representation] {
        var best: [String: (sound: DASHPresentation.Representation, rank: [Int])] = [:]
        var languages: [String] = []
        for sound in sounds {
            let decodable = sound.codecs.flatMap(CodecFamily.canDecodeAudio(in:))
            guard decodable != false else { continue }
            let rank = [sound.roleRank, decodable == true ? 1 : 0, sound.bandwidth]
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
    /// segments start where its own do. The others of the group are left out. Nil numbers: a picture alone in its group,
    /// numbered as its manifest says.
    static func numberedPictures(
        _ videos: [DASHPresentation.Representation]
    ) -> [(representation: DASHPresentation.Representation, numbers: [Int]?)] {
        struct Group: Hashable {
            var codec: String?
            var supplemental: String?
            var range: HLSVideoRange?
        }
        // `HLSInput.ladder(of:)` keeps every variant as one ladder when one of those with a picture (a size or a picture's
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
        var result: [(DASHPresentation.Representation, [Int]?)] = []
        for video in videos {
            guard let reference = references[group(of: video)] else {
                result.append((video, nil))
                continue
            }
            if video.id == reference.id && video.set == reference.set {
                result.append((video, reference.segments.map(\.number)))
                continue
            }
            let tolerance = reference.frameRate.map { 0.5 / max($0, 1) } ?? boundaryTolerance
            guard let numbers = numbers(of: video, on: reference, tolerance: tolerance) else {
                AppLog.warning(
                    .demuxer,
                    "DASH: \(video.id) (\(video.bandwidth) bit/s) is left out of the ladder: its segments do not start "
                        + "where \(reference.id)'s do")
                continue
            }
            result.append((video, numbers))
        }
        return result
    }

    /// The numbers `video`'s segments take from `reference`'s: the same count, each starting where the reference's of
    /// the same place does (within `tolerance` seconds). Nil when they don't.
    static func numbers(
        of video: DASHPresentation.Representation, on reference: DASHPresentation.Representation, tolerance: Double
    ) -> [Int]? {
        guard video.segments.count == reference.segments.count else { return nil }
        var numbers: [Int] = []
        numbers.reserveCapacity(video.segments.count)
        for (own, theirs) in zip(video.segments, reference.segments) {
            guard abs(own.start - theirs.start) <= tolerance else { return nil }
            numbers.append(theirs.number)
        }
        return numbers
    }
}

extension DASHPlaylists {
    /// The manifest and the playlists built from it, shared by every caller (the opening's side-by-side requests, the
    /// lanes): read once. A read is made by the first caller that needs it, through its own loader; the others wait for it
    /// (in steps, each giving way to its own abort). A read that gave way to its caller's abort is no answer: those
    /// waiting for it read again themselves. A real failure is the answer of those that waited for it.
    final class Store: @unchecked Sendable {
        let id: String
        private let address: URL
        private let inline: Data?

        private struct State {
            var built: Built?
            /// The read going on, by its number.
            var reading: Int?
            var reads = 0
            var failure: (read: Int, error: HLSPlaylistSourceError)?
            var waiting = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let changed = DispatchSemaphore(value: 0)
        /// How often a waiter checks its abort.
        static let waitStep: DispatchTimeInterval = .milliseconds(50)

        var waiting: Int { state.withLock { $0.waiting } }

        init(id: String, address: URL, inline: Data?) {
            self.id = id
            self.address = address
            self.inline = inline
        }

        func built(loader: HLSSegmentLoader) throws(HLSPlaylistSourceError) -> Built {
            enum Step {
                case done(Built)
                case failed(HLSPlaylistSourceError)
                case read(Int)
                case wait(Int)
            }
            var waitingFor: Int?
            while true {
                let waited = waitingFor
                let step: Step = state.withLock { state in
                    if let built = state.built { return .done(built) }
                    if let read = waited, let failure = state.failure, failure.read == read {
                        return .failed(failure.error)
                    }
                    if let read = state.reading { return .wait(read) }
                    state.reads += 1
                    state.reading = state.reads
                    return .read(state.reads)
                }
                switch step {
                case .done(let built): return built
                case .failed(let error): throw error
                case .wait(let read):
                    if loader.isAborted { throw .load(.interrupted) }
                    waitingFor = read
                    state.withLock { $0.waiting += 1 }
                    _ = changed.wait(timeout: .now() + Self.waitStep)
                    state.withLock { $0.waiting -= 1 }
                case .read(let read):
                    let outcome: Result<Built, HLSPlaylistSourceError>
                    do throws(HLSPlaylistSourceError) {
                        outcome = .success(try self.read(loader: loader))
                    } catch {
                        outcome = .failure(error)
                    }
                    let waiters = state.withLock { state in
                        state.reading = nil
                        switch outcome {
                        case .success(let built): state.built = built
                        case .failure(.load(.interrupted)): break
                        case .failure(let error): state.failure = (read, error)
                        }
                        return state.waiting
                    }
                    for _ in 0..<waiters { changed.signal() }
                    return try outcome.get()
                }
            }
        }

        private func read(loader: HLSSegmentLoader) throws(HLSPlaylistSourceError) -> Built {
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
            let presentation: DASHPresentation
            do throws(DASHPresentationError) {
                presentation = try DASHPresentation.parse(data, url: servedFrom)
            } catch {
                switch error {
                case .unreadable: throw .unreadable(.notAPlaylist)
                case .unsupported(let reason): throw .unsupported(reason)
                }
            }
            return try DASHPlaylists.build(presentation, id: id)
        }
    }
}
