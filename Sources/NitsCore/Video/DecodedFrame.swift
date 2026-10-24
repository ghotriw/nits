import CoreMedia
import Foundation

/// Represents a decoded video frame with underlying pixel buffer, presentation timestamp,
/// display flags, and optional dynamic HDR metadata.
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: CMTime
    public let duration: CMTime
    public let doNotDisplay: Bool
    public let hdrMetadata: FrameHDRMetadata?
    public let generation: UInt64

    public init(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime,
        doNotDisplay: Bool = false,
        hdrMetadata: FrameHDRMetadata? = nil,
        generation: UInt64 = 0
    ) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
        self.doNotDisplay = doNotDisplay
        self.hdrMetadata = hdrMetadata
        self.generation = generation
    }
}
