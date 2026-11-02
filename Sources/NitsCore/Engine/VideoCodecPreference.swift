import Foundation

/// The user's order of video codecs for choosing among the pictures of one size a manifest offers (DASH), most
/// preferred first. A codec switched off ranks after every one that is on, still played when it is all there is. The
/// size comes first, then HDR, and the codec only decides between those: the bitrate of different codecs says nothing
/// of their quality (VP9 and AV1 take a third to half fewer bits than H.264 for the same picture).
public struct VideoCodecPreference: Sendable, Equatable {
    /// H.264 and HEVC have hardware decoders on every Apple Silicon Mac; AV1's come with the M3, VP9's only in part.
    public static let defaultOrder = ["hevc", "avc", "av1", "vp9", "vp8"]

    /// The video families (`CodecFamily.video(in:)`) the order is of; Dolby Vision ranks with the codec it is made on.
    public static var families: [String] { defaultOrder }

    /// Every family, most preferred first.
    public private(set) var order: [String]
    public private(set) var disabled: Set<String>

    public init(order: [String] = Self.defaultOrder, disabled: Set<String> = []) {
        var seen = Set<String>()
        let listed = order.filter { Self.families.contains($0) && seen.insert($0).inserted }
        self.order = listed + Self.defaultOrder.filter { !seen.contains($0) }
        self.disabled = disabled.intersection(Self.families)
    }

    /// As stored in user defaults: the families in order, a codec switched off with a leading `-` ("hevc,avc,-vp9").
    public init(stored value: String) {
        var order: [String] = []
        var disabled = Set<String>()
        for entry in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            let isOff = entry.hasPrefix("-")
            let family = isOff ? String(entry.dropFirst()) : entry
            order.append(family)
            if isOff { disabled.insert(family) }
        }
        self.init(order: order, disabled: disabled)
    }

    public var stored: String {
        order.map { disabled.contains($0) ? "-\($0)" : $0 }.joined(separator: ",")
    }

    public func isEnabled(_ family: String) -> Bool {
        !disabled.contains(family)
    }

    public mutating func setEnabled(_ isEnabled: Bool, family: String) {
        guard Self.families.contains(family) else { return }
        if isEnabled { disabled.remove(family) } else { disabled.insert(family) }
    }

    /// Moves entries as a list view's `onMove` does: `destination` is a position in the list before the move. Entries
    /// and a destination outside the list are left out and clamped.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let source = source.filter { order.indices.contains($0) }
        let destination = min(max(destination, 0), order.count)
        let moved = source.map { order[$0] }
        let before = source.filter { $0 < destination }.count
        order = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        order.insert(contentsOf: moved, at: destination - before)
    }

    /// Moves `family` `places` up (negative) or down the list, to its ends at most.
    public mutating func shift(_ family: String, by places: Int) {
        guard let index = order.firstIndex(of: family) else { return }
        let target = min(max(index + places, 0), order.count - 1)
        order.insert(order.remove(at: index), at: target)
    }

    /// The family a codec's is ranked as: Dolby Vision on HEVC, AVC or AV1 as that codec.
    static func base(of family: String) -> String {
        switch family {
        case "dvhevc": "hevc"
        case "dvavc": "avc"
        case "dvav1": "av1"
        default: family
        }
    }

    /// Lower is more preferred. A codec off, after the codecs on; one not known (not told by the manifest), last.
    public func rank(ofFamily family: String) -> Int {
        let base = Self.base(of: family)
        guard let index = order.firstIndex(of: base) else { return 1000 }
        return disabled.contains(base) ? 100 + index : index
    }

    /// As shown ("H.264", "HEVC", "AV1", "VP9", "VP8").
    public static func displayName(of family: String) -> String {
        CodecFamily.displayName(ofVideo: family)
    }
}
