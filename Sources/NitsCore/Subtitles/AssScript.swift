import Foundation

/// What libass needs to draw an ASS / SSA track: the script header (styles), the events, and the fonts the media
/// carries. Kept next to the plain-text cues of the same track, which hosts and the "plain text" setting use.
public struct AssScript: Sendable, Equatable {
    /// One dialogue event as the container stores it: `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
    public struct Event: Sendable, Equatable {
        public let payload: String
        public let start: Double
        public let duration: Double

        public init(payload: String, start: Double, duration: Double) {
            self.payload = payload
            self.start = start
            self.duration = duration
        }
    }

    /// A font attached to the container (MKV attachments), for scripts that name fonts the system doesn't have.
    public struct Font: Sendable, Equatable {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// The stream's codec private data (script info and styles), or the whole script for `isCompleteFile`.
    public var header: Data
    /// A subtitle file read whole, events included, rather than a stream whose events come as packets.
    public let isCompleteFile: Bool
    public var events: [Event]
    public let fonts: [Font]

    public init(header: Data, isCompleteFile: Bool = false, events: [Event] = [], fonts: [Font] = []) {
        self.header = header
        self.isCompleteFile = isCompleteFile
        self.events = events
        self.fonts = fonts
    }
}
