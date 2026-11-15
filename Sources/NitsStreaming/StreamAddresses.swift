import Foundation

/// Where the signed addresses of a manifest's files are told by: a site's extractor (yt-dlp) lists files whose addresses
/// expire, so the manifest it makes names each by a key (`StreamAddresses.address(forKey:)`, an address that exists nowhere)
/// and the client asks the source for the real one at each request (`PlaylistSource.address(of:)`), and for new ones when
/// the server refused one (403). Never put a signed address in a manifest the client keeps.
package protocol StreamAddressSource: AnyObject, Sendable {
    /// The address of the file the manifest calls `key`, signed as it is now; nil for a key it does not know.
    func address(forKey key: String) -> URL?

    /// Makes the addresses valid again after the server refused one (403); false when it could not.
    func renewAddresses(shouldAbort: () -> Bool) -> Bool
}

package enum StreamAddresses {
    /// The host of the addresses a manifest names its files by, which no DNS knows.
    package static let host = "files.nits.invalid"

    /// What a manifest names the file `key` by (a format's id).
    package static func address(forKey key: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(["/"])
        return "https://\(host)/\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)"
    }

    /// The key of the file `url` names, when it is one of the manifest's addresses.
    package static func key(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host == host
        else { return nil }
        let key = String(components.percentEncodedPath.drop { $0 == "/" }).removingPercentEncoding
        return key?.isEmpty == false ? key : nil
    }
}
