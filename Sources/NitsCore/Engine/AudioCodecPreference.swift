import Foundation
internal import NitsStreaming

/// The user's order of audio codecs for choosing among the sounds of one language a manifest offers (DASH), most
/// preferred first. The role comes first (the main track over a commentary), and the codec decides before the bitrate:
/// the bitrate of different codecs says nothing of their quality (Opus is VBR, and 116 kbit/s of it is no worse than
/// AAC's 129).
public struct AudioCodecPreference: Sendable, Equatable {
    public static var defaultOrder: [String] { CodecFamily.audioFamilies }

    /// Every family, most preferred first.
    public private(set) var order: [String]

    public init(order: [String] = Self.defaultOrder) {
        var seen = Set<String>()
        let listed = order.filter { Self.defaultOrder.contains($0) && seen.insert($0).inserted }
        self.order = listed + Self.defaultOrder.filter { !seen.contains($0) }
    }

    /// As stored in user defaults: the families in order ("opus,aac,eac3").
    public init(stored value: String) {
        self.init(order: value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    public var stored: String { order.joined(separator: ",") }

    /// Moves `family` `places` up (negative) or down the list, to its ends at most.
    public mutating func shift(_ family: String, by places: Int) {
        guard let index = order.firstIndex(of: family) else { return }
        let target = min(max(index + places, 0), order.count - 1)
        order.insert(order.remove(at: index), at: target)
    }

    /// Lower is more preferred; a codec not known (not told by the manifest) last.
    public func rank(ofFamily family: String?) -> Int {
        family.flatMap { order.firstIndex(of: $0) } ?? order.count
    }

    /// As shown ("Opus", "AAC", "E-AC-3", "AC-3", "FLAC", "ALAC", "DTS", "Vorbis", "MP3").
    public static func displayName(of family: String) -> String {
        switch family {
        case "opus": "Opus"
        case "aac": "AAC"
        case "eac3": "E-AC-3"
        case "ac3": "AC-3"
        case "flac": "FLAC"
        case "alac": "ALAC"
        case "dts": "DTS"
        case "vorbis": "Vorbis"
        case "mp3": "MP3"
        default: family.uppercased()
        }
    }
}
