import Foundation

/// Playlists an HLS server serves: loaded, and read from their text against the address they were served from (after
/// redirects).
package struct HLSServedPlaylists: PlaylistSource {
    package func playlist(at url: URL, variables: [String: String], loader: SegmentLoader)
        throws(PlaylistSourceError)
        -> StreamingPlaylist
    {
        let loaded: (data: Data, servedFrom: URL)
        do {
            loaded = try loader.playlist(url)
        } catch {
            throw .load(error)
        }
        do {
            return try StreamingPlaylist.parse(loaded.data, url: loaded.servedFrom, variables: variables)
        } catch {
            throw .unreadable(error)
        }
    }
}
