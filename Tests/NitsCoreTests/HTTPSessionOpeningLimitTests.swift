import Foundation
import Testing

@testable import NitsCore

/// A body nobody reads isn't downloaded whole while a DASH demuxer opens (`HTTPSessionInput.OpeningLimit`): it reads
/// the start of each rung of a ladder, a few kilobytes of segments of megabytes, and they would take a slow link's
/// seconds each.
@Suite("Inputs opened while a demuxer opens", .serialized, .hostDependent, .networkServer)
struct HTTPSessionOpeningLimitTests {
    static let size = 4 << 20

    fileprivate static func server() throws -> (server: TestHTTPServer, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsOpeningLimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(
            to: directory.appendingPathComponent("body"))
        return (try TestHTTPServer(root: directory), directory)
    }

    fileprivate static func read(_ input: HTTPSessionInput, _ count: Int) -> Int {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var total = 0
        while total < count {
            let got = input.read(&buffer, Int32(min(buffer.count, count - total)))
            if got <= 0 { break }
            total += Int(got)
        }
        return total
    }

    /// Waits for `count` bytes to be received, or a time limit (ten seconds): what came.
    private static func wait(for input: HTTPSessionInput, toReceive count: Int) async -> Int {
        for _ in 0..<100 where input.receivedBytes < count {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return input.receivedBytes
    }

    private static func settle(_ input: HTTPSessionInput) async -> Int {
        var last = -1
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            let received = input.receivedBytes
            if received == last { return received }
            last = received
        }
        return last
    }

    @Test("Held while opening: a few hundred kB of the body come, not the 4 MB; lifted, the rest comes and is read")
    func holdsAndLifts() async throws {
        let (server, directory) = try Self.server()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let transport = HTTPSessionTransport(source: server.url("body"), headers: [:]) { false }
        guard
            case .input(let held) = transport.open(
                server.url("body"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil, opening: .held)
        else {
            Issue.record("not served")
            return
        }
        #expect(Self.read(held, 4096) == 4096)
        let whileHeld = await Self.settle(held)
        #expect(whileHeld < 1 << 20, "\(whileHeld) bytes downloaded of a body nobody reads")

        // One opened with no such limit takes the whole body at once.
        guard
            case .input(let free) = transport.open(
                server.url("body"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil)
        else {
            Issue.record("not served")
            return
        }
        #expect(Self.read(free, 4096) == 4096)
        let whole = await Self.wait(for: free, toReceive: Self.size)
        #expect(whole == Self.size, "\(whole) bytes")

        // The opening is done: the held one is read on, to the end.
        transport.endOpening()
        let rest = Self.read(held, Self.size)
        #expect(rest == Self.size - 4096, "\(rest) bytes more")
        held.close()
        free.close()
    }
}

extension HTTPSessionOpeningLimitTests {
    @Test("Asked for in pieces while opening: the server sends a piece, the reader gets the whole body, intact")
    func readsAcrossPieces() async throws {
        let (server, directory) = try Self.server()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let transport = HTTPSessionTransport(source: server.url("body"), headers: [:]) { false }
        // From the middle, to a set end: pieces continue from the offset and stop at the end.
        let offset = 100_000
        let end = Self.size - 50_000
        guard
            case .input(let input) = transport.open(
                server.url("body"), offset: Int64(offset), end: Int64(end), cookies: nil, cookieOrigin: nil,
                opening: .held)
        else {
            Issue.record("not served")
            return
        }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let got = input.read(&buffer, Int32(buffer.count))
            if got <= 0 { break }
            bytes += buffer[0..<Int(got)]
            #expect(input.receivedBytes - bytes.count <= 2 * HTTPSessionInput.openingHighWater)
        }
        #expect(bytes.count == end - offset)
        let expected = (offset..<end).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        #expect(bytes == expected)
        input.close()
    }
}

extension HTTPSessionOpeningLimitTests {
    @Test("The rate of the link is the bytes over the time any input transferred, inputs side by side counted once")
    func throughputOfOverlappingInputs() async throws {
        let limit = HTTPSessionInput.OpeningLimit()
        #expect(limit.throughput == nil)
        // Three inputs over the same 0.6 s, 100 kB each: 300 kB in 0.6 s, not three times 100 kB over 0.6 s.
        limit.transferBegan()
        limit.transferBegan()
        limit.transferBegan()
        for _ in 0..<3 { limit.received(100_000) }
        try await Task.sleep(for: .milliseconds(600))
        for _ in 0..<3 { limit.transferEnded() }
        let rate = try #require(limit.throughput)
        #expect(rate > 2_000_000 && rate < 4_200_000, "\(rate) bit/s of 4 Mbit/s")
        // Idle time (waiting for an answer) isn't counted.
        try await Task.sleep(for: .milliseconds(300))
        #expect(try #require(limit.throughput) == rate)
        // Lifted, it is measured no more.
        limit.lift()
        limit.transferBegan()
        limit.received(1_000_000)
        try await Task.sleep(for: .milliseconds(300))
        limit.transferEnded()
        #expect(try #require(limit.throughput) == rate)
    }
}

extension HTTPSessionOpeningLimitTests {
    @Test("What an input brought while the demuxer opened, even after it, is no sample of the link's rate")
    func openingBytesAreNoSample() async throws {
        let (server, directory) = try Self.server()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let transport = HTTPSessionTransport(source: server.url("body"), headers: [:]) { false }
        guard
            case .input(let input) = transport.open(
                server.url("body"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil, opening: .held)
        else {
            Issue.record("not served")
            return
        }
        #expect(Self.read(input, 4096) == 4096)
        // The opening ends before the first piece has come whole: its rest arrives after.
        transport.endOpening()
        #expect(Self.read(input, Self.size) == Self.size - 4096)
        input.close()
        let sampled = transport.meter.take().reduce(0) { $0 + $1.bytes }
        #expect(sampled <= Self.size - HTTPSessionInput.openingHighWater, "\(sampled) bytes sampled of \(Self.size)")
    }
}

/// The session a transport's requests go through is replaced when its connection was lost (`HTTPSessionHolder`).
@Suite("Replaceable sessions", .serialized, .hostDependent, .networkServer)
struct HTTPSessionHolderTests {
    @Test("A connection lost mid-body is asked again on a new session, and the body comes whole")
    func lostConnectionMovesOnToANewSession() throws {
        let (server, directory) = try HTTPSessionOpeningLimitTests.server()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        server.setBehavior(.init(failure: .dropMidwayOnce), forPaths: { $0 == "body" })
        let transport = HTTPSessionTransport(source: server.url("body"), headers: [:]) { false }
        let before = transport.holder.session
        guard
            case .input(let input) = transport.open(
                server.url("body"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil)
        else {
            Issue.record("the request was not served")
            return
        }
        defer { input.close() }
        let total = HTTPSessionOpeningLimitTests.read(input, HTTPSessionOpeningLimitTests.size)
        #expect(total == HTTPSessionOpeningLimitTests.size, "\(total) of \(HTTPSessionOpeningLimitTests.size) bytes")
        #expect(transport.holder.session !== before, "the session that lost its connection is still the one asked")
    }

    @Test("A session is replaced once for the connection that was lost, whoever finds it gone first")
    func replacesOnce() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let holder = HTTPSessionHolder(configuration: .ephemeral, queue: queue)
        defer { holder.invalidate() }
        let first = holder.session
        holder.replace(first)
        let second = holder.session
        #expect(second !== first)
        // Another request that lost the same connection finds the session replaced already: it keeps the new one.
        holder.replace(first)
        #expect(holder.session === second)
        holder.replace(second)
        #expect(holder.session !== second)
    }

    @Test("The cookies an answer set go with the requests on the session that replaced the one that got them")
    func cookiesSurviveTheReplacement() throws {
        let (server, directory) = try HTTPSessionOpeningLimitTests.server()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        server.setBehavior(.init(setCookie: "token=abc; Path=/"), forPaths: { $0 == "body" })
        let transport = HTTPSessionTransport(source: server.url("body"), headers: [:]) { false }
        func open() -> HTTPSessionInput? {
            guard
                case .input(let input) = transport.open(
                    server.url("body"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil)
            else { return nil }
            return input
        }
        let first = try #require(open())
        _ = HTTPSessionOpeningLimitTests.read(first, 1_000)
        first.close()
        transport.holder.replace(transport.holder.session)
        let second = try #require(open())
        defer { second.close() }
        _ = HTTPSessionOpeningLimitTests.read(second, 1_000)
        let sent = server.requests.last?.cookie
        #expect(sent?.contains("token=abc") == true, "the request after the replacement sent \(sent ?? "no cookie")")
    }

    @Test("A session of the caller's own is never replaced")
    func fixedSessionStays() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let holder = HTTPSessionHolder(fixed: session)
        holder.replace(session)
        #expect(holder.session === session)
    }
}

extension HTTPSessionOpeningLimitTests {
    @Test("The link's rate leaves the skipped start out, and is told once measured, or once the link is proven slower")
    func linkRatePastTheSkip() async throws {
        // Measured: 256 kB past a skip of 100 kB, the skip's own time left out.
        let fast = HTTPSessionInput.OpeningLimit()
        fast.skip(100_000)
        fast.transferBegan()
        fast.received(100_000)
        #expect(fast.linkRate(limit: 3_000_000) == nil)
        try await Task.sleep(for: .milliseconds(200))
        fast.received(HTTPSessionInput.OpeningLimit.measuredBytes)
        let rate = try #require(fast.linkRate(limit: 3_000_000))
        // 256 kB in about 0.2 s: some 10 Mbit/s; with the skip counted it would be some 14.
        #expect(rate > 5_000_000 && rate < 11_000_000, "\(rate) bit/s")
        fast.transferEnded()

        // Proven slow: by the time a link at the limit would have brought the skip and the measure, less came.
        let slow = HTTPSessionInput.OpeningLimit()
        slow.skip(100_000)
        slow.transferBegan()
        slow.received(100_000)
        // 356 kB at 30 Mbit/s: 0.1 s.
        try await Task.sleep(for: .milliseconds(400))
        slow.received(50_000)
        let slower = try #require(slow.linkRate(limit: 30_000_000))
        // 50 kB past the skip in about 0.4 s: 1 Mbit/s.
        #expect(slower < 2_000_000, "\(slower) bit/s")
        slow.transferEnded()
        #expect(!slow.isTransferring)

        // Ended before either: no told rate, but the rate of what came, over more than half a second.
        let short = HTTPSessionInput.OpeningLimit()
        short.transferBegan()
        short.received(100_000)
        #expect(short.rateOfWhatCame == nil)
        try await Task.sleep(for: .milliseconds(600))
        short.transferEnded()
        #expect(short.linkRate(limit: 3_000_000) == nil)
        let whatCame = try #require(short.rateOfWhatCame)
        // 100 kB in about 0.6 s: some 1.3 Mbit/s.
        #expect(whatCame > 800_000 && whatCame < 1_400_000, "\(whatCame) bit/s")
    }

    @Test("The start's input is asked for whole and not held while opening; what comes after the opening is a sample")
    func startIsWholeAndSampledAfterTheOpening() async throws {
        let (server, directory) = try Self.server()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        // 4 MB in 2 s.
        server.setDefaultBehavior(.init(bytesPerSecond: Self.size / 2))
        let transport = HTTPSessionTransport(source: server.url("body"), headers: [:]) { false }
        guard
            case .input(let input) = transport.open(
                server.url("body"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil, opening: .start)
        else {
            Issue.record("not served")
            return
        }
        defer { input.close() }
        #expect(Self.read(input, 4096) == 4096)
        // Unread, it goes on past the opening's buffer.
        let whileOpening = await Self.wait(for: input, toReceive: 1 << 20)
        #expect(whileOpening >= 1 << 20, "\(whileOpening) bytes while opening")
        #expect(server.requests.allSatisfy { $0.range == nil }, "\(server.requests.map(\.range))")
        transport.endOpening()
        #expect(Self.read(input, Self.size) == Self.size - 4096)
        input.close()
        // What came after the opening is a sample; what came during it is not.
        let sampled = transport.meter.take().reduce(0) { $0 + $1.bytes }
        #expect(sampled > 0 && sampled <= Self.size - whileOpening, "\(sampled) bytes sampled of \(Self.size)")
    }
}
