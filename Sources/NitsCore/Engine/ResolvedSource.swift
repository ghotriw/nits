import Foundation

/// The page playing as the resolver found it, and the request that asked for it: what loading the media again from
/// another of its streams needs (`PlayerEngine.selectVideoFormat`) without asking the resolver, whose answer is slow.
public struct ResolvedSource: Sendable, Equatable {
    public var request: MediaLoadRequest
    public var media: ResolvedMedia

    /// The request and streams that play picture `id` of the page from `startTime`, in place of the one playing; `nil`
    /// when the page has no such picture or it is the one playing. `audioTrack` and `subtitleTrack` are the tracks the
    /// viewer chose, kept; `title` and the artwork are what shows.
    public func switching(
        to id: String, startTime: Double, audioTrack: String?, subtitleTrack: String? = nil, title: String,
        artworkData: Data?, artworkURL: URL?
    ) -> (request: MediaLoadRequest, media: ResolvedMedia)? {
        guard id != media.selectedVideoFormatID, let switched = media.selecting(videoFormat: id) else { return nil }
        var request = request
        request.startTime = startTime
        request.audioTrack = audioTrack
        request.subtitleTrack = subtitleTrack
        request.title = title
        request.artworkData = artworkData
        request.artworkURL = artworkURL
        return (request, switched)
    }
}
