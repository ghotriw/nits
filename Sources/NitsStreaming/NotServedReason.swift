import Foundation

/// Why an address wasn't served (`HTTPSessionTransport.Opened.notServed`, `SegmentLoadError.notServed`): told in the
/// error, so a log shows what the server answered. The name a playlist lists may not be the address asked
/// (`PlaylistSource.address(of:)`): a reason names the host that answered (or a redirect's), with no path or query.
package enum NotServedReason: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Not a URL.
    case invalidAddress
    /// Answered, but not over HTTP.
    case notHTTP
    /// A redirect not followed (3xx), to `host` (its `Location`'s); or an answer from another address than asked.
    case redirected(host: String?)
    /// An HTTP status neither served nor an error: 204, a 3xx not followed, ...
    case status(Int, host: String?)
    /// A range from past the start answered with the whole file (200).
    case rangeAnsweredWhole
    /// A 206 whose `Content-Range` is not from the offset asked for (nil: none).
    case rangeMismatch(String?)
    /// A local file, which only a playlist that is a file itself may list (`SegmentLoader.allowsFiles`).
    case fileNotAllowed
    /// Not an address the source lists.
    case unknownAddress
    /// An entry of the manifest with neither segments nor an index of them.
    case noSegments

    package var description: String {
        switch self {
        case .invalidAddress: "not a URL"
        case .notHTTP: "not an HTTP answer"
        case .redirected(let host): "redirected to \(host ?? "another address"), not followed"
        case .status(let status, let host): "HTTP \(status)" + (host.map { " from \($0)" } ?? "")
        case .rangeAnsweredWhole: "the range answered whole (HTTP 200)"
        case .rangeMismatch(let range): "Content-Range \(range ?? "missing") is not the range asked for"
        case .fileNotAllowed: "a local file listed by a playlist served over HTTP"
        case .unknownAddress: "not an address the source lists"
        case .noSegments: "no segments listed"
        }
    }

    /// The same as `description`: an error's payload prints by it (`load(...notServed(url, reason: HTTP 204 ...))`).
    package var debugDescription: String { description }
}
