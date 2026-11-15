import Foundation
import Testing
import os

@testable import NitsCore
@testable import NitsKit

/// The files a YouTube page lists as formats, made into one manifest: a ladder for each codec, a sound for each language,
/// their addresses told by key, and what is offered to choose from.
@Suite("YouTube format manifest")
struct YouTubeFormatManifestTests {
    private static func format(
        _ id: String, ext: String, video: String? = nil, audio: String? = nil, height: Int? = nil, fps: Int = 25,
        range: String? = nil, language: String? = nil, note: String? = nil, tbr: Double = 500, drm: Bool? = nil,
        url: String? = nil
    ) -> String {
        var fields = [
            #""format_id": "\#(id)""#, #""ext": "\#(ext)""#, #""protocol": "https""#,
            #""url": "\#(url ?? "https://rr1.example/videoplayback?expire=1&sig=SECRET-\(id)")""#,
            #""vcodec": "\#(video ?? "none")""#, #""acodec": "\#(audio ?? "none")""#, #""tbr": \#(tbr)"#,
        ]
        if let height { fields += [#""height": \#(height)"#, #""width": \#(height * 16 / 9)"#, #""fps": \#(fps)"#] }
        if let range { fields.append(#""dynamic_range": "\#(range)""#) }
        if let language { fields.append(#""language": "\#(language)""#) }
        if let note { fields.append(#""format_note": "\#(note)""#) }
        if let drm { fields.append(#""has_drm": \#(drm)"#) }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    private static func info(_ formats: [String], extra: String = "") throws -> YTDLPInfo {
        let json =
            #"{"id": "aqz-KE-bpKQ", "title": "T", "extractor_key": "Youtube", "duration": 600, "requested_formats": [{"protocol": "https"}], "formats": ["#
            + formats.joined(separator: ",") + "]" + extra + "}"
        return try JSONDecoder().decode(YTDLPInfo.self, from: Data(json.utf8))
    }

    /// A page as YouTube's: H.264 and VP9 and AV1 at two sizes, an HDR VP9, a muxed 360p, the sound in AAC and Opus with
    /// a DRC duplicate, a storyboard.
    private static let ordinary = [
        format("136", ext: "mp4", video: "avc1.4D401F", height: 720, tbr: 1000),
        format("137", ext: "mp4", video: "avc1.640028", height: 1080, tbr: 3000),
        format("247", ext: "webm", video: "vp9", height: 720, tbr: 700),
        format("248", ext: "webm", video: "vp9", height: 1080, tbr: 1100),
        format("398", ext: "mp4", video: "av01.0.05M.08", height: 720, tbr: 650),
        format("399", ext: "mp4", video: "av01.0.08M.08", height: 1080, tbr: 1100),
        format("335", ext: "webm", video: "vp9.2", height: 1080, range: "HDR10", tbr: 6000),
        format("18", ext: "mp4", video: "avc1.42001E", audio: "mp4a.40.2", height: 360),
        format("140", ext: "m4a", audio: "mp4a.40.2", language: "en", tbr: 129),
        format("251", ext: "webm", audio: "opus", language: "en", tbr: 128),
        format("251-drc", ext: "webm", audio: "opus", language: "en", note: "medium, DRC", tbr: 129),
        format("617", ext: "mp4", video: "avc1.4D401F", height: 720, drm: true),
        #"{"format_id": "sb0", "ext": "mhtml", "protocol": "mhtml", "url": "https://i.example/sb", "vcodec": "none", "acodec": "none"}"#,
        format("hls", ext: "mp4", video: "avc1", height: 720, url: "https://m.example/x.m3u8").replacingOccurrences(
            of: #""protocol": "https""#, with: #""protocol": "m3u8_native""#),
    ]

    @Test(
        "Pictures of a codec, range and container are a set, sounds a set of each language; what plays nowhere is left out"
    )
    func listsTheFiles() throws {
        let manifest = try #require(try Self.info(Self.ordinary).fileManifest())
        // Keys, never signed addresses.
        #expect(!manifest.text.contains("SECRET") && !manifest.text.contains("rr1.example"))
        #expect(manifest.text.contains("files.nits.invalid"))
        #expect(
            manifest.keys == ["136", "137", "247", "248", "398", "399", "335", "140", "251"],
            "No muxed 360p, DRC duplicate, DRM format, storyboard or playlist: \(manifest.keys.sorted())")
        #expect(manifest.addresses["248"]?.contains("SECRET-248") == true)
        #expect(manifest.addresses.count == manifest.keys.count)
        // The sets: avc, vp9, av1, vp9 HDR (its own range) pictures and one sound (one language).
        #expect(manifest.text.components(separatedBy: #"contentType="video""#).count == 5)
        #expect(manifest.text.components(separatedBy: #"contentType="audio""#).count == 2)
        #expect(manifest.text.contains(#"value="16""#), "The HDR picture tells its transfer")
        #expect(manifest.text.contains(#"mimeType="video/webm" codecs="vp9.2""#))
        #expect(!manifest.text.contains("indexRange") && !manifest.text.contains("Initialization"))
    }

    @Test("A page with no picture, no sound, or neither as a file of its own is not made a manifest")
    func nothingToMake() throws {
        #expect(try Self.info([Self.ordinary[0], Self.ordinary[1]]).fileManifest() == nil, "No sound")
        #expect(try Self.info([Self.ordinary[8], Self.ordinary[9]]).fileManifest() == nil, "No picture")
        #expect(try Self.info(Self.ordinary, extra: #", "is_live": true"#).fileManifest() == nil, "A live stream")
        let other = try JSONDecoder().decode(
            YTDLPInfo.self,
            from: Data(
                #"{"id": "x", "extractor_key": "Vimeo", "formats": ["#.utf8
                    + Data(Self.ordinary.joined(separator: ",").utf8)
                    + Data("]}".utf8)))
        #expect(other.fileManifest() == nil, "Only YouTube's files are told apart this way")
    }

    @Test(
        "Each language is a set of its own, the original the main one; the key of a dubbed sound is its language, not its place"
    )
    func languages() throws {
        let formats = [
            Self.format("137", ext: "mp4", video: "avc1.640028", height: 1080),
            Self.format("249-0", ext: "webm", audio: "opus", language: "de", note: "German, low", tbr: 47),
            Self.format("249-1", ext: "webm", audio: "opus", language: "uk", note: "Ukrainian, low", tbr: 48),
            Self.format(
                "139-20", ext: "m4a", audio: "mp4a.40.5", language: "en", note: "English original (default), low"),
        ]
        let formatsDecoded = try Self.info(formats).formats ?? []
        let manifest = try #require(YouTubeFormatManifest(formats: formatsDecoded))
        #expect(manifest.keys == ["137", "249-de", "249-uk", "139-en"])
        #expect(manifest.text.components(separatedBy: #"value="main""#).count == 2)
        #expect(manifest.text.components(separatedBy: #"value="dub""#).count == 3)
        // Asked again, the list is in another order: the same sounds have the same keys.
        let reordered = try Self.info([formats[0], formats[2], formats[1], formats[3]]).formats ?? []
        #expect(YouTubeFormatManifest.addresses(of: reordered).keys.sorted() == manifest.addresses.keys.sorted())
        #expect(YouTubeFormatManifest.addresses(of: reordered)["249-uk"] == manifest.addresses["249-uk"])
    }

    @Test(
        "The player offers the codecs as for an .mpd of the network: the one it prefers first, each a location of the manifest itself"
    )
    func choices() throws {
        let manifest = try #require(try Self.info(Self.ordinary).fileManifest())
        let source = YouTubeFormatSource(urls: manifest.addresses) { [:] }
        var media = ResolvedMedia(path: MediaURL.inlineDASHManifest(manifest.text), headers: ["User-Agent": "x"])
        media.files = MediaFiles(source)
        let offered = MediaResolverChain.offeringChoices(of: media, codecs: VideoCodecPreference())
        #expect(offered.videoFormats.count >= 3, "\(offered.videoFormats.map(\.codec))")
        #expect(Set(offered.videoFormats.map(\.codec)).isSuperset(of: ["H.264", "VP9", "AV1"]))
        #expect(offered.videoFormats.contains { $0.codec == "VP9 HDR" })
        #expect(offered.selectedVideoFormatID == offered.videoFormats.first?.id)
        // Each is the manifest itself with the picture's id in the fragment, which only the client reads.
        let inline = String(media.path.prefix { $0 != "#" })
        for format in offered.videoFormats {
            #expect(format.url.hasPrefix(inline + "#nits-video="), "\(format.url.prefix(80))")
        }
        #expect(offered.path == offered.videoFormats.first?.url)
        // The selection reaches the client from the location.
        #expect(
            offered.selecting(videoFormat: offered.videoFormats[1].id)?.path == offered.videoFormats[1].url)
        // Not the manifests that are none of this's: a live history, or one the host has not made of keys.
        var plain = media
        plain.files = nil
        #expect(MediaResolverChain.offeringChoices(of: plain, codecs: VideoCodecPreference()) == plain)
    }

    @Test(
        "Addresses are the source's, renewed once for every caller, and merged: a file the renewal leaves out keeps its own"
    )
    func renewal() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let source = YouTubeFormatSource(
            urls: ["a": "https://x.example/a?sig=1", "b": "https://x.example/b?sig=1"], settling: .zero
        ) {
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(100))
            return ["a": "https://x.example/a?sig=2"]
        }
        #expect(source.address(forKey: "a")?.absoluteString == "https://x.example/a?sig=1")
        #expect(source.address(forKey: "missing") == nil)
        async let first = Task.detached { source.renewAddresses(shouldAbort: { false }) }.value
        async let second = Task.detached { source.renewAddresses(shouldAbort: { false }) }.value
        let (one, two) = await (first, second)
        #expect(one && two)
        #expect(calls.withLock { $0 } == 1, "A read refused while a renewal runs joins it")
        #expect(source.address(forKey: "a")?.absoluteString == "https://x.example/a?sig=2")
        #expect(source.address(forKey: "b")?.absoluteString == "https://x.example/b?sig=1")
        #expect(source.renewals == 1)
        // A renewal that fails is false, not a crash, and the addresses are as they were.
        let failing = YouTubeFormatSource(urls: ["a": "https://x.example/a"], settling: .zero) {
            throw MediaResolutionError("no")
        }
        #expect(!failing.renewAddresses(shouldAbort: { false }))
        #expect(failing.address(forKey: "a")?.absoluteString == "https://x.example/a")
    }

    @Test(
        "An address refused in its first seconds is waited for, not renewed: the same one is asked again, and later renewed"
    )
    func settling() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let source = YouTubeFormatSource(urls: ["a": "https://x.example/a?sig=1"], settling: .milliseconds(300)) {
            calls.withLock { $0 += 1 }
            return ["a": "https://x.example/a?sig=2"]
        }
        let began = ContinuousClock.now
        #expect(source.renewAddresses(shouldAbort: { false }))
        #expect(ContinuousClock.now - began >= .milliseconds(250), "Waited for the address to settle")
        #expect(calls.withLock { $0 } == 0 && source.address(forKey: "a")?.absoluteString.hasSuffix("sig=1") == true)
        // Once it is older than that, the refusal is of a bad address: yt-dlp is asked.
        #expect(source.renewAddresses(shouldAbort: { false }))
        #expect(calls.withLock { $0 } == 1 && source.address(forKey: "a")?.absoluteString.hasSuffix("sig=2") == true)
        // The wait gives way to an abort.
        let fresh = YouTubeFormatSource(urls: [:], settling: .seconds(30)) { [:] }
        #expect(!fresh.renewAddresses(shouldAbort: { true }))
    }

    @Test("From 720p a ladder keeps its 60 fps rungs and drops the 30 fps ones; below that both stay")
    func frameRates() throws {
        let formats = [
            Self.format("135", ext: "mp4", video: "avc1.4D401F", height: 480, fps: 30),
            Self.format("136", ext: "mp4", video: "avc1.4D401F", height: 720, fps: 30),
            Self.format("298", ext: "mp4", video: "avc1.4D401F", height: 720, fps: 60),
            Self.format("299", ext: "mp4", video: "avc1.64002A", height: 1080, fps: 60),
            Self.format("247", ext: "webm", video: "vp9", height: 720, fps: 30),
            Self.format("140", ext: "m4a", audio: "mp4a.40.2", language: "en"),
        ]
        let manifest = try #require(YouTubeFormatManifest(formats: try Self.info(formats).formats ?? []))
        // The H.264 ladder: 480p30, 720p60, 1080p60. VP9 has no 60 fps rung, so its 30 fps one stays.
        #expect(manifest.keys == ["135", "298", "299", "247", "140"], "\(manifest.keys.sorted())")
        #expect(manifest.addresses.keys.sorted() == manifest.keys.sorted())
    }

    @Test("Two sounds of one language and itag keep their own ids, so neither's address overwrites the other's")
    func sameLanguage() throws {
        let formats = [
            Self.format("137", ext: "mp4", video: "avc1.640028", height: 1080),
            Self.format(
                "249-0", ext: "webm", audio: "opus", language: "de", note: "German dubbed", url: "https://x.example/a"),
            Self.format(
                "249-1", ext: "webm", audio: "opus", language: "de", note: "German descriptive",
                url: "https://x.example/b"),
        ]
        let manifest = try #require(YouTubeFormatManifest(formats: try Self.info(formats).formats ?? []))
        #expect(manifest.keys == ["137", "249-0", "249-1"])
        #expect(
            manifest.addresses["249-0"] == "https://x.example/a" && manifest.addresses["249-1"] == "https://x.example/b"
        )
    }
}
