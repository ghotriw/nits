import Foundation
internal import NitsStreaming

/// What a manifest that names its files by keys (`MediaFileKey`: a site's extractor lists files whose signed addresses
/// expire, and a manifest built from them must not hold those) is given the real addresses by: the address of each file as
/// it is now, and new ones when a server refused one. Told by a resolver (`ResolvedMedia.files`); the streaming client asks
/// at each request (`PlaylistSource.address(of:)`). Not for hosts: the type is a resolver's of NitsKit.
package protocol MediaFileSource: AnyObject, Sendable {
    /// The address of the file the manifest calls `key`, signed as it is now; nil for a key it does not know.
    func address(forKey key: String) -> URL?

    /// Makes the addresses valid again after a server refused one; false when it could not. Blocks, giving way to `shouldAbort`.
    func renewAddresses(shouldAbort: () -> Bool) -> Bool
}

/// The name of a file in a manifest that is told its addresses by a `MediaFileSource`.
package enum MediaFileKey {
    package static func address(_ key: String) -> String { StreamAddresses.address(forKey: key) }
}

/// `ResolvedMedia.files`: the source, compared by identity.
package struct MediaFiles: Equatable, Sendable {
    package var source: any MediaFileSource

    package init(_ source: any MediaFileSource) { self.source = source }

    package static func == (lhs: MediaFiles, rhs: MediaFiles) -> Bool { lhs.source === rhs.source }
}

/// `ResolvedMedia.fallback`: what plays when the media cannot be opened, held by a box (a value cannot hold itself).
package final class ResolvedFallback: Sendable, Equatable {
    package let media: ResolvedMedia

    package init(_ media: ResolvedMedia) { self.media = media }

    package static func == (lhs: ResolvedFallback, rhs: ResolvedFallback) -> Bool { lhs === rhs }
}

/// The client's view of a `MediaFileSource`.
final class MediaFileSourceBridge: StreamAddressSource {
    private let source: any MediaFileSource

    init(_ source: any MediaFileSource) { self.source = source }

    func address(forKey key: String) -> URL? { source.address(forKey: key) }

    func renewAddresses(shouldAbort: () -> Bool) -> Bool { source.renewAddresses(shouldAbort: shouldAbort) }
}

extension MediaFiles {
    /// What the client is given to ask for the addresses.
    var addresses: any StreamAddressSource { MediaFileSourceBridge(source) }
}
