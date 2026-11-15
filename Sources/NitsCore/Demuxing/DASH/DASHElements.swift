import Foundation
internal import NitsStreaming

/// What an MPD's elements say, read the same way by the resolver's manifest (`DASHManifest`) and the client's source
/// (`DASHPresentation`).
enum DASHElements {
    /// "video", "audio", "text"…: the `contentType`, else the first part of the `mimeType`.
    static func kind(of element: XMLTreeElement) -> String? {
        // Some generators put the content type on a `ContentComponent` of the set instead.
        let contentType =
            element.attribute("contentType")
            ?? element.elements(named: "ContentComponent").lazy.compactMap { $0.attribute("contentType") }.first
        if let contentType { return contentType.lowercased() }
        return element.attribute("mimeType").map { String($0.prefix { $0 != "/" }).lowercased() }
    }

    /// How much a sound is the sound of its language, by the roles of its set and of itself: 2 the main track, 1 one
    /// without a role (or a dub, which is the sound of its own language), 0 a commentary, a description, an alternative,
    /// or one with an `Accessibility` descriptor (audio description): played only when the language has nothing else.
    static func roleRank(of representation: XMLTreeElement, in set: XMLTreeElement) -> Int {
        // The standard allows both on the set and on the representation.
        let roles = (set.elements(named: "Role") + representation.elements(named: "Role"))
            .compactMap { $0.attribute("value")?.lowercased() }
        if roles.contains("main") { return 2 }
        if !(set.elements(named: "Accessibility") + representation.elements(named: "Accessibility")).isEmpty {
            return 0
        }
        return roles.allSatisfy { $0 == "dub" } ? 1 : 0
    }

    /// An adaptation set of I-frames for fast forward, not a picture to play.
    static func isTrickMode(_ set: XMLTreeElement) -> Bool {
        (set.elements(named: "EssentialProperty") + set.elements(named: "SupplementalProperty")).contains {
            $0.attribute("schemeIdUri")?.contains("trickmode") == true
        }
    }

    /// The transfer the manifest's properties tell (`TransferCharacteristics`, H.273): 16 PQ, 18 HLG; nil when they
    /// tell none of those.
    static func hdrTransfer(of element: XMLTreeElement) -> HLSVideoRange? {
        for property in element.elements(named: "EssentialProperty") + element.elements(named: "SupplementalProperty")
        where property.attribute("schemeIdUri")?.hasSuffix("TransferCharacteristics") == true {
            switch property.attribute("value") {
            case "16": return .pq
            case "18": return .hlg
            default: continue
            }
        }
        return nil
    }

    /// The id of a representation: its own, or where it is (its set's place and its own) when it has none or another
    /// has it already in the period (ids are unique in a period by the standard; some manifests are not). The resolver
    /// (`DASHManifest`) and the client (`DASHPresentation`) name them by this one rule, as a choice is told by the id.
    static func uniqueID(
        of representation: XMLTreeElement, set: Int, index: Int, used: inout Set<String>
    ) -> String {
        var id = representation.attribute("id") ?? "\(set).\(index)"
        if !used.insert(id).inserted {
            id = "\(set).\(index)"
            used.insert(id)
        }
        return id
    }

    /// "24", "30000/1001".
    static func frameRate(of text: String) -> Double? {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        let rate: Double
        switch parts.count {
        case 1: rate = parts[0]
        case 2 where parts[1] != 0: rate = parts[0] / parts[1]
        default: return nil
        }
        // A rate no picture has (inf, nan, 1e300) is none: labels and pacing turn it into whole numbers.
        return rate.isFinite && rate > 0 && rate < 10_000 ? rate : nil
    }

    /// An ISO 8601 duration ("PT0H9M54.00S", "P1DT2H") in seconds; years and months as 365 and 30 days.
    static func duration(of text: String) -> Double? {
        guard text.hasPrefix("P") else { return nil }
        var seconds = 0.0
        var number = ""
        var inTime = false
        for character in text.dropFirst() {
            if character == "T" {
                inTime = true
            } else if character.isNumber || character == "." {
                number.append(character)
            } else {
                guard let value = Double(number) else { return nil }
                number = ""
                switch (character, inTime) {
                case ("Y", false): seconds += value * 365 * 86400
                case ("M", false): seconds += value * 30 * 86400
                case ("W", false): seconds += value * 7 * 86400
                case ("D", false): seconds += value * 86400
                case ("H", true): seconds += value * 3600
                case ("M", true): seconds += value * 60
                case ("S", true): seconds += value
                default: return nil
                }
            }
        }
        return number.isEmpty ? seconds : nil
    }

    /// An `xs:dateTime` ("2024-05-01T12:00:00.123Z", the zone optional: UTC then), as `availabilityStartTime`, `UTCTiming`
    /// and the `direct` scheme tell it.
    static func dateTime(of text: String) -> Date? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tIndex = text.firstIndex(of: "T") else { return nil }
        let time = text[tIndex...]
        if !time.contains("Z") && !time.contains("+") && !time.dropFirst().contains("-") { text += "Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// "828-3067": the bytes from the first to the last, both included.
    static func byteRange(of text: String) -> HLSByteRange? {
        let parts = text.split(separator: "-").compactMap { Int64($0) }
        guard parts.count == 2, parts[0] >= 0, parts[1] >= parts[0] else { return nil }
        return HLSByteRange(offset: parts[0], length: parts[1] - parts[0] + 1)
    }
}
