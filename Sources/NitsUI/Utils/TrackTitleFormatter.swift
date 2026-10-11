import Foundation

public enum TrackTitleFormatter {
    /// Formats an audio track title with localized language name or fallback
    public static func format(title: String, language: String, fallbackId: Int) -> String {
        var parts: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            parts.append(trimmedTitle)
        }

        let trimmedLang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLang.isEmpty {
            let loc = Locale.current
            if let localized = loc.localizedString(forLanguageCode: trimmedLang) {
                parts.append("[\(localized.capitalized)]")
            } else {
                parts.append("[\(trimmedLang.uppercased())]")
            }
        }

        if parts.isEmpty {
            parts.append("Track #\(fallbackId)")
        }

        return parts.joined(separator: " ")
    }
}
