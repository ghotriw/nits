import Foundation
internal import NitsStreaming

/// Plays the DASH manifests (`.mpd`) of the network. Reads the manifest (`DASHManifest`) for what it offers to choose
/// from, and hands back its address with the choice in the fragment (`DASHSelection`), which the client (`DASHPlaylists`)
/// plays: the picture chosen with the ladder of its codec (`VideoCodecPreference` orders them), and the best picture of
/// each other codec offered to choose from (`ResolvedMedia.videoFormats`: the quality menu, and the switch that opens
/// the address again at the position, are the ones of a video site's pictures). A manifest it cannot read or has no
/// use for (a live one, of several periods) is left to the client to open as it is, with the ladder and sounds it reads
/// itself.
///
/// Asked for addresses ending in `.mpd` only.
package struct DASHManifestResolver: MediaResolver {
    package var session: URLSession = .shared
    /// Which codec is preferred among the pictures of a size (`VideoCodecPreference`).
    package var codecs = VideoCodecPreference()
    /// Which codec is preferred among the sounds of a language (`AudioCodecPreference`).
    package var audioCodecs = AudioCodecPreference()

    package func order(for url: URL) -> MediaResolutionOrder? {
        // The name's end, not its extension: Unified Streaming's manifest is `…/.mpd`, a name that has none.
        guard url.lastPathComponent.lowercased().hasSuffix(".mpd") else { return nil }
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

    package func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in StreamingURL.sanitizedHeaders(headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (data, finalURL) = await download(request),
            let manifest = DASHManifest(data: data, url: finalURL, codecs: codecs, audioCodecs: audioCodecs)
        else {
            // A load that was replaced or stopped ends this early; nothing was left to the demuxer.
            if !Task.isCancelled { AppLog.info(.engine, "DASH: '\(url.absoluteString)' is left to the demuxer") }
            return nil
        }
        return try resolved(manifest, url: url, headers: headers)
    }

    /// What `manifest`, read from `url`, offers to choose from (see the type): the streams to play it with.
    package func resolved(_ manifest: DASHManifest, url: URL, headers: [String: String]) throws -> ResolvedMedia? {
        guard !manifest.videos.isEmpty || manifest.hasAudio else {
            if manifest.hasProtectedStreams { throw MediaResolutionError("Its streams are protected (DRM)") }
            return nil
        }
        // The manifest is not written again: each choice is the manifest's own address with the picture's id in its
        // fragment (`DASHSelection`), and the client reads the manifest as it plays any `.mpd`.
        // HDR10 and SDR of one size and codec would differ in the menu by their bitrates only. Dolby Vision says it in
        // its name.
        func format(_ video: DASHManifest.Video, url: String?) -> VideoFormat? {
            url.map { url in
                VideoFormat(
                    id: video.id, url: url, width: video.width,
                    height: video.height,
                    frameRate: video.frameRate,
                    codec: video.isHDR && video.codec != "Dolby Vision" ? "\(video.codec) HDR" : video.codec,
                    bitrate: video.bandwidth)
            }
        }
        // Pictures that are all files the client reads no index of (none with an index range): each a file, the sound added.
        if manifest.playsAsFiles {
            let formats = manifest.videos.compactMap { format($0, url: manifest.file(videoID: $0.id)?.absoluteString) }
            if let first = formats.first {
                let sounds = manifest.sounds().compactMap { sound in
                    URL(string: sound.path).map { (url: $0, language: sound.language) }
                }
                AppLog.info(
                    .engine,
                    "DASH: '\(url.absoluteString)': \(formats.count) picture(s) played as files, \(sounds.count) sound(s) added"
                )
                return ResolvedMedia(
                    path: first.url, headers: headers,
                    audioFiles: sounds.enumerated().map { index, sound in
                        // Named by its language: a track is otherwise named by its file, and a sound of segments is the
                        // manifest's address with it as the choice.
                        let title =
                            sound.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                            ?? sound.language ?? "Audio \(index + 1)"
                        return MediaLoadRequest.AudioFile(
                            url: sound.url, title: title, language: sound.language, isRequired: index == 0)
                    },
                    title: manifest.title, videoFormats: formats.count > 1 ? formats : [],
                    selectedVideoFormatID: formats.count > 1 ? first.id : nil)
            }
        }
        // A ladder of pictures that can follow the network plays as one: the client lists the rungs as variants and
        // the quality menu is theirs. What the viewer may choose besides is the codec (and range): the best picture of
        // each, which plays with the ladder of its own. A stream without a ladder offers its pictures.
        let ladder = manifest.ladder
        let hasLadder = manifest.codecGroups.contains { manifest.ladder(of: $0).count > 1 }
        let formats: [VideoFormat]
        if hasLadder {
            formats = manifest.codecGroups.compactMap { format($0, url: manifest.address(videoID: $0.id)) }
        } else {
            formats = manifest.videos.compactMap { format($0, url: manifest.address(videoID: $0.id)) }
        }
        guard let path = formats.first?.url ?? manifest.address() else { return nil }
        AppLog.info(
            .engine,
            "DASH: '\(url.absoluteString)': \(manifest.videos.count) picture(s), "
                + (!ladder.isEmpty ? "a ladder of \(ladder.count)" : "playing \(formats.first?.id ?? "audio")"))
        return ResolvedMedia(
            path: path, headers: headers, title: manifest.title, videoFormats: formats.count > 1 ? formats : [],
            selectedVideoFormatID: formats.count > 1 ? formats.first?.id : nil)
    }
}

/// What a load asks to turn an address into streams: the engine's own resolvers first, then the host's.
struct MediaResolverChain: MediaResolver {
    var codecs = VideoCodecPreference()
    var audioCodecs = AudioCodecPreference()
    var builtIn: [any MediaResolver] { [DASHManifestResolver(codecs: codecs, audioCodecs: audioCodecs)] }
    var host: (any MediaResolver)?

    func order(for url: URL) -> MediaResolutionOrder? {
        for resolver in builtIn { if let order = resolver.order(for: url) { return order } }
        return host?.order(for: url)
    }

    func resolve(_ url: URL, headers: [String: String]) async throws -> ResolvedMedia? {
        for resolver in builtIn where resolver.order(for: url) != nil {
            return try await resolver.resolve(url, headers: headers)
        }
        guard let found = try await host?.resolve(url, headers: headers) else { return nil }
        return Self.offeringChoices(of: found, codecs: codecs, audioCodecs: audioCodecs)
    }

    /// A host's manifest that names its files by keys (`ResolvedMedia.files`, or a live history's `liveHistory`, inline) gets what an `.mpd` of the network
    /// does (`DASHManifestResolver`): the pictures of each codec to choose from, the codec `codecs` prefers first, each
    /// choice the manifest's own location with the picture in its fragment (`DASHSelection`). The manifest is the host's
    /// and stays as it made it; one that cannot be read, or plays as files, is returned as it is.
    static func offeringChoices(
        of media: ResolvedMedia, codecs: VideoCodecPreference,
        audioCodecs: AudioCodecPreference = AudioCodecPreference()
    ) -> ResolvedMedia {
        // A live stream's history (`liveHistory`) names its streams by keys too, its addresses the live source's.
        guard media.files != nil || media.liveHistory != nil, media.videoFormats.isEmpty,
            let data = StreamingURL.inlineDASHManifestContents(media.path)
        else { return media }
        // What the choices' addresses are made against: no address, as the manifest has none of its own.
        let placeholder = URL(string: "https://\(StreamAddresses.host)/manifest.mpd")!
        let resolver = DASHManifestResolver(codecs: codecs, audioCodecs: audioCodecs)
        guard let manifest = DASHManifest(data: data, url: placeholder, codecs: codecs, audioCodecs: audioCodecs),
            let offered = try? resolver.resolved(manifest, url: placeholder, headers: media.headers),
            offered.path.hasPrefix(placeholder.absoluteString), offered.audioFiles.isEmpty
        else { return media }
        let base = String(media.path.prefix { $0 != "#" })
        func inline(_ address: String) -> String {
            let fragment = URLComponents(string: address)?.percentEncodedFragment
            return fragment.map { base + "#" + $0 } ?? base
        }
        var chosen = media
        chosen.path = inline(offered.path)
        chosen.videoFormats = offered.videoFormats.map { format in
            var format = format
            format.url = inline(format.url)
            return format
        }
        chosen.selectedVideoFormatID = offered.selectedVideoFormatID
        return chosen
    }
}
