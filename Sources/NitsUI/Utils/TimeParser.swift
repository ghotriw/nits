import Foundation

public enum TimeParser: Sendable {
    /// Formats a time in seconds as HH:MM:SS (if >= 1 hour) or MM:SS.
    public static func format(seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    /// Formats the difference between two timestamps, e.g. "+01:30" or "-00:45".
    public static func formatDiff(from: Double, to: Double) -> String {
        let diff = to - from
        let sign = diff >= 0 ? "+" : "-"
        return "\(sign)\(format(seconds: abs(diff)))"
    }

    /// Formats a subtitle delay with one to three decimals (e.g. "+0.2s", "-1.35s", "0.0s").
    public static func formatSubtitleDelay(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0.0s" }
        var text = String(format: "%.3f", abs(seconds))
        while text.hasSuffix("0") && !text.hasSuffix(".0") {
            text.removeLast()
        }
        guard text != "0.0" else { return text + "s" }
        return (seconds > 0 ? "+" : "-") + text + "s"
    }

    /// Formats an audio delay in whole milliseconds (e.g. "+50 ms", "-1000 ms", "0 ms").
    public static func formatAudioDelay(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0 ms" }
        let milliseconds = Int((seconds * 1000).rounded())
        return milliseconds == 0 ? "0 ms" : String(format: "%+d ms", milliseconds)
    }

    /// Formats a seek offset for display (e.g. "+5s", "+60s", "+1m 05s", "-2m 30s", "+1h 01m 05s").
    /// Offsets up to 60s are displayed in whole seconds, while offsets exceeding 60s are formatted in minutes and seconds.
    public static func formatSeekOffset(_ offset: Double) -> String {
        guard !offset.isNaN && !offset.isInfinite else { return "+0s" }
        let totalSeconds = Int(round(abs(offset)))
        guard totalSeconds > 0 else { return "+0s" }
        let sign = offset >= 0 ? "+" : "-"

        if totalSeconds > 60 {
            let s = totalSeconds % 60
            let m = (totalSeconds / 60) % 60
            let h = totalSeconds / 3600
            if h > 0 {
                return "\(sign)\(h)h \(String(format: "%02dm %02ds", m, s))"
            } else {
                return "\(sign)\(m)m \(String(format: "%02ds", s))"
            }
        } else {
            return "\(sign)\(totalSeconds)s"
        }
    }

    /// Parses a string representation of time into target seconds, clamped between 0 and duration.
    /// Supports:
    /// - `hh:mm:ss` (e.g. `1:23:45`, `01:23:45`) with strict validation (m < 60, s < 60)
    /// - `mm:ss` (e.g. `14:30`, `05:12`) with strict validation (s < 60)
    /// - Pure seconds (e.g. `90`, `120.5`, `120,5`)
    /// - Units in English or Ukrainian (e.g. `1h 30m 10s`, `1.5г`, `15хв`, `45s`, `30сек`)
    /// - Relative offsets (e.g. `+10`, `+10s`, `-1:30`, `+5m`, `-30сек`)
    /// - Percentage (e.g. `50%`, `25.5%`, `+10%`)
    public static func parse(input: String, currentTime: Double, duration: Double) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isRelativePlus = trimmed.hasPrefix("+")
        let isRelativeMinus = trimmed.hasPrefix("-")
        let cleanRaw =
            (isRelativePlus || isRelativeMinus)
            ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            : trimmed
        guard !cleanRaw.isEmpty else { return nil }

        // Normalize decimal separators (e.g. "1,5" -> "1.5" from Ukrainian / European keyboards)
        let clean = cleanRaw.replacingOccurrences(of: ",", with: ".")

        // 1. Percentage check (e.g. "50%", "25.5%")
        if clean.hasSuffix("%") {
            let numPart = String(clean.dropLast()).trimmingCharacters(in: .whitespaces)
            if let percent = Double(numPart), duration > 0 {
                let offset = (percent / 100.0) * duration
                let target: Double
                if isRelativePlus {
                    target = currentTime + offset
                } else if isRelativeMinus {
                    target = currentTime - offset
                } else {
                    target = offset
                }
                return clamp(target, duration: duration)
            }
            return nil
        }

        // 2. Colon-separated timestamps: "hh:mm:ss" or "mm:ss"
        // Validates range: seconds < 60, and minutes < 60 for hh:mm:ss
        if clean.contains(":") {
            let parts = clean.components(separatedBy: ":")
            if parts.count == 2 {
                // mm:ss
                if let m = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                    let s = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                    m >= 0, s >= 0, s < 60.0
                {
                    let total = m * 60.0 + s
                    let target =
                        isRelativePlus ? (currentTime + total) : (isRelativeMinus ? (currentTime - total) : total)
                    return clamp(target, duration: duration)
                }
            } else if parts.count == 3 {
                // hh:mm:ss
                if let h = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                    let m = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                    let s = Double(parts[2].trimmingCharacters(in: .whitespaces)),
                    h >= 0, m >= 0, m < 60.0, s >= 0, s < 60.0
                {
                    let total = h * 3600.0 + m * 60.0 + s
                    let target =
                        isRelativePlus ? (currentTime + total) : (isRelativeMinus ? (currentTime - total) : total)
                    return clamp(target, duration: duration)
                }
            }
            return nil
        }

        // 3. Units check: contains 'h', 'm', 's', or Ukrainian units ('г', 'хв', 'с')
        let lower = clean.lowercased()
        if let secondsFromUnits = parseUnits(lower) {
            let target: Double
            if isRelativePlus {
                target = currentTime + secondsFromUnits
            } else if isRelativeMinus {
                target = currentTime - secondsFromUnits
            } else {
                target = secondsFromUnits
            }
            return clamp(target, duration: duration)
        }

        // 4. Pure numeric seconds (e.g. "90", "120.5", "120,5")
        if let val = Double(clean), val >= 0 {
            let target = isRelativePlus ? (currentTime + val) : (isRelativeMinus ? (currentTime - val) : val)
            return clamp(target, duration: duration)
        }

        return nil
    }

    /// Parses strings like "1h 30m 15s", "1.5h", "45m", "90s", "1ч 30мин", "1,5ч", "45сек"
    private static func parseUnits(_ text: String) -> Double? {
        var total: Double = 0.0
        var foundAny = false

        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = .whitespaces

        while !scanner.isAtEnd {
            guard let number = scanner.scanDouble() else {
                return nil
            }
            guard let unit = scanner.scanCharacters(from: CharacterSet.letters) else {
                return nil
            }
            let u = unit.lowercased()
            if hourUnits.contains(u) {
                total += number * 3600.0
            } else if minuteUnits.contains(u) {
                total += number * 60.0
            } else if secondUnits.contains(u) {
                total += number
            } else {
                return nil
            }
            foundAny = true
        }

        return foundAny ? total : nil
    }

    private static let hourUnits: Set<String> = [
        "h", "hr", "hrs", "hour", "hours",
        "г", "год", "година", "години", "годин",
        "ч", "час", "часа", "часов",
    ]
    private static let minuteUnits: Set<String> = [
        "m", "min", "mins", "minute", "minutes",
        "хв", "хвилина", "хвилини", "хвилин",
        "м", "мин", "минут", "минуты",
    ]
    private static let secondUnits: Set<String> = [
        "s", "sec", "secs", "second", "seconds",
        "с", "сек", "секунда", "секунди", "секунд",
        "секунды",
    ]

    private static func clamp(_ value: Double, duration: Double) -> Double {
        let maxDuration = duration > 0 ? duration : Double.greatestFiniteMagnitude
        return min(max(value, 0.0), maxDuration)
    }
}
