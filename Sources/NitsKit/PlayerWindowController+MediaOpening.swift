import Foundation
import NitsCore
import NitsUI

extension PlayerWindowController {
    /// Opens the URLs dropped on the player or picked in its Open panel, in place: the window stays where it is.
    /// Returns the task resolving and loading them.
    @discardableResult
    public func openMedia(urls: [URL]) -> Task<Void, Never>? {
        guard !urls.isEmpty else { return nil }
        return Task { [weak self] in
            let request = await MediaOpenRequest.resolving(urls, source: "Drop / open")
            // The window may have closed while folders or a page resolved: nothing opens in it then.
            guard let self, !self.isWindowClosing else { return }
            await self.open(request, presentsWindow: false)
        }
    }

    /// Opens `request` (`MediaOpenRequest.open(in:osd:load:)`) through `openStream`.
    public func open(
        _ request: MediaOpenRequest, startTime: Double? = nil, audioTrack: String? = nil, subtitleTrack: String? = nil,
        presentsWindow: Bool = true
    ) async {
        await request.open(in: engine, osd: uiState.osd) { [weak self] url in
            self?.openStream(
                url: url, startTime: startTime, audioTrack: audioTrack, subtitleTrack: subtitleTrack,
                presentsWindow: presentsWindow)
        }
    }
}
