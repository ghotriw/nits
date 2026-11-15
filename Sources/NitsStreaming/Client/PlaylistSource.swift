import Foundation

/// Where the client's playlists come from: the opening's multivariant and media playlists (`HLSInput`) and a live one's
/// reloads (`HLSLane`). The client plays the playlists, not their text: an HLS server's (`HLSServedPlaylists`) or
/// another manifest's told as playlists (a DASH MPD's representations as variants and renditions). Called from the
/// thread that opens or reads, blocking it.
package protocol PlaylistSource: Sendable {
    /// The playlist at `url`: a multivariant or a media playlist. `variables`: those a multivariant defined, which a media playlist
    /// may import (`EXT-X-DEFINE:IMPORT`). What it requests goes through `loader`, the caller's: on its transport and
    /// giving way to its abort, as the caller's segments do.
    func playlist(at url: URL, variables: [String: String], loader: SegmentLoader) throws(PlaylistSourceError)
        -> StreamingPlaylist

    /// Where a request for `url`, an address a playlist lists (a segment's, an init section's), really goes: asked by the
    /// loader at each request, so an address that expires (a signed one) is given as it is now, and the playlist names
    /// the segment by a key that stays. Called on the thread that reads, which it may block.
    /// Nil when it has none (a key it does not know): the request fails as not found, without going to the network.
    func address(of url: URL) -> URL?

    /// Makes the addresses valid again after the server refused one (403: it expired before it was renewed); asked
    /// once per request, which is then made again at `address(of:)`. False when it could not.
    func renewAddresses(shouldAbort: () -> Bool) -> Bool
}

extension PlaylistSource {
    package func address(of url: URL) -> URL? { url }
    package func renewAddresses(shouldAbort: () -> Bool) -> Bool { false }
}

package enum PlaylistSourceError: Error, Equatable {
    /// It did not load.
    case load(SegmentLoadError)
    /// It loaded, but does not read as a playlist.
    case unreadable(HLSPlaylistError)
    /// It reads, as what the client does not play (yet): the reason. The stream may be opened otherwise.
    case unsupported(String)

    /// FFmpeg's error for it (`AVERROR_EXIT` for an abort).
    var code: Int32 {
        switch self {
        case .load(let error): SegmentReader.code(for: error)
        case .unreadable: -EIO
        case .unsupported: -ENOSYS
        }
    }
}
