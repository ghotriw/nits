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
    func flush()

    /// Drains any buffered frames at end-of-stream (EOF).
    func drain()

    /// Resets or invalidates the internal decoder session.
    func resetSession()
}
