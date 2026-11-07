import Foundation

/// What is searched in a numbered stream (`…&sq=N`) by asking for the segments one by one: the first the server still has.
///
/// The times of segments grow with their numbers but not evenly (YouTube's live segments are mostly 5 s, in runs
/// 4.933 s, and the odd one 1.667 s), so a number times a length is wrong by seconds after an hour and a minute after
/// three: the times of the segments are read from them (`FragmentStartTime`, `SegmentedDASHManifest.window`).
package enum SegmentTimeSearch {
    package struct Point: Equatable, Sendable {
        package var number: Int
        /// Seconds from the start of the stream.
        package var time: Double

        package init(number: Int, time: Double) {
            self.number = number
            self.time = time
        }
    }

    /// The first segment the server still has: the oldest ones expire (a week of a 24/7 stream, seconds of one without
    /// a DVR), and a number past the edge is answered with a 404.
    ///
    /// Looks back from `newest` in strides that double up to `maxStride`, then asks about `fanOut` numbers at once in
    /// the stretch the last stride left. Never farther past the edge than one `maxStride`: YouTube answers a segment
    /// far past it slowly (7.8 s from about a day and a half past, a tenth of a second up to 17 hours), so a search
    /// of the whole history at once, or strides that keep doubling, costs more than it saves.
    ///
    /// - Parameters:
    ///   - newest: A segment that is there.
    ///   - floor: The lowest number worth asking for (0).
    ///   - firstStride: How many segments the first step back takes (a stream without a DVR has seconds).
    ///   - maxStride: The longest step back: 8640 is 12 hours of 5 s segments.
    ///   - fanOut: How many numbers a round asks about at once in the last stretch.
    ///   - tolerance: How close to the edge is close enough, at most (an eighth of the way from `newest` to the edge at
    ///     most: close to the head it is exact, as a few segments of history are worth finding): the search ends once the stretch between a number that is
    ///     there and one that is not is this long, and tells the one that is there (so up to `tolerance` segments may be
    ///     there beyond it). Where the edge answers slowly and not steadily, a coarse one saves the rounds.
    ///   - isAvailable: Whether the server has the segment. Numbers from the first available one to `newest` all are.
    package static func oldestAvailable(
        upTo newest: Int, floor: Int = 0, firstStride: Int = 16, maxStride: Int = 8640, fanOut: Int = 8,
        tolerance: Int = 1,
        isAvailable: @escaping @Sendable (Int) async throws -> Bool
    ) async throws -> Int {
        var available = newest
        var stride = max(1, firstStride)
        var gone: Int?
        while available > floor {
            let candidate = max(floor, available - stride)
            if try await isAvailable(candidate) {
                available = candidate
                stride = min(stride * 2, max(1, maxStride))
            } else {
                gone = candidate
                break
            }
        }
        guard var gone else { return available }
        while available - gone > max(1, min(tolerance, (newest - gone) / 8)) {
            let width = available - gone
            let count = max(1, min(fanOut, width - 1))
            let candidates = (1...count).map { gone + width * $0 / (count + 1) }
            let answers = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
                for candidate in candidates {
                    group.addTask { (candidate, try await isAvailable(candidate)) }
                }
                var result: [(Int, Bool)] = []
                for try await answer in group { result.append(answer) }
                return result.sorted { $0.0 < $1.0 }
            }
            for (candidate, isThere) in answers {
                if isThere {
                    available = candidate
                    break
                }
                gone = candidate
            }
        }
        return available
    }
}
