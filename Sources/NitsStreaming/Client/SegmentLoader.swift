import CommonCrypto
import Foundation
import os

package enum SegmentLoadError: Error, Equatable {
    /// The load gave way to an abort (`HTTPSessionTransport.shouldAbort`): a seek, a close.
    case interrupted
    /// The server's answer, as FFmpeg's error for it (`AVERROR_HTTP_*`) or an I/O error.
    case failed(Int32)
    /// The address wasn't served by the transport (not HTTP(S), or answered in a way it leaves to FFmpeg).
    case notServed(URL)
    /// Encryption Nits doesn't decrypt (SAMPLE-AES, a key format other than `identity`, a key without an address).
    case unsupportedEncryption(String)
    /// The key isn't the 16 bytes of AES-128.
    case invalidKey(URL, count: Int)
    /// The bytes aren't what AES-128-CBC with PKCS#7 padding makes (CommonCrypto's status).
    case decryption(Int32)
    /// A byte range the server answered whole, and the answer is shorter than the range ends.
    case rangeOutsideFile(URL)
}

/// Downloads the bytes of HLS segments, init sections and keys on `HTTPSessionTransport`, one request at a time:
/// every request is a task of its own whose transfer the transport measures apart from its answer
/// (`NetworkTransferMeter`, for adaptive bitrate), and whose connections the session keeps open. A segment arrives
/// whole and decrypted (AES-128, CBC, the whole segment one stream, as RFC 8216 4.3.2.4 has it); init sections and
/// keys are kept, as many segments share them.
///
/// Blocking, for the thread that reads a rendition (the demuxer's read-ahead, FFmpeg's own calls): interruptible
/// through the transport's `shouldAbort`, checked every 50 ms while it waits for data.
package final class SegmentLoader: Sendable {
    private struct Cache {
        var initSections: [InitSection: Data] = [:]
        var keys: [URL: Data] = [:]
    }

    fileprivate let transport: HTTPSessionTransport
    /// Local files are read too: the playlist itself is a file (a saved manifest). A playlist served over HTTP(S) never
    /// reaches the disk, whatever it lists.
    package let allowsFiles: Bool
    private let cache: OSAllocatedUnfairLock<Cache>
    /// Interrupts this loader's requests besides the transport's `shouldAbort` (`aborting(when:)`).
    private let abort: (@Sendable () -> Bool)?
    /// Told how far each segment download has got while the reader waits for it (`watching`).
    private let relay: SegmentProgressRelay?
    /// Where the addresses the playlists list really go, and what renews them (`PlaylistSource.address(of:)`).
    private let addresses: (any PlaylistSource)?
    /// Init sections and keys kept at most: a stream has a few; a playlist that changes them every segment (a key per
    /// segment is common, rotating ones) must not grow the cache for good.
    static let cacheLimit = 32
    /// A run's first segment is retained to be replayed (`SegmentBody.replayedBody`), up to this
    /// many bytes (a 4K segment of six seconds is some 30 MB).
    static let retainLimit = 48 << 20
    private static let readSize = 64 << 10

    package init(transport: HTTPSessionTransport, allowsFiles: Bool = false, addresses: (any PlaylistSource)? = nil) {
        self.transport = transport
        self.allowsFiles = allowsFiles
        self.addresses = addresses
        cache = OSAllocatedUnfairLock(initialState: Cache())
        abort = nil
        relay = nil
    }

    private init(sharing loader: SegmentLoader, abort: (@Sendable () -> Bool)?, relay: SegmentProgressRelay?) {
        transport = loader.transport
        allowsFiles = loader.allowsFiles
        addresses = loader.addresses
        cache = loader.cache
        self.abort = abort
        self.relay = relay
    }

    /// The same loader whose segment downloads tell `relay` how far they have got.
    func watching(_ relay: SegmentProgressRelay) -> SegmentLoader {
        SegmentLoader(sharing: self, abort: abort, relay: relay)
    }

    /// The same loader (transport, kept init sections and keys) whose requests also give way to `abort`: a probe of the
    /// opening that another one beat (`StreamingInput`'s race), stopped without stopping the stream.
    func aborting(when abort: @escaping @Sendable () -> Bool) -> SegmentLoader {
        SegmentLoader(sharing: self, abort: abort, relay: relay)
    }

    /// Whether this loader's requests give way now: the transport's abort or its own.
    var isAborted: Bool { transport.shouldAbort() || abort?() == true }

    /// The segment's bytes, decrypted.
    func segment(_ segment: MediaSegment) throws(SegmentLoadError) -> Data {
        var data = try download(segment.url, range: segment.byteRange)
        if let key = segment.key { data = try decrypt(data, key: key, iv: segment.initializationVector) }
        return data
    }

    /// An init section whose bytes are already read (the start of a file whose layout was found from it): not asked for again.
    func keep(_ section: InitSection, data: Data) {
        cache.withLock { cache in
            if cache.initSections.count >= Self.cacheLimit { cache.initSections.removeAll() }
            cache.initSections[section] = data
        }
    }

    /// The init section's bytes, decrypted (one load per `EXT-X-MAP` in effect).
    func initSection(_ section: InitSection) throws(SegmentLoadError) -> Data {
        if let cached = cache.withLock({ $0.initSections[section] }) { return cached }
        var loaded = try download(section.url, range: section.byteRange)
        if let key = section.key { loaded = try decrypt(loaded, key: key, iv: section.initializationVector) }
        let data = loaded
        cache.withLock { cache in
            if cache.initSections.count >= Self.cacheLimit { cache.initSections.removeAll() }
            cache.initSections[section] = data
        }
        return data
    }

    /// The bytes of `range` of `url`: a part of a file that is not a segment (a DASH file's index).
    func bytes(of url: URL, range: ByteRange) throws(SegmentLoadError) -> Data {
        try download(url, range: range)
    }

    /// A playlist's text and where it was served from, after redirects (its relative URIs are read against that).
    func playlist(_ url: URL) throws(SegmentLoadError) -> (data: Data, servedFrom: URL) {
        if url.isFileURL {
            guard allowsFiles else { throw .notServed(url) }
            return (try file(url, range: nil), url)
        }
        switch transport.open(
            url.absoluteString, offset: 0, end: nil, followsRedirects: true,
            abort: abort)
        {
        case .input(let input):
            let servedFrom = input.servedFrom ?? url
            return (try read(input), servedFrom)
        case .failed(let code):
            throw code == FFmpegErrorCode.exit ? .interrupted : .failed(code)
        case .notServed:
            throw .notServed(url)
        }
    }

    /// The `Date` of the answer at `url`, its body not read (`UTCTiming` `http-head`): the server's clock, to the second.
    func serverDate(of url: URL) throws(SegmentLoadError) -> Date? {
        guard !url.isFileURL else { return nil }
        switch transport.open(
            url.absoluteString, offset: 0, end: nil, followsRedirects: true,
            abort: abort)
        {
        case .input(let input):
            defer { input.close() }
            return input.serverDate
        case .failed(let code):
            throw code == FFmpegErrorCode.exit ? .interrupted : .failed(code)
        case .notServed:
            throw .notServed(url)
        }
    }

    // MARK: Decryption

    private func decrypt(_ data: Data, key: HLSKey, iv: [UInt8]?) throws(SegmentLoadError) -> Data {
        guard key.isDecryptable, let keyURL = key.url, let iv, iv.count == kCCBlockSizeAES128 else {
            throw .unsupportedEncryption(key.method == .aes128 ? "AES-128 with \(key.keyFormat)" : "\(key.method)")
        }
        let keyBytes = try keyData(keyURL)
        guard keyBytes.count == kCCKeySizeAES128 else { throw .invalidKey(keyURL, count: keyBytes.count) }
        guard !data.isEmpty else { return data }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var produced = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                keyBytes.withUnsafeBytes { keyPointer in
                    iv.withUnsafeBytes { ivPointer in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyPointer.baseAddress, kCCKeySizeAES128, ivPointer.baseAddress, input.baseAddress,
                            data.count, out.baseAddress, out.count, &produced)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw .decryption(status) }
        output.removeSubrange(produced...)
        return output
    }

    private func keyData(_ url: URL) throws(SegmentLoadError) -> Data {
        if let cached = cache.withLock({ $0.keys[url] }) { return cached }
        let data = try download(url, range: nil)
        cache.withLock { cache in
            if cache.keys.count >= Self.cacheLimit { cache.keys.removeAll() }
            cache.keys[url] = data
        }
        return data
    }

    // MARK: Download

    /// Asks `request` for `url` at the address the source gives it now (`PlaylistSource.address(of:)`); once more at
    /// the address as renewed when the server refuses one the source gave (403: the signature expired before the source
    /// renewed it). A second refusal is the server's.
    private func open(
        _ url: URL, _ request: (String) -> HTTPSessionTransport.Opened
    ) -> HTTPSessionTransport.Opened {
        guard let addresses else { return request(url.absoluteString) }
        guard let address = addresses.address(of: url) else { return .failed(FFmpegErrorCode.httpNotFound) }
        let opened = request(address.absoluteString)
        guard address != url, case .failed(let code) = opened, code == FFmpegErrorCode.httpForbidden,
            addresses.renewAddresses(shouldAbort: { isAborted }),
            let renewed = addresses.address(of: url)
        else { return opened }
        return request(renewed.absoluteString)
    }

    /// The body of `url`, or of its `range`. A range the server answers whole (the transport leaves that to FFmpeg
    /// otherwise) is asked for as the file and cut.
    private func download(_ url: URL, range: ByteRange?) throws(SegmentLoadError) -> Data {
        if let range, range.length == 0 { return Data() }
        if url.isFileURL { return try file(url, range: range) }
        let opened = open(url) { address in
            transport.open(
                address, offset: range?.offset ?? 0, end: range.map { $0.offset + $0.length }, followsRedirects: true,
                abort: abort)
        }
        switch opened {
        case .input(let input):
            // A server may answer a range with more than was asked for (206 with a longer range).
            let body = try read(input)
            if let range, Int64(body.count) > range.length { return body.prefix(Int(range.length)) }
            return body
        case .failed(let code):
            throw code == FFmpegErrorCode.exit ? .interrupted : .failed(code)
        case .notServed:
            guard let range else { throw .notServed(url) }
            return try wholeFile(url, range: range)
        }
    }

    /// A byte range the server answers whole: the file, cut to the range.
    private func wholeFile(_ url: URL, range: ByteRange) throws(SegmentLoadError) -> Data {
        guard
            case .input(let input) = open(
                url,
                {
                    transport.open(
                        $0, offset: 0, end: nil, followsRedirects: true, abort: abort)
                })
        else { throw .notServed(url) }
        let whole = try read(input, limit: Int(range.range.upperBound))
        guard whole.count >= range.range.upperBound else { throw .rangeOutsideFile(url) }
        return whole.subdata(in: Int(range.offset)..<Int(range.range.upperBound))
    }

    /// A segment with a byte range, as the file cut (no request for the range first: the server has answered it whole).
    fileprivate func wholeFileSegment(_ segment: MediaSegment) throws(SegmentLoadError) -> Data {
        guard let range = segment.byteRange else { throw .notServed(segment.url) }
        return try wholeFile(segment.url, range: range)
    }

    private func read(_ input: HTTPSessionInput, limit: Int = .max) throws(SegmentLoadError) -> Data {
        defer { input.close() }
        var body = Data()
        if let length = input.answeredLength, length > 0, length < Int64(Int32.max) {
            body.reserveCapacity(Int(length))
        }
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress!, Int32($0.count)) }
            if count > 0 {
                body.append(buffer, count: Int(count))
                if body.count >= limit { return body }
            } else if count == FFmpegErrorCode.eof || count == 0 {
                // A body shorter than the server announced is a connection that dropped, not a short segment.
                if let length = input.answeredLength, length > 0, Int64(body.count) < length, limit == .max {
                    throw .failed(-EIO)
                }
                return body
            } else if count == FFmpegErrorCode.exit {
                throw .interrupted
            } else {
                throw .failed(count)
            }
        }
    }
}

/// Where a lane's segment downloads tell how far they have got (`SegmentLoader.watching`): the lane sets its
/// handler once it is made, after the loader it reads with. Called on the thread that reads the segment, while it waits.
package final class SegmentProgressRelay: @unchecked Sendable {
    var handler: ((MediaSegment, HTTPSessionInput.Progress) -> Void)?
    /// The download last begun, for a check made while the thread that reads is idle (`StreamingLane.pollProgress`): the
    /// download goes on in the background while the read-ahead is full, and nothing waits for it then.
    private let latest = OSAllocatedUnfairLock<(segment: MediaSegment, input: Weak<HTTPSessionInput>)?>(
        initialState: nil)

    package final class Weak<T: AnyObject>: @unchecked Sendable {
        weak var value: T?
        package init(_ value: T) { self.value = value }
    }

    func tell(_ segment: MediaSegment, _ progress: HTTPSessionInput.Progress) {
        handler?(segment, progress)
    }

    func began(_ segment: MediaSegment, _ input: HTTPSessionInput) {
        latest.withLock { $0 = (segment, Weak(input)) }
    }

    /// The segment last begun and how far its download has got; nil once it is through, closed or gone.
    var inFlight: (segment: MediaSegment, progress: HTTPSessionInput.Progress)? {
        guard let (segment, weak) = latest.withLock({ $0 }), let input = weak.value else { return nil }
        let progress = input.progress
        return progress.isFinished ? nil : (segment, progress)
    }
}

/// A segment's bytes as they come: the demuxer starts on a segment's first bytes while the rest is still on the way
/// (`SegmentLoader.segmentBody`), as FFmpeg's `hls.c` reads one, so the first picture of a segment does not wait for
/// the whole of it (30 MB for a 4K segment of six seconds, on a link that may take seconds to carry them). Not for an
/// encrypted segment, which is decrypted as one stream (`SegmentLoader.segment`), nor one the transport leaves to
/// the loader's other path: those arrive whole.
///
/// Blocking, interruptible as the loader's downloads are. A body that `retains` what it hands out (a run's first
/// segment, which the opening reads to describe the picture and the demuxer then goes back to the start of) can be
/// `replayed`: a new body gives the bytes read so far again and goes on with the same download, up to
/// `SegmentLoader.retainLimit` bytes.
package final class SegmentBody {
    private enum Source {
        case data(Data)
        case input(HTTPSessionInput, limit: Int64?)
    }

    private var source: Source
    private var offset = 0
    private var received = 0
    private var buffer: [UInt8]
    /// Bytes to give again before the download's (a replay).
    private var replay = Data()
    private var replayed = 0
    /// What was handed out so far, when retaining; nil once it outgrew the limit.
    private var retained: Data?
    private var isFinished = false
    /// The download was read through, and closed.
    private var isComplete = false

    package init(data: Data) {
        source = .data(data)
        buffer = []
    }

    fileprivate init(input: HTTPSessionInput, limit: Int64?, retains: Bool) {
        source = .input(input, limit: limit)
        buffer = [UInt8](repeating: 0, count: 64 << 10)
        retained = retains ? Data() : nil
    }

    /// The next bytes, at most `count`; nil at the end of the segment.
    func next(_ count: Int = 64 << 10) throws(SegmentLoadError) -> Data? {
        if replayed < replay.count {
            let end = min(replayed + count, replay.count)
            defer { replayed = end }
            return replay.subdata(in: (replay.startIndex + replayed)..<(replay.startIndex + end))
        }
        switch source {
        case .data(let data):
            guard offset < data.count else { return nil }
            defer { offset += min(count, data.count - offset) }
            return data.subdata(
                in: (data.startIndex + offset)..<(data.startIndex + offset + min(count, data.count - offset)))
        case .input(let input, let limit):
            var wanted = min(count, buffer.count)
            if let limit {
                wanted = Int(min(Int64(wanted), limit - Int64(received)))
                if wanted <= 0 { return end(input, isComplete: true) }
            }
            let result = buffer.withUnsafeMutableBufferPointer { input.read($0.baseAddress!, Int32(wanted)) }
            if result > 0 {
                received += Int(result)
                let chunk = Data(buffer[0..<Int(result)])
                if retained != nil {
                    retained?.append(chunk)
                    if received > SegmentLoader.retainLimit { retained = nil }
                }
                return chunk
            }
            if result == FFmpegErrorCode.eof || result == 0 {
                // A body shorter than the server announced (or than the range) is a connection that dropped.
                let expected = limit ?? input.answeredLength.flatMap { $0 > 0 ? $0 : nil }
                if let expected, Int64(received) < expected {
                    throw .failed(-EIO)
                }
                return end(input, isComplete: true)
            }
            throw result == FFmpegErrorCode.exit ? .interrupted : .failed(result)
        }
    }

    /// The download tells `relay` how far it has got, for a body that a loader other than the lane's made (a probe's).
    func watch(_ relay: SegmentProgressRelay, segment: MediaSegment) {
        guard case .input(let input, _) = source else { return }
        input.onProgress = { [segment] progress in relay.tell(segment, progress) }
        relay.began(segment, input)
    }

    /// Everything that is left.
    func rest() throws(SegmentLoadError) -> Data {
        var all = Data()
        while let chunk = try next() { all.append(chunk) }
        return all
    }

    private func end(_ input: HTTPSessionInput, isComplete: Bool) -> Data? {
        if !isFinished {
            isFinished = true
            self.isComplete = isComplete
            input.close()
        }
        return nil
    }

    /// A body that gives what this one handed out again, and goes on with its download, which it takes over: this one
    /// is done with. Nil when it didn't retain (or outgrew the limit): the segment is to be asked for again.
    func replayedBody() -> SegmentBody? {
        if case .data(let data) = source, !isFinished {
            isFinished = true
            return SegmentBody(data: data)
        }
        guard let kept = retained, !isFinished || isComplete else { return nil }
        let body: SegmentBody
        switch source {
        case .data(let data):
            body = SegmentBody(data: data)
        case .input(let input, let limit):
            if isComplete {
                body = SegmentBody(data: kept)
            } else {
                body = SegmentBody(input: input, limit: limit, retains: true)
                body.received = received
                body.replay = kept
                body.retained = kept
            }
        }
        // The download is the new body's now.
        isFinished = true
        isComplete = false
        source = .data(Data())
        return body
    }

    /// Gives the download up for another's, so that a read of it is interrupted (`HTTPSessionInput.abandon`); not for a body
    /// held in memory.
    func abandon() {
        guard case .input(let input, _) = source else { return }
        input.abandon()
    }

    /// Gives the download up (the segment is not read to its end).
    package func close() {
        guard case .input(let input, _) = source, !isFinished else { return }
        isFinished = true
        input.close()
    }

    deinit { close() }
}

extension SegmentLoader {
    /// The segment's bytes as they arrive (`SegmentBody`): the download starts now and the caller reads as it comes.
    /// `opening`: a probe of the stream's description (`StreamingLane.probe`), which FFmpeg's analysis reads as far as it
    /// needs: the request is the opening's (`HTTPSessionTransport.open(opening:)`), counted in its rate and in no
    /// adaptive-bitrate sample; held to a small buffer so that the server sends little more than is read, but for the
    /// segment playback starts on (`.start`). `retains`: the body can be `replayed`.
    func segmentBody(
        _ segment: MediaSegment, opening: HTTPSessionInput.Opening? = nil, retains: Bool = false
    ) throws(SegmentLoadError) -> SegmentBody {
        if segment.key != nil || segment.byteRange?.length == 0 {
            return SegmentBody(data: try self.segment(segment))
        }
        if segment.url.isFileURL { return SegmentBody(data: try file(segment.url, range: segment.byteRange)) }
        let range = segment.byteRange
        var onProgress: (@Sendable (HTTPSessionInput.Progress) -> Void)?
        if let relay { onProgress = { [segment] progress in relay.tell(segment, progress) } }
        let opened = open(segment.url) { address in
            transport.open(
                address, offset: range?.offset ?? 0, end: range.map { $0.offset + $0.length },
                opening: opening, followsRedirects: true, abort: abort,
                onProgress: onProgress)
        }
        switch opened {
        case .input(let input):
            relay?.began(segment, input)
            return SegmentBody(input: input, limit: range?.length, retains: retains)
        case .failed(let code):
            throw code == FFmpegErrorCode.exit ? .interrupted : .failed(code)
        case .notServed:
            // A range the server answers whole (the request is already made once): the file, cut.
            return SegmentBody(data: try wholeFileSegment(segment))
        }
    }
}

extension SegmentLoader {
    /// A local file's bytes, or those of its `range` (mapped, not copied, while it is read).
    fileprivate func file(_ url: URL, range: ByteRange?) throws(SegmentLoadError) -> Data {
        guard allowsFiles else { throw .notServed(url) }
        let whole: Data
        do {
            whole = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            // The POSIX error underneath (not found, not permitted, ...), as FFmpeg's own file protocol reports it.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw .failed(underlying?.domain == NSPOSIXErrorDomain ? -Int32(underlying?.code ?? Int(EIO)) : -EIO)
        }
        guard let range else { return whole }
        guard whole.count >= range.range.upperBound else { throw .rangeOutsideFile(url) }
        return whole.subdata(in: Int(range.offset)..<Int(range.range.upperBound))
    }
}
