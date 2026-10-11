import Foundation

/// Defines an event displayed on the On-Screen Display (OSD) overlay.
public enum OSDEvent: Equatable, Sendable {
    case play
    case pause
    case seek(offsetSeconds: Double, currentTime: Double, duration: Double)
    case volume(level: Float, isMuted: Bool)
    case frameStep(forward: Bool)
    case audioTrack(title: String)
    case subtitleTrack(title: String)
    case renderMode(modeName: String)
    case sharpness(value: Float)
    case playbackRate(rate: Double)
    case custom(symbol: String, text: String, subtext: String? = nil, progress: Float? = nil)
}
