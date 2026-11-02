import CFFmpeg
import Foundation

/// Plays the DASH manifests (`.mpd`) of the network. Reads the manifest itself (`DASHManifest`) and hands the demuxer
/// a rewritten one with the ladder of the preferred codec (`VideoCodecPreference`), the best picture of each other codec
/// offered to choose from, with a ladder of its own (`ResolvedMedia.videoFormats`:
/// the quality menu, and the switch that opens the manifest again at the position, are the ones of a video site's
/// pictures). A manifest it cannot read or has no use for (a live one, of several periods) is left to the demuxer to
/// open as it is, which plays the first picture it lists.
///
/// Asked for addresses ending in `.mpd` only: a manifest at another address, which FFmpeg opens itself, plays
/// without this.
struct DASHManifestResolver: MediaResolver {
    var session: URLSession = .shared
    /// Which codec is preferred among the pictures of a size (`VideoCodecPreference`).
    var codecs = VideoCodecPreference()

    func order(for url: URL) -> MediaResolutionOrder? {
        // The name's end, not its extension: Unified Streaming's manifest is `…/.mpd`, a name that has none.
        guard url.lastPathComponent.lowercased().hasSuffix(".mpd"), av_find_input_format("dash") != nil else {
            return nil
        }
        return .beforeOpening
    }

    /// The manifest, and the address it came from after redirects; nil when it is not answered with success, or is
    /// larger than a manifest is read to be (`DASHManifest.sizeLimit`: stopped as it comes, not downloaded first).
    private func download(_ request: URLRequest) async -> (Data, URL)? {
        guard let (bytes, response) = try? await session.bytes(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            http.expectedContentLength <= DASHManifest.sizeLimit
        else { return nil }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > DASHManifest.sizeLimit { return nil }
            }
        } catch {
            return nil
        }
        return (data, http.url ?? request.url!)
    }

    /// How long the indexes may take all together, seconds: a request's own timeout counts the time without data, and
    /// a slow one would hold the opening of every picture for it. The rest play as they are.
    var indexBudget: Duration = .seconds(6)

    private enum IndexOutcome: Sendable {
        case found(DASHManifest.IndexRequest, SegmentIndex)
        case missed
        case expired
    }

    /// The indexes `requests` ask for, a range of each file, side by side. One that is not answered as asked, or is not
    /// an index the manifest can say the segments of, is left out: its file plays as it is.
    private func indexes(
        of requests: [DASHManifest.IndexRequest], headers: [String: String]
    ) async -> [(DASHManifest.IndexRequest, SegmentIndex)] {
        await withTaskGroup(of: IndexOutcome.self) { group in
            group.addTask {
                try? await Task.sleep(for: indexBudget)
                return .expired
            }
            for request in requests {
                group.addTask { await index(of: request, headers: headers) }
            }
            var found: [(DASHManifest.IndexRequest, SegmentIndex)] = []
            var pending = requests.count
            for await outcome in group {
                switch outcome {
                case .found(let request, let index):
                    found.append((request, index))
                    pending -= 1
                case .missed: pending -= 1
                // Those not in yet are given up, and the clock with those in.
                case .expired: group.cancelAll()
                }
                if pending == 0 { group.cancelAll() }
            }
            return found
        }
    }

    /// The index of one file: asked for as a range, and not read if the server answers otherwise (a server that takes
    /// no `Range` sends the file, which is not downloaded for this) or with more than asked for.
    private func index(of request: DASHManifest.IndexRequest, headers: [String: String]) async -> IndexOutcome {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 15)
        for (name, value) in MediaURL.sanitizedHeaders(headers) { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue(
            "bytes=\(request.range.lowerBound)-\(request.range.upperBound)", forHTTPHeaderField: "Range")
        let size = request.range.count
        guard let (bytes, response) = try? await session.bytes(for: urlRequest) else { return .missed }
        guard
            let http = response as? HTTPURLResponse, http.statusCode == 206, http.expectedContentLength == size
        else {
            bytes.task.cancel()
            return .missed
        }
        var data = Data()
        data.reserveCapacity(Int(size))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > size {
                    bytes.task.cancel()
                    return .missed
                }
            }
        } catch {
            return .missed
        }
        guard Int64(data.count) == size, let index = SegmentIndex.parse(data, at: request.range.lowerBound),
            !request.requiresSAP || index.startsWithSAP
        else { return .missed }
        return .found(request, index)
    }

    func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in MediaURL.sanitizedHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, finalURL) = await download(request),
            var manifest = DASHManifest(data: data, url: finalURL, codecs: codecs)
        else {
            // A load that was replaced or stopped ends this early; nothing was left to the demuxer.
            if !Task.isCancelled { AppLog.info(.engine, "DASH: '\(url.absoluteString)' is left to the demuxer") }
            return nil
        }
        guard !manifest.videos.isEmpty || manifest.hasAudio else {
            if manifest.hasProtectedStreams { throw MediaResolutionError("Its streams are protected (DRM)") }
            return nil
        }
        // The segments of the pictures and sounds that are single files, which FFmpeg reads from their start to seek in.
        let requests = manifest.indexRequests
        if !requests.isEmpty {
            let found = await indexes(of: requests, headers: headers)
            AppLog.info(.engine, "DASH: the segments of \(found.count) of \(requests.count) single file(s) are known")
            for (request, index) in found {
                manifest.setIndex(index, for: request)
            }
        }
        // HDR10 and SDR of one size and codec would differ in the menu by their bitrates only. Dolby Vision says it in
        // its name.
        func format(_ video: DASHManifest.Video, text: String?) -> VideoFormat? {
            text.map { text in
                VideoFormat(
                    id: video.id, url: MediaURL.inlineDASHManifest(text), width: video.width, height: video.height,
                    frameRate: video.frameRate,
                    codec: video.isHDR && video.codec != "Dolby Vision" ? "\(video.codec) HDR" : video.codec,
                    bitrate: video.bandwidth)
            }
        }
        // A ladder of pictures that can follow the network plays as one: the demuxer lists the rungs as variants and
        // the quality menu is theirs. What the viewer may choose besides is the codec (and range): the best picture of
        // each, which plays with the ladder of its own. A stream without a ladder offers its pictures.
        let ladder = manifest.ladderText().map(MediaURL.inlineDASHManifest)
        let hasLadder = manifest.codecGroups.contains { manifest.ladder(of: $0).count > 1 }
        let formats: [VideoFormat]
        if hasLadder {
            formats = manifest.codecGroups.compactMap { head in
                format(head, text: manifest.ladderText(of: head) ?? manifest.text(videoID: head.id))
            }
        } else {
            formats = manifest.videos.compactMap { format($0, text: manifest.text(videoID: $0.id)) }
        }
        guard let path = ladder ?? formats.first?.url ?? manifest.text().map(MediaURL.inlineDASHManifest) else {
            return nil
        }
        AppLog.info(
            .engine,
            "DASH: '\(url.absoluteString)': \(manifest.videos.count) picture(s), "
                + (ladder != nil ? "a ladder of \(manifest.ladder.count)" : "playing \(formats.first?.id ?? "audio")"))
        return ResolvedMedia(
            path: path, headers: headers, title: manifest.title, videoFormats: formats.count > 1 ? formats : [],
            selectedVideoFormatID: formats.count > 1 ? formats.first?.id : nil)
    }
}

/// What a load asks to turn an address into streams: the engine's own resolvers first, then the host's.
struct MediaResolverChain: MediaResolver {
    var codecs = VideoCodecPreference()
    var builtIn: [any MediaResolver] { [DASHManifestResolver(codecs: codecs)] }
    var host: (any MediaResolver)?

    func order(for url: URL) -> MediaResolutionOrder? {
        for resolver in builtIn { if let order = resolver.order(for: url) { return order } }
        return host?.order(for: url)
    }

    func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
        for resolver in builtIn where resolver.order(for: url) != nil {
            return try await resolver.resolve(url, headers: headers)
        }
        return try await host?.resolve(url, headers: headers)
    }
}
