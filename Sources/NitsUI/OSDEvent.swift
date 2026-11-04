import Foundation
import NitsCore

/// Defines an event displayed on the On-Screen Display (OSD) overlay.
public enum OSDEvent: Equatable, Sendable {
    case play
    case pause
    case seek(offsetSeconds: Double, currentTime: Double, duration: Double)
    case volume(level: Float, isMuted: Bool)
    case frameStep(forward: Bool)
    case audioTrack(title: String)
    case subtitleTrack(title: String)
    case subtitleDelay(seconds: Double)
    case secondarySubtitleDelay(seconds: Double)
    case audioDelay(seconds: Double)
    case renderMode(modeName: String)
    case sharpness(value: Float)
    case playbackRate(rate: Double)
    case custom(symbol: String, text: String, subtext: String? = nil, progress: Float? = nil)
}

/// A log message mirrored to the debug OSD stack.
public struct DebugOSDMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let level: LogLevel
    public let category: LogCategory
    public let text: String
    /// Number of identical consecutive messages collapsed into this badge.
    public var repeatCount: Int
    public var expiresAt: ContinuousClock.Instant

    public init(
        id: UUID = UUID(),
        level: LogLevel,
        category: LogCategory,
        text: String,
        repeatCount: Int = 1,
        expiresAt: ContinuousClock.Instant
    ) {
        self.id = id
        self.level = level
        self.category = category
        self.text = text
        self.repeatCount = repeatCount
        self.expiresAt = expiresAt
    }
}

extension OSDEvent {
    /// A seek's OSD at `time` in the media of `engine`: the place in it and its duration. Of a live stream, what its
    /// timeline shows (its timestamps run from where the stream began, hours in): how far behind the edge, with the
    /// place in the window as the bar; of one that ended, the time into it and its length.
    @MainActor
    public static func seek(offsetSeconds: Double, at time: Double, of engine: PlayerEngine) -> OSDEvent {
        guard engine.live.isLive, let window = engine.live.window() else {
            return .seek(offsetSeconds: offsetSeconds, currentTime: time, duration: engine.media.duration)
        }
        if window.hasEnded {
            return .seek(
                offsetSeconds: offsetSeconds, currentTime: max(0, time - window.start), duration: window.length)
        }
        let behind =
            engine.live.isAtEdge(time)
            ? "Live" : "−" + TimeParser.format(seconds: engine.live.secondsBehindEdge(at: time))
        return .custom(
            symbol: offsetSeconds >= 0 ? "goforward" : "gobackward", text: TimeParser.formatSeekOffset(offsetSeconds),
            subtext: behind, progress: Float(min(max((time - window.start) / max(window.length, 1), 0), 1)))
    }
}
