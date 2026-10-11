import CoreMedia
import Foundation

/// Represents a decoded video frame with underlying pixel buffer, presentation timestamp,
/// display flags, and optional dynamic HDR metadata.
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: CMTime
    public let duration: CMTime
    public let doNotDisplay: Bool
    public let doviMetadata: DolbyVisionFrameMetadata?

    public init(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime,
        doNotDisplay: Bool = false,
        doviMetadata: DolbyVisionFrameMetadata? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
        self.doNotDisplay = doNotDisplay
        self.doviMetadata = doviMetadata
    }
}
