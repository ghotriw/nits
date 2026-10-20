import Foundation

/// Fast parser and lookup container for timed subtitle cues (SRT, WebVTT).
public struct SubtitleDocument: Sendable, Equatable {
    public let cues: [SubtitleCue]
    /// Bitmap cues (PGS, VobSub, DVB) of a track; a track has either these or `cues`.
    public let imageCues: [SubtitleImageCue]
    /// What libass draws an ASS / SSA track from; `cues` hold the same dialogue as plain text.
    public let assScript: AssScript?

    public init(cues: [SubtitleCue], imageCues: [SubtitleImageCue] = [], assScript: AssScript? = nil) {
        self.assScript = assScript
        // Ensure cues are sorted chronologically by startTime
        self.cues = cues.sorted { $0.startTime < $1.startTime }
        self.imageCues = imageCues.sorted { $0.startTime < $1.startTime }
    }

    /// Fast lookup for single active subtitle cue (returns the first matching cue).
    public func activeCue(at time: Double) -> SubtitleCue? {
        activeCues(at: time).first
    }

    /// Finds all subtitle cues active at given playback timestamp.
    /// Supports overlapping/simultaneous dialogs (e.g. top + bottom lines).
    public func activeCues(at time: Double) -> [SubtitleCue] {
        Self.active(in: cues, at: time, start: \.startTime, end: \.endTime)
    }

    /// The bitmap cues on screen at the timestamp.
    public func activeImageCues(at time: Double) -> [SubtitleImageCue] {
        Self.active(in: imageCues, at: time, start: \.startTime, end: \.endTime)
    }

    /// The items of a list sorted by start that contain the time, in list order.
    private static func active<Item>(
        in items: [Item], at time: Double, start: KeyPath<Item, Double>, end: KeyPath<Item, Double>
    ) -> [Item] {
        guard !items.isEmpty else { return [] }

        // Binary search to find the partition index where items[i].start > time
        var low = 0
        var high = items.count

        while low < high {
            let mid = (low + high) / 2
            if items[mid][keyPath: start] <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // low is the first item with start > time.
        // Scan backwards to collect all items that are still active (end >= time).
        var matched: [Item] = []
        var i = low - 1
        while i >= 0 {
            let item = items[i]
            if time <= item[keyPath: end] {
                matched.append(item)
            } else if (time - item[keyPath: start]) > 300.0 {
                // Heuristic early break: subtitle cues rarely last more than 5 minutes.
                break
            }
            i -= 1
        }

        return matched.reversed()
    }

    /// Parses an SRT string into a SubtitleDocument.
    public static func parseSRT(_ text: String) -> SubtitleDocument {
        var cues: [SubtitleCue] = []
        // Normalize newline endings
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var index = 0
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let lines = trimmed.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count >= 2 else { continue }

            // Find line containing time separator "-->"
            var timeLineIndex = -1
            for (idx, line) in lines.enumerated() {
                if line.contains("-->") {
                    timeLineIndex = idx
                    break
                }
            }

            guard timeLineIndex >= 0 else { continue }
            let timeLine = lines[timeLineIndex]
            let timeParts = timeLine.components(separatedBy: "-->")
            guard timeParts.count == 2 else { continue }

            guard let start = parseTimestamp(timeParts[0].trimmingCharacters(in: .whitespaces)),
                let end = parseTimestamp(timeParts[1].trimmingCharacters(in: .whitespaces))
            else {
                continue
            }

            let textLines = lines.suffix(from: timeLineIndex + 1)
            let cueText = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let alignment = parseAlignment(from: cueText)
            let cleanText = cleanFormattingTags(cueText)

            if !cleanText.isEmpty {
                index += 1
                cues.append(
                    SubtitleCue(
                        id: index,
                        startTime: start,
                        endTime: end,
                        text: cleanText,
                        alignment: alignment
                    )
                )
            }
        }

        return SubtitleDocument(cues: cues)
    }

    /// Parses a WebVTT string into a SubtitleDocument.
    public static func parseWebVTT(_ text: String) -> SubtitleDocument {
        var cues: [SubtitleCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var index = 0
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("WEBVTT") || trimmed.hasPrefix("NOTE") { continue }

            let lines = trimmed.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var timeLineIndex = -1
            for (idx, line) in lines.enumerated() {
                if line.contains("-->") {
                    timeLineIndex = idx
                    break
                }
            }

            guard timeLineIndex >= 0 else { continue }
            let timeLine = lines[timeLineIndex]
            let timeParts = timeLine.components(separatedBy: "-->")
            guard timeParts.count == 2 else { continue }

            // WebVTT may contain alignment/positioning tags after end timestamp (e.g. 00:01:00.000 line:0%)
            let rawStart = timeParts[0].trimmingCharacters(in: .whitespaces)
            let rawEnd = timeParts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""

            guard let start = parseTimestamp(rawStart),
                let end = parseTimestamp(rawEnd)
            else {
                continue
            }

            let textLines = lines.suffix(from: timeLineIndex + 1)
            let cueText = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            // WebVTT line:0% or line:10% indicates top position
            var alignment = parseAlignment(from: cueText)
            if timeLine.contains("line:0%") || timeLine.contains("line:10%") || timeLine.contains("line:0 ") {
                alignment = .topCenter
            }

            let cleanText = cleanFormattingTags(cueText)

            if !cleanText.isEmpty {
                index += 1
                cues.append(
                    SubtitleCue(
                        id: index,
                        startTime: start,
                        endTime: end,
                        text: cleanText,
                        alignment: alignment
                    )
                )
            }
        }

        return SubtitleDocument(cues: cues)
    }

    /// Parses an ASS / SSA script: the dialogue as plain-text cues (what hosts and the plain-text setting show) and
    /// the whole script for libass.
    public static func parseASS(_ text: String) -> SubtitleDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        var fields: [String] = []
        var inEvents = false
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst("format:".count).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
            } else if line.lowercased().hasPrefix("dialogue:"), let startField = fields.firstIndex(of: "start"),
                let endField = fields.firstIndex(of: "end"), let textField = fields.firstIndex(of: "text")
            {
                // The text is the last field and may hold commas.
                let values = line.dropFirst("dialogue:".count).split(
                    separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                guard values.count == fields.count,
                    let start = parseTimestamp(values[startField].trimmingCharacters(in: .whitespaces)),
                    let end = parseTimestamp(values[endField].trimmingCharacters(in: .whitespaces))
                else { continue }
                let raw = String(values[textField])
                // A vector drawing (`{\p1}m 0 0 l ...`) is not text.
                if raw.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) != nil { continue }
                let clean = cleanFormattingTags(raw)
                guard !clean.isEmpty else { continue }
                cues.append(
                    SubtitleCue(
                        id: cues.count + 1, startTime: start, endTime: end, text: clean,
                        alignment: parseAlignment(from: raw), rawPayload: String(line)))
            }
        }
        return SubtitleDocument(
            cues: cues, assScript: AssScript(header: Data(normalized.utf8), isCompleteFile: true))
    }

    /// Detects ASS/SSA alignment tags like {\an8}, {\an7}, {\an1}, etc.
    public static func parseAlignment(from text: String) -> SubtitleAlignment {
        if text.contains("{\\an8}") || text.contains("{\\an7}") || text.contains("{\\an9}") {
            return .topCenter
        } else if text.contains("{\\an4}") || text.contains("{\\an5}") || text.contains("{\\an6}") {
            return .center
        } else if text.contains("{\\an1}") {
            return .bottomLeft
        } else if text.contains("{\\an3}") {
            return .bottomRight
        }
        return .bottomCenter
    }

    /// Converts timestamps in format "HH:MM:SS,mmm" or "HH:MM:SS.mmm" or "MM:SS.mmm" to seconds.
    public static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")

        if parts.count == 3 {
            guard let h = Double(parts[0]),
                let m = Double(parts[1]),
                let s = Double(parts[2])
            else { return nil }
            return h * 3600.0 + m * 60.0 + s
        } else if parts.count == 2 {
            guard let m = Double(parts[0]),
                let s = Double(parts[1])
            else { return nil }
            return m * 60.0 + s
        }

        return nil
    }

    /// Strips inline formatting tags, handles ASS hard line breaks and decodes HTML entities.
    public static func cleanFormattingTags(_ text: String) -> String {
        var result = text
        // Replace ASS line breaks and hard spaces before stripping tags
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\h", with: " ")
        // Replace ASS / SSA styling tags e.g. {\an8}, {\b1}, {\pos(100,200)}, {y:i}
        result = result.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        // Replace HTML tags e.g. <i>, <font color="...">
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common HTML entities if present
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
