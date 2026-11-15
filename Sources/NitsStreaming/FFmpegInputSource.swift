import CFFmpeg
import Foundation

/// An input served by Nits instead of FFmpeg's protocols: what an `AVIOContext`'s callbacks read (an HLS segment,
/// `HLSSegmentReader`).
package protocol FFmpegInputSource: AnyObject {
    func read(_ buffer: UnsafeMutablePointer<UInt8>, _ size: Int32) -> Int32
    /// `avio_seek`'s `offset` and `whence` (`AVSEEK_SIZE` among them).
    func seek(_ offset: Int64, _ whence: Int32) -> Int64
    /// The input is closed: what it holds is let go.
    func close()
}
