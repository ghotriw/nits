import Foundation
import Testing

@testable import NitsCore

/// The rate a transfer reports is the link's: every byte received while it ran, whoever's (`Transfer.linkBytes`), as at a
/// variant switch, where the old variant's segment is read on while the new one's comes.
@Suite("Network transfer meter", .serialized, .hostDependent, .networkServer)
struct NetworkTransferMeterTests {
    private static func files(_ sizes: [String: Int]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NitsMeter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, size) in sizes {
            try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(
                to: directory.appendingPathComponent(name))
        }
        return directory
    }

    private static func read(_ input: HTTPSessionInput, _ count: Int) -> Int {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var total = 0
        while total < count {
            let got = input.read(&buffer, Int32(min(buffer.count, count - total)))
            if got <= 0 { break }
            total += Int(got)
        }
        return total
    }

    @Test("A short transfer inside a long one adds its bytes to the long one's, whatever the timing")
    func shortInsideLong() throws {
        let long = 3 << 20
        let short = 300 << 10
        let directory = try Self.files(["long": long, "short": short])
        let server = try TestHTTPServer(root: directory)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        // Slow enough that the long one is still coming when the short one has come (3 s against some 0.6 sharing).
        server.setLinkRate(1 << 20)
        let transport = HTTPSessionTransport(source: server.url("long"), headers: [:]) { false }
        guard
            case .input(let longInput) = transport.open(
                server.url("long"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil),
            case .input(let shortInput) = transport.open(
                server.url("short"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil)
        else {
            Issue.record("not served")
            return
        }
        // Both run side by side; the short one comes whole while the long one is still on its way.
        #expect(Self.read(shortInput, short) == short)
        #expect(longInput.receivedBytes < long, "The long one had come already: no overlap")
        #expect(Self.read(longInput, long) == long)
        // Ended: reported when the input is read to its end or closed.
        shortInput.close()
        longInput.close()

        // Each leaves out its first delivery, which came in no time of its own; so does the link's count from then on.
        let transfers = transport.meter.take()
        let longTransfer = try #require(transfers.max { $0.bytes < $1.bytes })
        let shortTransfer = try #require(transfers.min { $0.bytes < $1.bytes })
        #expect(longTransfer.bytes < long && longTransfer.bytes > long - (64 << 10), "\(longTransfer.bytes)")
        #expect(shortTransfer.bytes < short && shortTransfer.bytes > short - (64 << 10), "\(shortTransfer.bytes)")
        // The short one came whole inside the long one's window, its first delivery too.
        let others = longTransfer.linkBytes - longTransfer.bytes
        #expect(others == short, "The long one's window held \(others) bytes of others, of \(short)")
        #expect(shortTransfer.linkBytes <= long + short)
    }

    /// The stand of 2026-11-13: a request cut after its first piece of 16 KB, which came with the answer, read 97–167
    /// Mbit/s on a 2 Mbit/s link, and took the estimate up two rungs.
    @Test("A body that came in one delivery, with its answer, is no sample: it took no time of its own")
    func oneDeliveryIsNoSample() throws {
        let size = Int(HTTPSessionTransport.oneTimeRequestBytes)
        let directory = try Self.files(["piece": size])
        let server = try TestHTTPServer(root: directory)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let transport = HTTPSessionTransport(source: server.url("piece"), headers: [:]) { false }
        guard
            case .input(let input) = transport.open(
                server.url("piece"), offset: 0, end: nil, cookies: nil, cookieOrigin: nil)
        else {
            Issue.record("not served")
            return
        }
        #expect(Self.read(input, size) == size)
        input.close()
        let transfers = transport.meter.take()
        #expect(transfers.isEmpty, "Sampled: \(transfers.map { "\($0.bytes) B in \($0.seconds) s" })")
    }
}
