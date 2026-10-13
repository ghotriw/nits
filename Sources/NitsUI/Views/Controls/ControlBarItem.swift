import Foundation

/// Represents an individual item / button on the bottom player control bar.
public enum ControlBarItem: String, CaseIterable, Identifiable, Codable, Sendable {
    case playlistPrevious = "playlistPrevious"
    case seekBackward = "seekBackward"
    case playPause = "playPause"
    case seekForward = "seekForward"
    case playlistNext = "playlistNext"
    case timeline = "timeline"
    case volume = "volume"
    case audioTrack = "audioTrack"
    case subtitleTrack = "subtitleTrack"
    case playlist = "playlist"
    case playlistRepeat = "playlistRepeat"
    case playlistShuffle = "playlistShuffle"
    case quickSettings = "quickSettings"

    public var id: String { rawValue }

    /// Localized / user-facing display title for settings.
    public var title: String {
        switch self {
        case .playlistPrevious:
            return "Previous Track"
        case .seekBackward:
            return "Seek Backward"
        case .playPause:
            return "Play / Pause"
        case .seekForward:
            return "Seek Forward"
        case .playlistNext:
            return "Next Track"
        case .timeline:
            return "Timeline & Duration"
        case .volume:
            return "Volume Slider"
        case .audioTrack:
            return "Audio Tracks"
        case .subtitleTrack:
            return "Subtitles"
        case .playlist:
            return "Playlist Panel"
        case .playlistRepeat:
            return "Repeat Mode"
        case .playlistShuffle:
            return "Shuffle"
        case .quickSettings:
            return "Quick Settings Panel"
        }
    }

    /// System SF Symbol representing the control.
    public var iconName: String {
        switch self {
        case .playlistPrevious:
            return "backward.end.fill"
        case .seekBackward:
            return "gobackward"
        case .playPause:
            return "playpause.fill"
        case .seekForward:
            return "goforward"
        case .playlistNext:
            return "forward.end.fill"
        case .timeline:
            return "slider.horizontal.below.rectangle"
        case .volume:
            return "speaker.wave.2.fill"
        case .audioTrack:
            return "waveform.circle"
        case .subtitleTrack:
            return "captions.bubble"
        case .playlist:
            return "list.bullet"
        case .playlistRepeat:
            return "repeat"
        case .playlistShuffle:
            return "shuffle"
        case .quickSettings:
            return "slider.horizontal.3"
        }
    }

    /// Whether this item can be toggled off or hidden.
    /// Play/Pause and Timeline are essential for playback control and cannot be disabled.
    public var isRequired: Bool {
        switch self {
        case .playPause, .timeline:
            return true
        default:
            return false
        }
    }
}
