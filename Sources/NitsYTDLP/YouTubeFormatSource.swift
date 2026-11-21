import Foundation
import NitsCore
import os

/// The signed addresses of the files of a YouTube video's manifest (`YouTubeFormatManifest`), which the client asks for at
/// each request (`MediaFileSource`): they expire in about six hours, and a video paused or left open that long is read
/// again with new ones. Renewed when a server refuses one (403), by asking yt-dlp for the page again; one renewal at a
/// time, and a read that is refused while one runs joins it.
final class YouTubeFormatSource: MediaFileSource {
    /// New signed addresses of the files by their keys (the formats' ids): yt-dlp asked again.
    typealias Renew = @Sendable () async throws -> [String: String]

    private struct State {
        var urls: [String: String]
        var renewal: (id: Int, task: Task<Bool, Never>)?
        var renewals = 0
        /// The id of the last renewal begun, failed ones too: a late waiter of a failed one must not end the next.
        var lastRenewalID = 0
        /// When the addresses were given (the resolver's answer or the last renewal).
        var issuedAt = ContinuousClock.now
    }

    private let state: OSAllocatedUnfairLock<State>
    private let renew: Renew
    /// How long a new address may be refused for (403) before it is taken to be a bad one.
    let settling: Duration

    init(urls: [String: String], settling: Duration = .seconds(5), renew: @escaping Renew) {
        self.settling = settling
        state = OSAllocatedUnfairLock(initialState: State(urls: urls))
        self.renew = renew
    }

    /// How many times the addresses were renewed.
    var renewals: Int { state.withLock { $0.renewals } }

    func address(forKey key: String) -> URL? {
        state.withLock { $0.urls[key] }.flatMap { URL(string: $0) }
    }

    /// An address that is refused in its first seconds is not a bad one: YouTube's CDN answers 403 to a signature just made
    /// for its first seconds (measured: refused up to 1.5 and 2 s, accepted from 2 and 2.5 s; another time every request
    /// still refused at 2.9 s and accepted a second later), and asking yt-dlp again would only restart that. So while the
    /// addresses are younger than `settling`, a refusal waits out the rest of it and the same addresses are asked again;
    /// once they are older, they are renewed, and the renewed ones are waited for the same way before they are asked: the
    /// loader asks once more only. What a wait does not cover at the opening, the engine's own retries do.
    func renewAddresses(shouldAbort: () -> Bool) -> Bool {
        if ContinuousClock.now < state.withLock({ $0.issuedAt }) + settling { return settle(shouldAbort: shouldAbort) }
        guard YouTubeLiveSource.blocking(shouldAbort: shouldAbort, { [self] in await renewShared() }) == true else {
            return false
        }
        return settle(shouldAbort: shouldAbort)
    }

    /// Waits until the addresses are older than `settling`; false when `shouldAbort` says so first.
    private func settle(shouldAbort: () -> Bool) -> Bool {
        let deadline = state.withLock { $0.issuedAt } + settling
        let step = DispatchSemaphore(value: 0)
        while ContinuousClock.now < deadline {
            if shouldAbort() { return false }
            _ = step.wait(timeout: .now() + .milliseconds(50))
        }
        return true
    }

    /// Renews the addresses, or joins the renewal that is under way.
    private func renewShared() async -> Bool {
        let (id, task): (Int, Task<Bool, Never>) = state.withLock { current in
            if let running = current.renewal { return running }
            current.lastRenewalID += 1
            let id = current.lastRenewalID
            let task = Task { [self] () -> Bool in
                do {
                    let fresh = try await renew()
                    // A file the renewal does not name keeps the address it has.
                    state.withLock { state in
                        state.urls.merge(fresh) { _, new in new }
                        state.issuedAt = .now
                    }
                    return true
                } catch {
                    AppLog.warning(.ytdlp, "Renewing the video's addresses failed: \(error)")
                    return false
                }
            }
            current.renewal = (id, task)
            return (id, task)
        }
        let isRenewed = await task.value
        state.withLock { state in
            if state.renewal?.id == id {
                state.renewal = nil
                if isRenewed { state.renewals += 1 }
            }
        }
        return isRenewed
    }
}
