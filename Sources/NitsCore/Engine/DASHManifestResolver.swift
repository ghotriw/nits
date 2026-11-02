import CFFmpeg
import Foundation

/// Plays the DASH manifests (`.mpd`) of the network. Reads the manifest itself (`DASHManifest`) and hands the demuxer
/// a rewritten one with the best picture of its ladder, the others offered to choose from (`ResolvedMedia.videoFormats`:
/// the quality menu, and the switch that opens the manifest again at the position, are the ones of a video site's
/// pictures). A manifest it cannot read or has no use for (a live one, of several periods) is left to the demuxer to
/// open as it is, which plays the first picture it lists.
///
/// Asked for addresses ending in `.mpd` only: a manifest at another address, which FFmpeg opens itself, plays
/// without this.
struct DASHManifestResolver: MediaResolver {
    var session: URLSession = .shared

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

    func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in MediaURL.sanitizedHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, finalURL) = await download(request),
            let manifest = DASHManifest(data: data, url: finalURL)
        else {
            // A load that was replaced or stopped ends this early; nothing was left to the demuxer.
            if !Task.isCancelled { AppLog.info(.engine, "DASH: '\(url.absoluteString)' is left to the demuxer") }
            return nil
        }
        guard !manifest.videos.isEmpty || manifest.hasAudio else {
            if manifest.hasProtectedStreams { throw MediaResolutionError("Its streams are protected (DRM)") }
            return nil
        }
        let formats = manifest.videos.compactMap { video -> VideoFormat? in
            manifest.text(videoID: video.id).map { text in
                // HDR10 and SDR of one size and codec would differ in the menu by their bitrates only. Dolby Vision
                // says it in its name.
                VideoFormat(
                    id: video.id, url: MediaURL.inlineDASHManifest(text), width: video.width, height: video.height,
                    frameRate: video.frameRate,
                    codec: video.isHDR && video.codec != "Dolby Vision" ? "\(video.codec) HDR" : video.codec,
                    bitrate: video.bandwidth)
            }
        }
        // A ladder of pictures that can follow the network plays as one: the demuxer lists the rungs as variants, the
        // quality menu is theirs and the pictures `videoFormats` lists are left to a stream without a ladder.
        let ladder = manifest.ladderText().map(MediaURL.inlineDASHManifest)
        guard let path = ladder ?? formats.first?.url ?? manifest.text().map(MediaURL.inlineDASHManifest) else {
            return nil
        }
        AppLog.info(
            .engine,
            "DASH: '\(url.absoluteString)': \(manifest.videos.count) picture(s), "
                + (ladder != nil ? "a ladder of \(manifest.ladder.count)" : "playing \(formats.first?.id ?? "audio")"))
        return ResolvedMedia(
            path: path, headers: headers, title: manifest.title, videoFormats: formats.count > 1 ? formats : [],
            selectedVideoFormatID: formats.first?.id)
    }
}

/// What a load asks to turn an address into streams: the engine's own resolvers first, then the host's.
struct MediaResolverChain: MediaResolver {
    var builtIn: [any MediaResolver] = [DASHManifestResolver()]
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
