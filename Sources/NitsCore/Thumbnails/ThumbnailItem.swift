import CoreGraphics
import Foundation

/// Represents a decoded and rendered video thumbnail at a specific timestamp.
public struct ThumbnailItem: Sendable {
    /// Timestamp in seconds.
    public let time: Double
    /// Rendered image of the thumbnail.
    public let image: CGImage
    /// Pixel width of the thumbnail.
    public let width: Int
    /// Pixel height of the thumbnail.
    public let height: Int

    public init(time: Double, image: CGImage, width: Int, height: Int) {
        self.time = time
        self.image = image
        self.width = width
        self.height = height
    }
}
