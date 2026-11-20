import Foundation

/// How the best ladder is told from the others, one rule for the client (`StreamingInput.ladder(of:)`) and for the hosts
/// that offer the ladders with the best first (`HLSLadderMenu`, `DASHManifest`, both in `NitsCore`): the biggest
/// picture (height, then width), HDR over SDR, then the codec the host prefers (`codecRank`, lower is more preferred: the bitrate of different codecs says nothing of their
/// quality), then the higher bandwidth.
package enum LadderChoice {
    /// The key the best of rungs is the greatest of; `family` is a `CodecFamily.video(in:)` name ("" when unknown).
    package static func key(
        height: Int, width: Int, isHDR: Bool, family: String, bandwidth: Int, codecRank: (String) -> Int
    ) -> (Int, Int, Int, Int, Int) {
        (height, width, isHDR ? 1 : 0, -codecRank(family), bandwidth)
    }
}
