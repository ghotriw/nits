import Testing

@testable import NitsStreaming

@Suite("DASH picture group")
struct DASHPictureGroupTests {
    private static func video(
        _ id: String, codecs: String, supplemental: String? = nil, range: VideoRange? = nil, isWebM: Bool = false,
        bandwidth: Int = 1_000_000
    ) -> DASHPresentation.Representation {
        DASHPresentation.Representation(
            id: id, kind: .video, bandwidth: bandwidth, codecs: codecs, supplementalCodecs: supplemental, width: 1920,
            height: 1080, frameRate: nil, videoRange: range, language: nil, roleRank: 0, set: 0, initSection: nil,
            presentationTimeOffset: 0, segments: [], index: nil, isWebM: isWebM)
    }

    @Test("One codec family, supplemental codec, range and container make one group")
    func sameGroup() {
        let a = Self.video("a", codecs: "avc1.4d401f")
        let b = Self.video("b", codecs: "avc3.640028", bandwidth: 5_000_000)
        #expect(DASHPictureGroup(a) == DASHPictureGroup(b))
        #expect(DASHPictureGroup(a) != DASHPictureGroup(Self.video("c", codecs: "avc1", range: .pq)))
        #expect(DASHPictureGroup(a) != DASHPictureGroup(Self.video("d", codecs: "hvc1")))
        #expect(
            DASHPictureGroup(Self.video("e", codecs: "hvc1", supplemental: "dvh1.08.06"))
                != DASHPictureGroup(Self.video("f", codecs: "hvc1")))
    }

    @Test("A WebM and an MP4 of one codec are different groups, also numbered together")
    func containersApart() {
        let mp4 = Self.video("mp4", codecs: "vp09.00.40.08")
        let webm = Self.video("webm", codecs: "vp9", isWebM: true, bandwidth: 2_000_000)
        #expect(DASHPictureGroup(mp4) != DASHPictureGroup(webm))
        // Two pictures that are alone in their group: neither is numbered on the other.
        let numbered = DASHPlaylists.numberedPictures([mp4, webm])
        #expect(numbered.map(\.numbering) == [.own, .own])
    }
}
