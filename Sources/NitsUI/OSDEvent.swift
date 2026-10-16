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
