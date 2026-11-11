import CommonCrypto
import Foundation
import os

enum HLSSegmentLoadError: Error, Equatable {
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
final class HLSSegmentLoader: Sendable {
    private struct Cache {
        var initSections: [HLSInitSection: Data] = [:]
        var keys: [URL: Data] = [:]
    }

    fileprivate let transport: HTTPSessionTransport
    /// Local files are read too: the playlist itself is a file (a saved manifest). A playlist served over HTTP(S) never
    /// reaches the disk, whatever it lists.
    let allowsFiles: Bool
    private let cache: OSAllocatedUnfairLock<Cache>
    /// Interrupts this loader's requests besides the transport's `shouldAbort` (`aborting(when:)`).
    private let abort: (@Sendable () -> Bool)?
    /// Init sections and keys kept at most: a stream has a few; a playlist that changes them every segment (a key per
    /// segment is common, rotating ones) must not grow the cache for good.
    static let cacheLimit = 32
    /// A run's first segment is retained to be replayed (`HLSSegmentBody.replayedBody`), up to this
    /// many bytes (a 4K segment of six seconds is some 30 MB).
    static let retainLimit = 48 << 20
    private static let readSize = 64 << 10

    init(transport: HTTPSessionTransport, allowsFiles: Bool = false) {
        self.transport = transport
        self.allowsFiles = allowsFiles
        cache = OSAllocatedUnfairLock(initialState: Cache())
        abort = nil
    }

    private init(sharing loader: HLSSegmentLoader, abort: @escaping @Sendable () -> Bool) {
        transport = loader.transport
        allowsFiles = loader.allowsFiles
        cache = loader.cache
        self.abort = abort
    }

    /// The same loader (transport, kept init sections and keys) whose requests also give way to `abort`: a probe of the
    /// opening that another one beat (`HLSInput`'s race), stopped without stopping the stream.
    func aborting(when abort: @escaping @Sendable () -> Bool) -> HLSSegmentLoader {
        HLSSegmentLoader(sharing: self, abort: abort)
    }

    /// The segment's bytes, decrypted.
    func segment(_ segment: HLSSegment) throws(HLSSegmentLoadError) -> Data {
        var data = try download(segment.url, range: segment.byteRange)
        if let key = segment.key { data = try decrypt(data, key: key, iv: segment.initializationVector) }
        return data
    }

    /// The init section's bytes, decrypted (one load per `EXT-X-MAP` in effect).
    func initSection(_ section: HLSInitSection) throws(HLSSegmentLoadError) -> Data {
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

    /// A playlist's text and where it was served from, after redirects (its relative URIs are read against that).
    func playlist(_ url: URL) throws(HLSSegmentLoadError) -> (data: Data, servedFrom: URL) {
        if url.isFileURL {
            guard allowsFiles else { throw .notServed(url) }
            return (try file(url, range: nil), url)
        }
        switch transport.open(
            url.absoluteString, offset: 0, end: nil, cookies: nil, cookieOrigin: nil, followsRedirects: true,
            abort: abort)
        {
        case .input(let input):
            let servedFrom = input.servedFrom ?? url
            return (try read(input), servedFrom)
        case .failed(let code):
            throw code == HTTPSessionInput.averrorExit ? .interrupted : .failed(code)
        case .notServed:
            throw .notServed(url)
        }
    }

    // MARK: Decryption

    private func decrypt(_ data: Data, key: HLSKey, iv: [UInt8]?) throws(HLSSegmentLoadError) -> Data {
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

    private func keyData(_ url: URL) throws(HLSSegmentLoadError) -> Data {
        if let cached = cache.withLock({ $0.keys[url] }) { return cached }
        let data = try download(url, range: nil)
        cache.withLock { cache in
            if cache.keys.count >= Self.cacheLimit { cache.keys.removeAll() }
            cache.keys[url] = data
        }
        return data
    }

    // MARK: Download

    /// The body of `url`, or of its `range`. A range the server answers whole (the transport leaves that to FFmpeg
    /// otherwise) is asked for as the file and cut.
    private func download(_ url: URL, range: HLSByteRange?) throws(HLSSegmentLoadError) -> Data {
        if let range, range.length == 0 { return Data() }
        if url.isFileURL { return try file(url, range: range) }
        let address = url.absoluteString
        let opened = transport.open(
            address, offset: range?.offset ?? 0, end: range.map { $0.offset + $0.length }, cookies: nil,
            cookieOrigin: nil, followsRedirects: true, abort: abort)
        switch opened {
        case .input(let input):
            // A server may answer a range with more than was asked for (206 with a longer range).
            let body = try read(input)
            if let range, Int64(body.count) > range.length { return body.prefix(Int(range.length)) }
            return body
        case .failed(let code):
            throw code == HTTPSessionInput.averrorExit ? .interrupted : .failed(code)
        case .notServed:
            guard let range else { throw .notServed(url) }
            return try wholeFile(url, range: range)
        }
    }

    /// A byte range the server answers whole: the file, cut to the range.
    private func wholeFile(_ url: URL, range: HLSByteRange) throws(HLSSegmentLoadError) -> Data {
        guard
            case .input(let input) = transport.open(
                url.absoluteString, offset: 0, end: nil, cookies: nil, cookieOrigin: nil, followsRedirects: true,
                abort: abort)
        else { throw .notServed(url) }
        let whole = try read(input, limit: Int(range.range.upperBound))
        guard whole.count >= range.range.upperBound else { throw .rangeOutsideFile(url) }
        return whole.subdata(in: Int(range.offset)..<Int(range.range.upperBound))
    }

    /// A segment with a byte range, as the file cut (no request for the range first: the server has answered it whole).
    fileprivate func wholeFileSegment(_ segment: HLSSegment) throws(HLSSegmentLoadError) -> Data {
        guard let range = segment.byteRange else { throw .notServed(segment.url) }
        return try wholeFile(segment.url, range: range)
    }

    private func read(_ input: HTTPSessionInput, limit: Int = .max) throws(HLSSegmentLoadError) -> Data {
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
            } else if count == MediaDemuxer.averrorEOF || count == 0 {
                // A body shorter than the server announced is a connection that dropped, not a short segment.
                if let length = input.answeredLength, length > 0, Int64(body.count) < length, limit == .max {
                    throw .failed(-EIO)
                }
                return body
            } else if count == HTTPSessionInput.averrorExit {
                throw .interrupted
            } else {
                throw .failed(count)
            }
        }
    }
}

/// A segment's bytes as they come: the demuxer starts on a segment's first bytes while the rest is still on the way
/// (`HLSSegmentLoader.segmentBody`), as FFmpeg's `hls.c` reads one, so the first picture of a segment does not wait for
/// the whole of it (30 MB for a 4K segment of six seconds, on a link that may take seconds to carry them). Not for an
/// encrypted segment, which is decrypted as one stream (`HLSSegmentLoader.segment`), nor one the transport leaves to
/// the loader's other path: those arrive whole.
///
/// Blocking, interruptible as the loader's downloads are. A body that `retains` what it hands out (a run's first
/// segment, which the opening reads to describe the picture and the demuxer then goes back to the start of) can be
/// `replayed`: a new body gives the bytes read so far again and goes on with the same download, up to
/// `HLSSegmentLoader.retainLimit` bytes.
final class HLSSegmentBody {
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

    init(data: Data) {
        source = .data(data)
        buffer = []
    }

    fileprivate init(input: HTTPSessionInput, limit: Int64?, retains: Bool) {
        source = .input(input, limit: limit)
        buffer = [UInt8](repeating: 0, count: 64 << 10)
        retained = retains ? Data() : nil
    }

    /// The next bytes, at most `count`; nil at the end of the segment.
    func next(_ count: Int = 64 << 10) throws(HLSSegmentLoadError) -> Data? {
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
                    if received > HLSSegmentLoader.retainLimit { retained = nil }
                }
                return chunk
            }
            if result == MediaDemuxer.averrorEOF || result == 0 {
                // A body shorter than the server announced (or than the range) is a connection that dropped.
                let expected = limit ?? input.answeredLength.flatMap { $0 > 0 ? $0 : nil }
                if let expected, Int64(received) < expected {
                    throw .failed(-EIO)
                }
                return end(input, isComplete: true)
            }
            throw result == HTTPSessionInput.averrorExit ? .interrupted : .failed(result)
        }
    }

    /// Everything that is left.
    func rest() throws(HLSSegmentLoadError) -> Data {
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
    func replayedBody() -> HLSSegmentBody? {
        if case .data(let data) = source, !isFinished {
            isFinished = true
            return HLSSegmentBody(data: data)
        }
        guard let kept = retained, !isFinished || isComplete else { return nil }
        let body: HLSSegmentBody
        switch source {
        case .data(let data):
            body = HLSSegmentBody(data: data)
        case .input(let input, let limit):
            if isComplete {
                body = HLSSegmentBody(data: kept)
            } else {
                body = HLSSegmentBody(input: input, limit: limit, retains: true)
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

    /// Gives the download up (the segment is not read to its end).
    func close() {
        guard case .input(let input, _) = source, !isFinished else { return }
        isFinished = true
        input.close()
    }

    deinit { close() }
}

extension HLSSegmentLoader {
    /// The segment's bytes as they arrive (`HLSSegmentBody`): the download starts now and the caller reads as it comes.
    /// `whileOpening`: a probe of the stream's description (`HLSLane.probe`), which FFmpeg's analysis reads as far as it
    /// needs and the caller then closes: the request is the opening's (`HTTPSessionTransport.open(whileOpening:)`), held
    /// to a small buffer so that the server sends little more than is read, and counted in no adaptive-bitrate sample, but
    /// in `HTTPSessionTransport.openingThroughput`. `retains`: the body can be `replayed`.
    func segmentBody(
        _ segment: HLSSegment, whileOpening: Bool = false, retains: Bool = false
    ) throws(HLSSegmentLoadError) -> HLSSegmentBody {
        if segment.key != nil || segment.byteRange?.length == 0 {
            return HLSSegmentBody(data: try self.segment(segment))
        }
        if segment.url.isFileURL { return HLSSegmentBody(data: try file(segment.url, range: segment.byteRange)) }
        let range = segment.byteRange
        let opened = transport.open(
            segment.url.absoluteString, offset: range?.offset ?? 0, end: range.map { $0.offset + $0.length },
            cookies: nil, cookieOrigin: nil, whileOpening: whileOpening, followsRedirects: true, abort: abort)
        switch opened {
        case .input(let input):
            return HLSSegmentBody(input: input, limit: range?.length, retains: retains)
        case .failed(let code):
            throw code == HTTPSessionInput.averrorExit ? .interrupted : .failed(code)
        case .notServed:
            // A range the server answers whole (the request is already made once): the file, cut.
            return HLSSegmentBody(data: try wholeFileSegment(segment))
        }
    }
}

extension HLSSegmentLoader {
    /// A local file's bytes, or those of its `range` (mapped, not copied, while it is read).
    fileprivate func file(_ url: URL, range: HLSByteRange?) throws(HLSSegmentLoadError) -> Data {
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
