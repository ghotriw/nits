import CoreMedia
import Foundation

/// Unified interface for video decoders (hardware VideoToolbox and software libdav1d).
public protocol VideoDecoderProtocol: AnyObject, Sendable {
    typealias OutputHandler = @Sendable (DecodedFrame) -> Void

    /// Registers the callback invoked when a frame has been decoded.
    func setOutputHandler(_ handler: @escaping OutputHandler)

    /// Decodes a CoreMedia sample buffer.
    func decode(sampleBuffer: CMSampleBuffer)

    /// Flushes any pending or in-flight frames.
    /// May be destructive (e.g. libdav1d drops reference frames): only call before a demuxer seek.
    func flush()

    /// Non-destructive: blocks until asynchronously emitted frames have been delivered.
    /// Decoder reference state is preserved so decoding can continue with the next packet.
    func waitForPendingFrames()

    /// Drains any buffered frames at end-of-stream (EOF).
    func drain()

    /// Resets or invalidates the internal decoder session.
    func resetSession()

    /// Dynamically instructs the decoder to skip non-reference frames (e.g. during exact seek preroll).
    func setDiscardNonReferenceFrames(_ discard: Bool)
}

extension VideoDecoderProtocol {
    public func setDiscardNonReferenceFrames(_ discard: Bool) {}
}
