import Foundation
import Network
import os

/// A minimal HTTP/1.1 server on the loopback interface for streaming tests: serves the files of a directory over
/// `GET` (keep-alive, single `Range`), each path at a rate, after a delay or failing as a test sets it, and logs what
/// was asked for. Not a web server: what FFmpeg's HTTP client needs, nothing more.
///
/// The rate paces whole chunks with `Task.sleep`, so a response arrives at about that rate; TCP windows, loss and
/// latency of a real network are not modelled (check those by hand, with Network Link Conditioner).
final class TestHTTPServer: Sendable {
    /// How a path is served.
    struct Behavior: Sendable {
        /// Bytes a second, unlimited when nil. Read again for every chunk: a change applies to responses under way.
        var bytesPerSecond: Int?
        /// Before the response.
        var delay: Duration = .zero
        var failure: Failure?
        /// The connection closes after the response (`Connection: close`), as with a server that keeps none open.
        var closesConnection = false
        /// Bytes a range response holds at most, fewer than asked for: a server may send a range in parts.
        var rangeLimit: Int?
        /// Answered with a redirect (302) to this path, relative to the served directory.
        var redirect: String?
    }

    enum Failure: Sendable {
        /// This status, without a body.
        case status(Int)
        /// The connection is closed half way through the body.
        case dropMidway
        /// No response at all, until the server stops.
        case hang
    }

    struct Request: Sendable {
        let path: String
        let time: ContinuousClock.Instant
        /// The `User-Agent` header: FFmpeg's starts with `Lavf`.
        var userAgent: String?
        /// The `Range` header.
        var range: String?
    }

    private struct State {
        /// Bytes a second all responses share, as on a real link (FFmpeg's HLS client opens the next segment while
        /// it reads one, and reads two variants while it switches).
        var linkRate: Int?
        /// When the link is free for the next chunk.
        var linkFreeAt = ContinuousClock.now
        var defaultBehavior = Behavior()
        /// Bodies made per request instead of read from a file (a live playlist).
        var responders: [String: @Sendable () -> Data] = [:]
        var behaviors: [(matches: @Sendable (String) -> Bool, behavior: Behavior)] = []
        var requests: [Request] = []
        var connections: [ObjectIdentifier: NWConnection] = [:]
    }

    private let root: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Nits.TestHTTPServer")
    private let state = OSAllocatedUnfairLock(initialState: State())
    let port: UInt16

    /// Starts serving `root` on a free loopback port.
    init(root: URL) throws {
        self.root = root.standardizedFileURL
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        let failed = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failed.withLock { $0 = error }
                ready.signal()
            default:
                break
            }
        }
        let state = self.state
        let queue = self.queue
        let servedRoot = self.root
        listener.newConnectionHandler = { connection in
            state.withLock { $0.connections[ObjectIdentifier(connection)] = connection }
            connection.start(queue: queue)
            Task { await Self.serve(connection, root: servedRoot, state: state) }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw failed.withLock { $0 } ?? URLError(.cannotConnectToHost)
        }
        if let error = failed.withLock({ $0 }) {
            listener.cancel()
            throw error
        }
        self.port = port
    }

    deinit { stop() }

    /// `http://127.0.0.1:port/` followed by `path`, relative to the served directory.
    func url(_ path: String) -> String {
        "http://127.0.0.1:\(port)/\(path)"
    }

    /// Bytes a second shared by all responses, unlimited when nil: the rate of the link, where a behavior's
    /// `bytesPerSecond` limits each response on its own.
    func setLinkRate(_ bytesPerSecond: Int?) {
        state.withLock { state in
            state.linkRate = bytesPerSecond
            state.linkFreeAt = .now
        }
    }

    /// Answers `path` with what `body` makes at each request, instead of the file.
    func setResponder(forPath path: String, body: @escaping @Sendable () -> Data) {
        state.withLock { $0.responders[path] = body }
    }

    /// How paths without a behavior of their own are served.
    func setDefaultBehavior(_ behavior: Behavior) {
        state.withLock { $0.defaultBehavior = behavior }
    }

    /// How paths `matches` accepts are served; the latest behavior set for a path wins.
    func setBehavior(_ behavior: Behavior, forPaths matches: @escaping @Sendable (String) -> Bool) {
        state.withLock { $0.behaviors.append((matches, behavior)) }
    }

    /// Paths asked for so far (without the leading slash), in order.
    var requests: [Request] {
        state.withLock { $0.requests }
    }

    func stop() {
        listener.cancel()
        let connections = state.withLock { state in
            defer { state.connections.removeAll() }
            return Array(state.connections.values)
        }
        for connection in connections {
            connection.cancel()
        }
    }

    // MARK: - Serving

    private static func behavior(for path: String, in state: OSAllocatedUnfairLock<State>) -> Behavior {
        state.withLock { state in
            state.behaviors.last { $0.matches(path) }?.behavior ?? state.defaultBehavior
        }
    }

    /// Answers the requests of one connection until the client closes it.
    private static func serve(_ connection: NWConnection, root: URL, state: OSAllocatedUnfairLock<State>) async {
        defer {
            connection.cancel()
            state.withLock { _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        }
        var buffer = Data()
        while true {
            // The request head ends with an empty line; a GET has no body.
            while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard let received = await receive(on: connection), !received.isEmpty else { return }
                buffer.append(received)
            }
            let headEnd = buffer.range(of: Data("\r\n\r\n".utf8))!
            let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
            buffer.removeSubrange(..<headEnd.upperBound)

            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            guard requestLine.count >= 2, requestLine[0] == "GET" else {
                _ = await send(response(status: 405, headers: [:]), on: connection)
                return
            }
            let target = String(requestLine[1])
            let path =
                String(target.split(separator: "?").first ?? "").removingPercentEncoding?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let request = Request(path: path, time: .now, userAgent: headers["user-agent"], range: headers["range"])
            state.withLock { $0.requests.append(request) }

            let behavior = behavior(for: path, in: state)
            if behavior.delay > .zero { try? await Task.sleep(for: behavior.delay) }
            if let redirect = behavior.redirect {
                let headers = ["Location": "/" + redirect, "Content-Length": "0"]
                guard await send(response(status: 302, headers: headers), on: connection) else { return }
                continue
            }
            switch behavior.failure {
            case .hang:
                // Until the client or the server closes the connection.
                while await receive(on: connection) != nil {}
                return
            case .status(let status):
                guard await send(response(status: status, headers: ["Content-Length": "0"]), on: connection) else {
                    return
                }
                continue
            case .dropMidway, nil:
                break
            }

            let file = root.appendingPathComponent(path).standardizedFileURL
            let responder = state.withLock { $0.responders[path] }
            guard
                let contents = responder?()
                    ?? (file.path.hasPrefix(root.path + "/") ? try? Data(contentsOf: file) : nil)
            else {
                guard await send(response(status: 404, headers: ["Content-Length": "0"]), on: connection) else {
                    return
                }
                continue
            }
            var body = contents[...]
            var status = 200
            var responseHeaders = ["Content-Type": contentType(of: path), "Accept-Ranges": "bytes"]
            if var range = headers["range"].flatMap({ byteRange($0, size: contents.count) }) {
                if let limit = behavior.rangeLimit {
                    range = range.lowerBound...min(range.upperBound, range.lowerBound + limit - 1)
                }
                body = contents[range]
                status = 206
                responseHeaders["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(contents.count)"
            }
            responseHeaders["Content-Length"] = String(body.count)
            if behavior.closesConnection { responseHeaders["Connection"] = "close" }
            guard await send(response(status: status, headers: responseHeaders), on: connection) else { return }

            let dropAt = behavior.failure == nil ? Int.max : body.count / 2
            guard await sendBody(body, until: dropAt, path: path, on: connection, state: state) else { return }
            if behavior.closesConnection || headers["connection"]?.lowercased() == "close" { return }
        }
    }

    /// Sends `body` in chunks at the path's current rate; false when the connection failed or `dropAt` was reached.
    private static func sendBody(
        _ body: Data.SubSequence, until dropAt: Int, path: String, on connection: NWConnection,
        state: OSAllocatedUnfairLock<State>
    ) async -> Bool {
        let chunkSize = 16 << 10
        var sent = 0
        var paced = (start: ContinuousClock.now, bytes: 0, rate: Int?.none)
        while sent < body.count {
            let end = min(sent + chunkSize, body.count, dropAt)
            guard end > sent else { return false }
            let chunk = body[(body.startIndex + sent)..<(body.startIndex + end)]
            // The chunk's turn on the link, after the chunks of every response sent before it.
            let slot = state.withLock { state -> ContinuousClock.Instant? in
                guard let rate = state.linkRate, rate > 0 else { return nil }
                let start = max(ContinuousClock.now, state.linkFreeAt)
                state.linkFreeAt = start + .seconds(Double(chunk.count) / Double(rate))
                return state.linkFreeAt
            }
            if let slot, slot > .now { try? await Task.sleep(until: slot) }
            guard await send(Data(chunk), on: connection) else { return false }
            sent = end
            if sent >= dropAt { return false }

            // Paced from the last rate change, so a new rate applies from now on.
            let rate = behavior(for: path, in: state).bytesPerSecond
            if rate != paced.rate { paced = (.now, 0, rate) }
            paced.bytes += chunk.count
            if let rate, rate > 0 {
                let due = paced.start + .seconds(Double(paced.bytes) / Double(rate))
                if due > .now { try? await Task.sleep(until: due) }
            }
        }
        return true
    }

    private static func receive(on connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: isComplete || error != nil ? nil : Data())
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
        }
    }

    private static func response(status: Int, headers: [String: String]) -> Data {
        let reason =
            [200: "OK", 206: "Partial Content", 302: "Found", 404: "Not Found", 405: "Method Not Allowed"][status]
            ?? "Error"
        let lines = ["HTTP/1.1 \(status) \(reason)"] + headers.sorted { $0.key < $1.key }.map { "\($0): \($1)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n`, clamped to the file.
    private static func byteRange(_ header: String, size: Int) -> ClosedRange<Int>? {
        guard header.hasPrefix("bytes="), size > 0, !header.contains(",") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 {
            return max(size - suffix, 0)...(size - 1)
        }
        guard let start = Int(bounds[0]), start < size else { return nil }
        let end = Int(bounds[1]).map { min($0, size - 1) } ?? size - 1
        return start <= end ? start...end : nil
    }

    private static func contentType(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4", "m4s": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
