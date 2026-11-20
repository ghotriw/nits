import Foundation

/// What switches with what among the pictures of a DASH manifest: representations of one video codec, one supplemental
/// codec (Dolby Vision's on an HDR10 base), one transfer (PQ, HLG, or none told) and one container (a WebM and an MP4 of
/// one codec never switch with each other) are one ladder. One rule for the client (`DASHPlaylists.pictures(of:selection:)`
/// and `numberedPictures`) and for the resolver that lists the pictures (`DASHManifest`).
///
/// Whether a representation is a rung at all (a bitrate told) is not part of it: that is "is it a rung", not "which ladder".
package struct DASHPictureGroup: Hashable, Sendable {
    /// The video codec family (`CodecFamily.video(in:)`); nil when the manifest tells none or none known.
    package var codec: String?
    /// The supplemental codec's family; nil when none.
    package var supplemental: String?
    package var range: VideoRange?
    package var isWebM: Bool

    package init(codecs: String?, supplementalCodecs: String?, range: VideoRange?, isWebM: Bool) {
        codec = codecs.flatMap(CodecFamily.video(in:))
        supplemental = supplementalCodecs.flatMap(CodecFamily.video(in:))
        self.range = range
        self.isWebM = isWebM
    }

    package init(_ representation: DASHPresentation.Representation) {
        self.init(
            codecs: representation.codecs, supplementalCodecs: representation.supplementalCodecs,
            range: representation.videoRange, isWebM: representation.isWebM)
    }

    /// The group of every picture when the client plays all of them as one ladder (`DASHPlaylists.numberedPictures`).
    static let all = DASHPictureGroup(codecs: nil, supplementalCodecs: nil, range: nil, isWebM: false)
}
