import Foundation

@testable import NitsCore

extension SubtitleController {
    /// Adds a subtitle file as tracks, as `addExternal(urls:)` does but without selecting one, reading a local file on
    /// the calling actor; the tracks made, or found already made from it (empty if it can't be read).
    func addExternalFile(url: URL) -> [Int] {
        guard url.isFileURL else { return addNetworkFile(url: url) }
        return addReadFile(SubtitleFileRead.read(url, encoding: settings.encoding))
    }
}
