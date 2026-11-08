import Foundation
import NitsCore
import os

/// What a YouTube live stream's manifest is asked for its segments through (`LiveSegmentSource`): their signed
/// addresses, which expire in about six hours; where the stream's head is; and a new signature when the old one is
/// refused.
///
/// The addresses are renewed before they expire (a margin ahead of the earliest `expire` they carry), by asking yt-dlp
/// for the page again, so that a stream watched at its edge for a day never has to be reopened; and at once when the server
/// refuses one (`renewSignature`, which waits). Renewals are one at a time: a read that is refused while one runs joins it.
final class YouTubeLiveSource: LiveSegmentSource {
    /// New signed addresses of the streams by their keys (the formats' ids): yt-dlp asked again.
    typealias Renew = @Sendable () async throws -> [String: String]
    /// Whether the page says the stream is over (yt-dlp asked again: `is_live`, as the player knows it).
    typealias Over = @Sendable () async throws -> Bool
    /// A blocking request for the head, given up when the second says so; nil when it got no answer.
    typealias HeadRequest = @Sendable (URLRequest, () -> Bool) -> YouTubeLiveHistory.Answer?

    private struct State {
        var urls: [String: String]
        var renewal: (id: Int, task: Task<Bool, Never>)?
        var renewals = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let headers: [String: String]
    private let renew: Renew
    private let isOver: Over
    private let headRequest: HeadRequest
    private let refreshMargin: Double
    private let refresher = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    let segmentWaitLimit: Duration
    let headPollInterval: Duration
    let reportedSegmentGrace: Duration

    /// - Parameters:
    ///   - urls: The signed address of each stream, by key, without a segment's number.
    ///   - headers: What the requests for the head are sent with (the page's, the player's user agent).
    ///   - refreshMargin: How long before the earliest address expires it is renewed, seconds.
    init(
        urls: [String: String], headers: [String: String], segmentWaitLimit: Duration = .seconds(60),
        headPollInterval: Duration = .seconds(5), reportedSegmentGrace: Duration = .seconds(15),
        refreshMargin: Double = 1800, renew: @escaping Renew, isOver: @escaping Over = { true },
        headRequest: @escaping HeadRequest = urlSessionHead
    ) {
        self.state = OSAllocatedUnfairLock(initialState: State(urls: urls))
        self.headers = headers
        self.segmentWaitLimit = segmentWaitLimit
        self.headPollInterval = headPollInterval
        self.reportedSegmentGrace = reportedSegmentGrace
        self.refreshMargin = refreshMargin
        self.renew = renew
        self.isOver = isOver
        self.headRequest = headRequest
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.secondsUntilRefresh() else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                _ = await self.renewShared()
                // Whatever came of it, the next is not at once: addresses that come back already inside the margin (or
                // the same ones) would otherwise be renewed, by yt-dlp, every second.
                try? await Task.sleep(for: .seconds(Self.minimumRefreshInterval))
            }
        }
        refresher.withLock { $0 = task }
    }

    deinit {
        refresher.withLock { $0 }?.cancel()
        state.withLock { $0.renewal?.task.cancel() }
    }

    /// Seconds between one renewal ahead of expiry and the next, at the least.
    static let minimumRefreshInterval = 60.0

    /// How many times the signature was renewed.
    var renewals: Int { state.withLock { $0.renewals } }

    // MARK: LiveSegmentSource

    func url(for key: String, number: Int) -> URL? {
        guard let base = state.withLock({ $0.urls[key] }) else { return nil }
        return LiveHistory.segmentURL(base, number: number)
    }

    func head(shouldAbort: () -> Bool) -> LiveHeadAnswer {
        guard let base = state.withLock({ $0.urls.sorted { $0.key < $1.key }.first?.value }),
            let url = URL(string: base)
        else { return .noAnswer }
        // A request without a number gets the newest segment; every answer, a refusal too, tells the head.
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let answer = headRequest(request, shouldAbort) else { return .noAnswer }
        return Self.head(in: answer.headers).map { .head($0) } ?? .answeredWithoutHead
    }

    /// The head an answer's headers tell (names in lower case): its number and its start.
    static func head(in headers: [String: String]) -> LiveHead? {
        guard let number = (headers["x-head-seqnum"] ?? headers["x-sequence-num"]).flatMap({ Int($0) }),
            let millis = headers["x-head-time-millis"].flatMap({ Double($0) })
        else { return nil }
        return LiveHead(number: number, startTime: millis / 1000)
    }

    func renewSignature(shouldAbort: () -> Bool) -> Bool {
        Self.blocking(shouldAbort: shouldAbort) { [self] in await renewShared() } ?? false
    }

    func hasEnded(shouldAbort: () -> Bool) -> Bool? {
        Self.blocking(shouldAbort: shouldAbort) { [isOver] in try? await isOver() } ?? nil
    }

    /// Runs `work` to its end for a caller that cannot await: the demuxer's read thread, which blocks as it does in any read.
    /// Steps of 50 ms let `shouldAbort` (a seek or a close wants the thread) end the wait, and it ends at ninety seconds; `nil`
    /// then. The work is a task of the system's pool, so this is for the threads of FFmpeg's reads, not for the pool's own
    /// (in a pool of one thread such a wait would be for a task with no thread to run on).
    private static func blocking<T: Sendable>(
        shouldAbort: () -> Bool, _ work: @escaping @Sendable () async -> T
    ) -> T? {
        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            let value = await work()
            result.withLock { $0 = value }
            done.signal()
        }
        let deadline = ContinuousClock.now + .seconds(90)
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if shouldAbort() || ContinuousClock.now >= deadline { return nil }
        }
        return result.withLock { $0 }
    }

    // MARK: Renewal

    /// Renews the addresses, or joins the renewal that is under way.
    private func renewShared() async -> Bool {
        let (id, task): (Int, Task<Bool, Never>) = state.withLock { current in
            if let running = current.renewal { return running }
            let id = current.renewals + 1
            let task = Task { [self] () -> Bool in
                do {
                    let fresh = try await renew()
                    state.withLock { state in
                        // A stream the renewal does not name keeps the address it has.
                        state.urls.merge(fresh) { _, new in new }
                    }
                    return true
                } catch {
                    AppLog.warning(.ytdlp, "Renewing the live stream's signature failed: \(error)")
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

    /// Seconds until the earliest address is to be renewed; an hour when none says when it expires.
    private func secondsUntilRefresh() -> Double {
        let expiries = state.withLock { $0.urls.values }.compactMap { Self.expiry(of: $0) }
        guard let earliest = expiries.min() else { return 3600 }
        return max(1, earliest.timeIntervalSinceNow - refreshMargin)
    }

    /// The moment a signed address expires (YouTube's `expire`, seconds since 1970).
    static func expiry(of address: String) -> Date? {
        URLComponents(string: address)?.queryItems?.first { $0.name == "expire" }?.value
            .flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: The network

    static let urlSessionHead: HeadRequest = { request, shouldAbort in
        let answer = OSAllocatedUnfairLock<YouTubeLiveHistory.Answer?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { answer.withLock { $0 = .init(http, data: data ?? Data()) } }
            done.signal()
        }
        task.resume()
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if shouldAbort() {
                task.cancel()
                return nil
            }
        }
        return answer.withLock { $0 }
    }
}
