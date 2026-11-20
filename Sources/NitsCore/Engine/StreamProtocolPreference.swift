import Foundation

/// What plays a video of a site that offers it both ways (YouTube: its files, and an HLS playlist of the same pictures):
/// the manifest Nits makes of the files (every codec, every language; the codec chosen by `VideoCodecPreference`) or the
/// site's HLS playlist (its ladder of the codec `VideoCodecPreference` chooses). A site that offers one way plays that way.
public enum StreamProtocolPreference: String, Sendable, CaseIterable, Identifiable {
    case files
    case hls

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .files: "Files"
        case .hls: "HLS Playlist"
        }
    }
}
