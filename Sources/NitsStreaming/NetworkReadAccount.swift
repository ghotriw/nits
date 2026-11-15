import Foundation

/// The bytes and requests of an input's network reads (`FFmpegIOByteCounter`), as adaptive bitrate measures them
/// (`MediaDemuxer.noteRead`). Behind the demuxer's `lock`.
package protocol NetworkReadAccount: AnyObject {
    /// Bytes read so far over the network.
    var total: Int64 { get }
    /// Seconds spent opening requests (their latency, no transfer).
    var openSeconds: Double { get }
    /// The latest request opened: when it was asked for and answered, with `total` and `openSeconds` then.
    var lastOpen: (asked: ContinuousClock.Instant, opened: ContinuousClock.Instant, total: Int64, openSeconds: Double)?
    {
        get
    }
    /// The transfers of the requests, each measured apart from its answer.
    var transferMeter: NetworkTransferMeter? { get }
}
