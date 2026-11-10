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

    private let transport: HTTPSessionTransport
    private let cache = OSAllocatedUnfairLock(initialState: Cache())
    /// Init sections and keys kept at most: a stream has a few; a playlist that changes them every segment (a key per
    /// segment is common, rotating ones) must not grow the cache for good.
    static let cacheLimit = 32
    private static let readSize = 64 << 10

    init(transport: HTTPSessionTransport) {
        self.transport = transport
    }

    /// The segment's bytes, decrypted.
    func segment(_ segment: HLSSegment) throws(HLSSegmentLoadError) -> Data {
        let data = try download(segment.url, range: segment.byteRange)
        guard let key = segment.key else { return data }
        return try decrypt(data, key: key, iv: segment.initializationVector)
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
        switch transport.open(
            url.absoluteString, offset: 0, end: nil, cookies: nil, cookieOrigin: nil, followsRedirects: true)
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
        let address = url.absoluteString
        let opened = transport.open(
            address, offset: range?.offset ?? 0, end: range.map { $0.offset + $0.length }, cookies: nil,
            cookieOrigin: nil, followsRedirects: true)
        switch opened {
        case .input(let input):
            // A server may answer a range with more than was asked for (206 with a longer range).
            let body = try read(input)
            if let range, Int64(body.count) > range.length { return body.prefix(Int(range.length)) }
            return body
        case .failed(let code):
            throw code == HTTPSessionInput.averrorExit ? .interrupted : .failed(code)
        case .notServed:
            guard let range,
                case .input(let input) = transport.open(
                    address, offset: 0, end: nil, cookies: nil, cookieOrigin: nil, followsRedirects: true)
            else { throw .notServed(url) }
            let whole = try read(input, limit: Int(range.range.upperBound))
            guard whole.count >= range.range.upperBound else { throw .rangeOutsideFile(url) }
            return whole.subdata(in: Int(range.offset)..<Int(range.range.upperBound))
        }
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
