import Foundation

/// What one run of yt-dlp gave, as the command line gives it.
public struct YTDLPOutput: Sendable {
    /// 0: `stdout` is what `--dump-single-json` prints. Anything else: the run failed, `stderr` says why.
    public var status: Int32
    public var stdout: Data
    /// On a failure it ends in yt-dlp's `ERROR: [extractor] id: reason` line, which is what the load's error shows
    /// (`YTDLPResolver.error(in:)`); without one the error is a generic "yt-dlp failed".
    public var stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs yt-dlp with a command line's arguments, once, and gives what it wrote: a process on macOS (`NitsKit`), the
/// embedded interpreter of a host on iOS, which can run the arguments through `yt_dlp.parse_options` and answer
/// `YoutubeDL.sanitize_info`'s JSON, which is what `--dump-single-json` prints.
public protocol YTDLPRunner: Sendable {
    /// Whether it can run now (macOS: a yt-dlp was found). `false`: the resolver resolves nothing, as without yt-dlp.
    /// Synchronous and cheap: the resolver asks it in `order(for:)`, on the path of every load, to choose the resolver
    /// (macOS: a search of the file system; a host: read a flag, under a lock if it is set from elsewhere).
    var isAvailable: Bool { get }

    /// Runs it once. The one thing asked of the runner is that cancelling the task ends the run promptly (kills the
    /// process, cancels the call) and throws: the resolver cancels it to enforce its timeout and when the load is
    /// cancelled, and waits for it to end, so a runner that ignores cancellation holds the load past its timeout.
    func run(arguments: [String]) async throws -> YTDLPOutput
}
