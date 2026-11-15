import Foundation

/// What of a manifest is played, told by the address that opens it: the resolver (`DASHManifestResolver`) reads the
/// manifest to offer its pictures and sounds, and hands the address back with the choice in its fragment
/// (`https://…/manifest.mpd#nits-video=<id>`), which a server never sees. The client (`DASHPlaylists`) reads the manifest
/// itself and plays what the choice names; an address with none plays what the manifest tells, as for any `.mpd`.
struct DASHSelection: Equatable, Sendable {
    /// The picture to play (a representation's id): its ladder, the pictures that switch with it (`DASHPlaylists.ladder`),
    /// with the manifest's sounds.
    var video: String?
    /// The sound to play alone (a representation's id): a sound told by segments beside a picture played as a file.
    var audio: String?

    private static let videoKey = "nits-video"
    private static let audioKey = "nits-audio"

    var isEmpty: Bool { video == nil && audio == nil }

    init(video: String? = nil, audio: String? = nil) {
        self.video = video
        self.audio = audio
    }

    /// The choice an address's fragment holds; empty for an address with none or a fragment that is not this one's.
    init(fragment: String?) {
        for part in (fragment ?? "").split(separator: "&") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let value = String(part[part.index(after: equals)...]).removingPercentEncoding
            switch part[..<equals] {
            case Self.videoKey: video = value
            case Self.audioKey: audio = value
            default: break
            }
        }
    }

    /// `address` with the choice in its fragment (without it when empty).
    func address(of manifest: URL) -> String {
        guard var components = URLComponents(url: manifest, resolvingAgainstBaseURL: false) else {
            return manifest.absoluteString
        }
        components.fragment = nil
        let allowed = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "&=%"))
        var parts: [String] = []
        if let video, let escaped = video.addingPercentEncoding(withAllowedCharacters: allowed) {
            parts.append("\(Self.videoKey)=\(escaped)")
        }
        if let audio, let escaped = audio.addingPercentEncoding(withAllowedCharacters: allowed) {
            parts.append("\(Self.audioKey)=\(escaped)")
        }
        if !parts.isEmpty { components.percentEncodedFragment = parts.joined(separator: "&") }
        return components.string ?? manifest.absoluteString
    }
}
