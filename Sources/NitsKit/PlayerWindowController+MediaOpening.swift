import Foundation
import NitsCore
import NitsUI

extension PlayerWindowController {
    /// Opens the URLs dropped on the player or picked in its Open panel, in place: the window stays where it is.
    /// Returns the task resolving, opening and awaiting load completion of the media.
    @discardableResult
    public func openMedia(urls: [URL]) -> Task<Void, Never>? {
        session.openMedia(urls: urls)
    }

    /// Opens `request` (`MediaOpenRequest.open(in:osd:load:)`) through `openStream`.
    public func open(
        _ request: MediaOpenRequest, startTime: Double? = nil, audioTrack: String? = nil, subtitleTrack: String? = nil,
        presentsWindow: Bool = true
    ) async {
        await session.open(
            request, startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack,
            presents: presentsWindow)
    }
}
