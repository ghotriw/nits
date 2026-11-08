import Foundation
import NitsCore
import Testing
import os

@testable import NitsKit

/// Runs `work`, which blocks, on a thread of its own, as the demuxer's read thread does: not in the cooperative pool, whose
/// one thread (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) it would hold while waiting for a task that needs it.
func onThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: work()) }
    }
}

/// The addresses, the head and the signature of a YouTube live stream's segments (`YouTubeLiveSource`).
@Suite("YouTube live source")
struct YouTubeLiveSourceTests {
    private static let video =
        "https://rr1.googlevideo.example/videoplayback?id=live&itag=299&expire=2000000000&sig=old"
    private static let audio =
        "https://rr1.googlevideo.example/videoplayback?id=live&itag=140&expire=2000000000&sig=old"

    private static func answer(_ status: Int, _ headers: [String: String]) -> YouTubeLiveHistory.Answer {
        .init(status: status, headers: headers, data: Data())
    }

    private func source(
        urls: [String: String] = ["299": video, "140": audio], refreshMargin: Double = 1800,
        waitLimit: Duration = .seconds(60), renew: @escaping YouTubeLiveSource.Renew = { [:] },
        isOver: @escaping YouTubeLiveSource.Over = { true },
        headRequest: @escaping YouTubeLiveSource.HeadRequest = { _, _ in nil }
    ) -> YouTubeLiveSource {
        YouTubeLiveSource(
            urls: urls, headers: ["User-Agent": "Test/1"], segmentWaitLimit: waitLimit, refreshMargin: refreshMargin,
            renew: renew, isOver: isOver, headRequest: headRequest)
    }

    @Test("A segment's address is the stream's signed one with its number; a stream the source doesn't have has none")
    func addresses() throws {
        let source = source()
        let url = try #require(source.url(for: "299", number: 311_256))
        #expect(url.absoluteString == Self.video + "&sq=311256")
        #expect(source.url(for: "140", number: 0)?.absoluteString.hasSuffix("&sq=0") == true)
        #expect(source.url(for: "nope", number: 1) == nil)
        let bare = self.source(urls: ["1": "https://media.example/segment"])
        #expect(bare.url(for: "1", number: 7)?.absoluteString == "https://media.example/segment?sq=7")
    }

    @Test("The head is told by the headers of any answer, a refusal's too; none, none")
    func headFromHeaders() throws {
        let asked = OSAllocatedUnfairLock(initialState: [URLRequest]())
        let reply = OSAllocatedUnfairLock(
            initialState: Self.answer(404, ["x-head-seqnum": "329078", "x-head-time-millis": "1637915400"]))
        let source = self.source(waitLimit: .seconds(5)) {
            [] in
            [:]
        } headRequest: { request, _ in
            asked.withLock { $0.append(request) }
            return reply.withLock { $0 }
        }
        #expect(source.segmentWaitLimit == .seconds(5))
        let head = source.head(shouldAbort: { false })
        #expect(head == .head(LiveHead(number: 329_078, startTime: 1_637_915.4)))
        // A request without a number, for the first byte, with the player's headers.
        let request = try #require(asked.withLock { $0.first })
        #expect(request.url?.query?.contains("sq=") == false)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-0")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Test/1")

        reply.withLock { $0 = Self.answer(206, ["x-sequence-num": "5", "x-head-time-millis": "9000"]) }
        #expect(source.head(shouldAbort: { false }) == .head(LiveHead(number: 5, startTime: 9)))
        // An answer with no head in it is an answer: the server is there.
        reply.withLock { $0 = Self.answer(404, [:]) }
        #expect(source.head(shouldAbort: { false }) == .answeredWithoutHead)
    }

    @Test("A head nobody answered for is unknown")
    func headWithoutAnAnswer() {
        let source = self.source()
        #expect(source.head(shouldAbort: { false }) == .noAnswer)
    }

    @Test("Callers refused at once renew the signature together, once, and all get the new one")
    func renewalsAreShared() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let source = self.source(renew: {
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(200))
            return ["299": Self.video.replacingOccurrences(of: "sig=old", with: "sig=new")]
        })
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask { await onThread { source.renewSignature(shouldAbort: { false }) } }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results == [true, true, true, true])
        #expect(calls.withLock { $0 } == 1, "yt-dlp was asked \(calls.withLock { $0 }) times")
        #expect(source.url(for: "299", number: 1)?.absoluteString.contains("sig=new") == true)
        // The stream the renewal does not name keeps its address.
        #expect(source.url(for: "140", number: 1)?.absoluteString.contains("sig=old") == true)
        #expect(source.renewals == 1)
    }

    @Test("A renewal that fails says so, a renewal that is waited for gives way to a seek or a close")
    func failingAndAbortedRenewals() async {
        struct Down: Error {}
        let failing = self.source(renew: { throw Down() })
        let failed = await onThread { failing.renewSignature(shouldAbort: { false }) }
        #expect(!failed)
        #expect(failing.renewals == 0)

        let slow = self.source(renew: {
            try await Task.sleep(for: .seconds(30))
            return [:]
        })
        let abort = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            abort.withLock { $0 = true }
        }
        let started = ContinuousClock.now
        let aborted = await onThread { slow.renewSignature(shouldAbort: { abort.withLock { $0 } }) }
        #expect(!aborted)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("The signature is renewed before it expires, not once it was refused")
    func renewsAheadOfExpiry() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let expiring = "https://media.example/v?expire=\(Int(Date().timeIntervalSince1970) + 3)&sig=old"
        let source = self.source(
            urls: ["299": expiring], refreshMargin: 2,
            renew: {
                calls.withLock { $0 += 1 }
                return ["299": "https://media.example/v?expire=\(Int(Date().timeIntervalSince1970) + 7200)&sig=new"]
            })
        // Three seconds to expire, a margin of two: renewed after about one (never sooner than that).
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls.withLock { $0 } == 0)
        var waited = 0.0
        while calls.withLock({ $0 }) == 0, waited < 4 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        #expect(calls.withLock { $0 } == 1, "renewed \(calls.withLock { $0 }) time(s) in \(waited + 0.5) s")
        #expect(source.url(for: "299", number: 1)?.absoluteString.contains("sig=new") == true)
        // Two hours ahead now: not again.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Whether the stream is over is what the page says; no answer, no end; the wait for it gives way to a seek")
    func endOfTheStream() async {
        struct Down: Error {}
        let over = self.source(isOver: { true })
        #expect(await onThread { over.hasEnded(shouldAbort: { false }) } == true)
        let live = self.source(isOver: { false })
        #expect(await onThread { live.hasEnded(shouldAbort: { false }) } == false)
        let broken = self.source(isOver: { throw Down() })
        #expect(await onThread { broken.hasEnded(shouldAbort: { false }) } == nil)

        let slow = self.source(isOver: {
            try await Task.sleep(for: .seconds(30))
            return true
        })
        let abort = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            abort.withLock { $0 = true }
        }
        let started = ContinuousClock.now
        #expect(await onThread { slow.hasEnded(shouldAbort: { abort.withLock { $0 } }) } == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("Addresses that come back already inside the margin are not renewed again and again")
    func doesNotRenewEverySecond() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // Three seconds to expire, a margin of two: renewed after a second. Renewed to the same, which is inside it again.
        let source = self.source(
            urls: ["299": "https://media.example/v?expire=\(Int(Date().timeIntervalSince1970) + 3)&sig=old"],
            refreshMargin: 2,
            renew: {
                calls.withLock { $0 += 1 }
                return ["299": "https://media.example/v?expire=\(Int(Date().timeIntervalSince1970) + 3)&sig=again"]
            })
        try await Task.sleep(for: .milliseconds(3500))
        #expect(calls.withLock { $0 } == 1, "renewed \(calls.withLock { $0 }) times in 3.5 s")
        #expect(source.url(for: "299", number: 1)?.absoluteString.contains("sig=again") == true)
    }

    @Test("When an address expires is told by its `expire`")
    func readsExpiry() {
        #expect(YouTubeLiveSource.expiry(of: Self.video) == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(YouTubeLiveSource.expiry(of: "https://media.example/v?sig=x") == nil)
        #expect(YouTubeLiveSource.head(in: ["x-head-seqnum": "9"]) == nil, "a number without its time is no head")
    }
}
