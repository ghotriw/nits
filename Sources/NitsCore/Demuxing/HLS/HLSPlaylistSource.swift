import Foundation

/// Where the client's playlists come from: the opening's master and media playlists (`HLSInput`) and a live one's
/// reloads (`HLSLane`). The client plays the playlists, not their text: an HLS server's (`HLSServedPlaylists`) or
/// another manifest's told as playlists (a DASH MPD's representations as variants and renditions). Called from the
/// thread that opens or reads, blocking it.
protocol HLSPlaylistSource: Sendable {
    /// The playlist at `url`: a master or a media playlist. `variables`: those a master defined, which a media playlist
    /// may import (`EXT-X-DEFINE:IMPORT`). What it requests goes through `loader`, the caller's: on its transport and
    /// giving way to its abort, as the caller's segments do.
    func playlist(at url: URL, variables: [String: String], loader: HLSSegmentLoader) throws(HLSPlaylistSourceError)
        -> HLSPlaylist
}

enum HLSPlaylistSourceError: Error, Equatable {
    /// It did not load.
    case load(HLSSegmentLoadError)
    /// It loaded, but does not read as a playlist.
    case unreadable(HLSPlaylistError)

    /// FFmpeg's error for it (`AVERROR_EXIT` for an abort).
    var code: Int32 {
        switch self {
        case .load(let error): HLSSegmentReader.code(for: error)
        case .unreadable: -EIO
        }
    }
}

/// Playlists an HLS server serves: loaded, and read from their text against the address they were served from (after
/// redirects).
struct HLSServedPlaylists: HLSPlaylistSource {
    func playlist(at url: URL, variables: [String: String], loader: HLSSegmentLoader) throws(HLSPlaylistSourceError)
        -> HLSPlaylist
    {
        let loaded: (data: Data, servedFrom: URL)
        do {
            loaded = try loader.playlist(url)
        } catch {
            throw .load(error)
        }
        do {
            return try HLSPlaylist.parse(loaded.data, url: loaded.servedFrom, variables: variables)
        } catch {
            throw .unreadable(error)
        }
    }
}
