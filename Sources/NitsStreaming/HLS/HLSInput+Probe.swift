import Foundation

extension HLSInput {
    /// The length of a finished HLS stream (a playlist that ends), from its playlists alone: the top variant's, for a
    /// multivariant. Nil for a live one, or one that doesn't load in time (`interrupt`). No segment is read.
    package static func finishedDuration(of address: String, headers: [String: String], interrupt: FFmpegInterrupt)
        -> Double?
    {
        let url = StreamingURL.normalizeMediaPath(address)
        let isLocal = !HTTPSessionTransport.serves(url)
        guard let location = isLocal ? URL(fileURLWithPath: url) : URL(string: url) else { return nil }
        let transport = HTTPSessionTransport(source: url, headers: headers) { interrupt.shouldInterruptFFmpeg }
        let loader = SegmentLoader(transport: transport, allowsFiles: isLocal)
        guard let first = try? loader.playlist(location),
            let parsed = try? StreamingPlaylist.parse(first.data, url: first.servedFrom)
        else { return nil }
        let media: MediaPlaylist
        switch parsed {
        case .media(let playlist):
            media = playlist
        case .multivariant(let multivariant):
            guard let best = ladder(of: multivariant).max(by: { $0.bandwidth < $1.bandwidth }),
                let loaded = try? loader.playlist(best.url),
                case .media(let playlist)? = try? StreamingPlaylist.parse(
                    loaded.data, url: loaded.servedFrom, variables: multivariant.variables)
            else { return nil }
            media = playlist
        }
        guard !media.isLive, !media.segments.isEmpty else { return nil }
        let timeline = HLSTimeline(media)
        return timeline.end - timeline.start
    }
}
