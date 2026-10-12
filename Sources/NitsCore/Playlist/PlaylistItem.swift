import Foundation

/// Represents a single media item within a playlist.
public struct PlaylistItem: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var duration: Double?
    public var startTime: Double?
    public var customHeaders: [String: String]
    /// Original index before shuffle, used to restore original ordering on unshuffle.
    public var originalIndex: Int

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        duration: Double? = nil,
        startTime: Double? = nil,
        customHeaders: [String: String] = [:],
        originalIndex: Int = 0
    ) {
        self.id = id
        self.url = url
        if let title, !title.isEmpty {
            self.title = title
        } else if url.isFileURL {
            let name = url.deletingPathExtension().lastPathComponent
            self.title = name.removingPercentEncoding ?? name
        } else {
            self.title = url.absoluteString
        }
        self.duration = duration
        self.startTime = startTime
        self.customHeaders = customHeaders
        self.originalIndex = originalIndex
    }

    /// Display filename or url last path component.
    public var filename: String {
        let last = url.lastPathComponent
        return url.isFileURL ? (last.removingPercentEncoding ?? last) : last
    }

    /// Whether this item represents a remote streaming resource.
    public var isNetworkStream: Bool {
        !url.isFileURL
    }

    /// Formatted duration string (e.g. "03:45" or "1:12:30").
    public var formattedDuration: String? {
        guard let duration, duration > 0, !duration.isNaN, !duration.isInfinite else { return nil }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
