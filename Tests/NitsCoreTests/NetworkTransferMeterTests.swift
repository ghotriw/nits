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

        let transfers = transport.meter.take()
        let longTransfer = try #require(transfers.first { $0.bytes == long })
        let shortTransfer = try #require(transfers.first { $0.bytes == short })
        #expect(longTransfer.linkBytes == long + short, "The long one's window held \(longTransfer.linkBytes) bytes")
        #expect(shortTransfer.linkBytes <= long + short)
    }
}
