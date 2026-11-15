import Foundation
import os

/// A live stream given as the segments of its past (`StreamHistory`), told as a playlist that grows: the manifest the
/// resolver made is static and goes on a day past the head (`SegmentedDASHManifest`), and what is listed of it is the
/// segments up to the head the source tells, one less (the newest the server reports, less one: a segment reported and
/// not served yet is never listed, so a segment that fails stays one rule for all the client's sources: it is skipped
/// at once). A reload of the playlist asks the head, no more often than `StreamHistorySource.headPollInterval`.
///
/// **The end.** A head that stood still for `StreamHistorySource.segmentWaitLimit` asks the source whether the stream is
/// over (`hasEnded`): `true` ends the playlist after the head's segment, as a recording; `false` is a stream on the air
/// and silent, waited for with no limit; `nil` is not told: with the server not answering it is the network, waited for;
/// with it answering and the head standing still, it is the end after a few asks (`unknownRounds`).
///
/// **The start.** The window slides with the clock from the first load, as the server's oldest segments expire as
/// time goes: what is listed starts as many seconds on as have passed (the engine slides its window the same way).
/// The timeline's zero stays where the first segment was (`StreamingTimeline` keeps the places of the segments it had).
///
/// **The addresses.** A segment is named by its stream's key and number (`StreamHistory.segment(named:)`); the loader
/// asks the source for the signed address at each request, and for a new signature when one is refused.
package final class DASHHistory: Sendable {
    /// How many times `hasEnded` may fail to tell, with the server answering and its head standing still, before that is
    /// taken for the end of the stream.
    static let unknownRounds = 3
    /// How long a playlist that is not over is not taken for stuck (`MediaPlaylist.updatePeriod`): a day. The end is
    /// the source's to tell, not the lane's to guess.
    static let updatePeriod = 86_400.0

    let source: any StreamHistorySource

    private struct State {
        /// The newest segment known to be there.
        var head: Int
        var isEnded = false
        /// When the head last moved, and the source was last asked for it (the host's clock, `clock`).
        var lastMovement: Date
        var lastPoll: Date
        var isPolling = false
        /// Whether the server answered the last ask for the head: it is reachable, or it may be the network that is down.
        var isServerAnswering = false
        var unknownEnds = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let clock: @Sendable () -> Date
    private let began: Date

    /// - Parameter head: The number of the newest segment when the manifest was made.
    init(source: any StreamHistorySource, head: Int, clock: @escaping @Sendable () -> Date) {
        self.source = source
        self.clock = clock
        let now = clock()
        began = now
        state = OSAllocatedUnfairLock(initialState: State(head: head, lastMovement: now, lastPoll: now))
    }

    var head: Int { state.withLock { $0.head } }
    var isEnded: Bool { state.withLock { $0.isEnded } }

    /// `full`, the manifest's playlist of a representation (a day past the head), as it is now: from where the window
    /// has slid to, to the segment before the head (the head's, once the stream is over). The head is asked first, if
    /// it is time; `shouldAbort` gives way to a seek or a close.
    func listing(of full: MediaPlaylist, shouldAbort: () -> Bool) -> MediaPlaylist {
        refresh(shouldAbort: shouldAbort)
        let (head, isEnded) = state.withLock { ($0.head, $0.isEnded) }
        var playlist = full
        playlist.type = nil
        playlist.hasEnded = isEnded
        playlist.updatePeriod = isEnded ? nil : Self.updatePeriod
        guard let first = full.segments.first?.sequence else { return playlist }
        // The last listed: up to the segment before the head, at least the first.
        let lastNumber = max(isEnded ? head : head - 1, first)
        let end = Self.index(after: lastNumber, in: full.segments)
        // The first: the segments whose time has passed since the first load are expired.
        let elapsed = max(0, clock().timeIntervalSince(began))
        var start = 0
        var passed = 0.0
        while start + 1 < end, passed + full.segments[start].duration <= elapsed {
            passed += full.segments[start].duration
            start += 1
        }
        playlist.segments = Array(full.segments[start..<end])
        playlist.mediaSequence = playlist.segments.first?.sequence ?? first
        return playlist
    }

    /// The index after the last segment numbered at most `number` (the numbers rise).
    private static func index(after number: Int, in segments: [MediaSegment]) -> Int {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].sequence <= number { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: The head

    /// Asks the source for the head when it is time, by the first caller that finds it so (the lanes' reloads come
    /// together; the others list what is known). Blocks, as any read of the client does.
    private func refresh(shouldAbort: () -> Bool) {
        let now = clock()
        let isDue = state.withLock { state -> Bool in
            guard !state.isEnded, !state.isPolling,
                now.timeIntervalSince(state.lastPoll) >= (source.headPollInterval / .seconds(1))
            else { return false }
            state.isPolling = true
            return true
        }
        guard isDue else { return }
        defer { state.withLock { $0.isPolling = false } }

        let answer = source.head(shouldAbort: shouldAbort)
        if shouldAbort() { return }
        let found = state.withLock { state -> Int? in
            state.lastPoll = clock()
            // Any answer is the server being there; only no answer at all is the network being down.
            state.isServerAnswering = answer != .noAnswer
            if case .head(let head) = answer, head.number > state.head {
                state.head = head.number
                state.lastMovement = state.lastPoll
                state.unknownEnds = 0
                return head.number
            }
            return nil
        }
        if let found { StreamingLog.debug("DASH history: the head moved to \(found)") }
        let stood = state.withLock { clock().timeIntervalSince($0.lastMovement) }
        guard stood >= (source.segmentWaitLimit / .seconds(1)) else { return }

        let over = source.hasEnded(shouldAbort: shouldAbort)
        if shouldAbort() { return }
        state.withLock { state in
            switch over {
            case true?:
                state.isEnded = true
            case false?:
                // Still on the air, and silent: waited for as long as it takes, asking again after another limit.
                state.lastMovement = clock()
            case nil:
                state.lastMovement = clock()
                // The server answers and its head stands still, and the source cannot say (yt-dlp fails on a page whose
                // stream is gone): after a few asks, that is the end. If the server does not answer either, it is the
                // network: waited for as long as it takes.
                if state.isServerAnswering {
                    state.unknownEnds += 1
                    if state.unknownEnds > Self.unknownRounds { state.isEnded = true }
                }
            }
        }
        if isEnded { StreamingLog.info("DASH history: the stream is over, after segment \(head)") }
    }
}
