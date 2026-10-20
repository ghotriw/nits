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
    public let header: Data
    /// A subtitle file read whole, events included, rather than a stream whose events come as packets.
    public let isCompleteFile: Bool
    public var events: [Event]
    public let fonts: [Font]

    public init(header: Data, isCompleteFile: Bool = false, events: [Event] = [], fonts: [Font] = []) {
        self.header = header
        self.hostHeader = Self.hostHeader(of: header)
        self.isCompleteFile = isCompleteFile
        self.events = events
        self.fonts = fonts
    }

    /// The order of event fields in the lines hosts get (`dialogueLine`), as the `Format:` of `hostHeader` lists it.
    public static let eventFormat = "Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"

    /// The script without its events, for a host that draws it (libass in a web view): script info, styles, embedded
    /// fonts and graphics, then an `[Events]` section with `eventFormat`, which the hosts' `Dialogue:` lines follow.
    /// Made once, with the script: for a file it means going through all of it.
    public let hostHeader: String

    private static func hostHeader(of header: Data) -> String {
        let text = (String(data: header, encoding: .utf8) ?? String(decoding: header, as: UTF8.self))
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var kept: [Substring] = []
        var inEvents = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inEvents = trimmed.lowercased() == "[events]" }
            if !inEvents { kept.append(line) }
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        return kept.joined(separator: "\n") + "\n\n[Events]\nFormat: \(Self.eventFormat)\n"
    }

    /// A `Dialogue:` line in `eventFormat`, timed `start`-`end` (seconds) and with the other fields as given; empty
    /// numbers become 0, and the text keeps its commas and tags.
    static func dialogueLine(
        start: Double, end: Double, layer: String, style: String, name: String, marginL: String, marginR: String,
        marginV: String, effect: String, text: String
    ) -> String {
        func number(_ field: String) -> String {
            let value = field.trimmingCharacters(in: .whitespaces)
            return Int(value) == nil ? "0" : value
        }
        let fields = [
            number(layer), timestamp(start), timestamp(end), style.trimmingCharacters(in: .whitespaces),
            name.trimmingCharacters(in: .whitespaces), number(marginL), number(marginR), number(marginV),
            effect.trimmingCharacters(in: .whitespaces),
        ]
        return "Dialogue: " + fields.joined(separator: ",") + "," + text
    }

    /// The `Dialogue:` line of a Matroska ASS event (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`,
    /// or an old muxer's `Dialogue:` line with its own times), timed `start`-`end`. An event short of fields is taken
    /// whole for the text, in the Default style, as the cue's plain text is.
    static func dialogueLine(matroskaEvent payload: String, start: Double, end: Double) -> String {
        var fields: [Substring]
        if payload.hasPrefix("Dialogue:") {
            // Layer (or SSA's Marked), Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
            fields = payload.dropFirst("Dialogue:".count).split(
                separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            if fields.count == 10 {
                fields.removeSubrange(1...2)
                if fields[0].contains("=") { fields[0] = "0" }
            }
        } else {
            fields = payload.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            if fields.count == 9 { fields.removeFirst() }  // ReadOrder
        }
        guard fields.count == 8 else {
            return dialogueLine(
                start: start, end: end, layer: "", style: "Default", name: "", marginL: "", marginR: "", marginV: "",
                effect: "", text: payload)
        }
        return dialogueLine(
            start: start, end: end, layer: String(fields[0]), style: String(fields[1]), name: String(fields[2]),
            marginL: String(fields[3]), marginR: String(fields[4]), marginV: String(fields[5]),
            effect: String(fields[6]), text: String(fields[7]))
    }

    /// `H:MM:SS.cc`, as ASS times are written.
    static func timestamp(_ seconds: Double) -> String {
        let centiseconds = Int((max(seconds, 0) * 100).rounded())
        let (hours, rest) = centiseconds.quotientAndRemainder(dividingBy: 360_000)
        let (minutes, rest2) = rest.quotientAndRemainder(dividingBy: 6_000)
        let (secs, cs) = rest2.quotientAndRemainder(dividingBy: 100)
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, cs)
    }
}
