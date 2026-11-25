import CoreMedia
import Foundation
import Testing

@testable import NitsCore
@testable import NitsKit
@testable import NitsYTDLP

/// A real YouTube video played from the manifest of all its files, measured; needs yt-dlp and the network, so it runs
/// only with `NITS_YOUTUBE_URL` set (one page per run). Reports what it saw as the test's output.
@Suite("YouTube real stream", .enabled(if: ProcessInfo.processInfo.environment["NITS_YOUTUBE_URL"] != nil))
struct YouTubeRealStreamTests {
    @Test("The page's files play as a ladder, with a seek, from the manifest")
    func plays() async throws {
        let page = try #require(URL(string: ProcessInfo.processInfo.environment["NITS_YOUTUBE_URL"] ?? ""))
        let began = ContinuousClock.now
        let host = YTDLPResolver(customPath: "", sponsorBlock: false)
        let media = try #require(
            try await MediaResolverChain(codecs: VideoCodecPreference(), host: host).resolve(page, headers: [:]))
        let resolved = ContinuousClock.now - began
        print(
            "resolved in \(resolved): files \(media.files != nil), formats \(media.videoFormats.map { "\($0.codec) \($0.height)p" })"
        )
        #expect(media.files != nil, "No manifest of the page's files")

        let context = MediaDemuxer.InterruptContext()
        let openBegan = ContinuousClock.now
        let attempt = MediaDemuxer(
            url: media.path, headers: media.headers, httpRequestSize: nil, interruptContext: context, files: media.files
        )
        print("open error: \(String(describing: context.lastError))")
        if attempt == nil {
            for entry in LogStore.shared.snapshot().suffix(25) { print(entry.plainTextFormatted.prefix(300)) }
        }
        let demuxer = try #require(attempt)
        let opened = ContinuousClock.now - openBegan
        print("opened in \(opened): \(demuxer.variants.count) rungs, \(demuxer.durationSeconds) s")
        for variant in demuxer.variants { print("  rung \(variant.id): \(variant)") }
        #expect(demuxer.variants.count > 1, "A ladder")

        demuxer.startReadAhead(limits: .init(seconds: 20), held: true)
        let seekAt = demuxer.durationSeconds / 2
        let seekBegan = ContinuousClock.now
        demuxer.seek(to: seekAt, exact: true)
        let sample = try #require(demuxer.nextVideoSample())
        let landed = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        print("seek to \(seekAt) landed at \(landed) in \(ContinuousClock.now - seekBegan)")
        #expect(abs(landed - seekAt) < 12)
        #expect(media.audioFiles.isEmpty)
        #expect(demuxer.audioTracks.count >= 1, "The sound is in the manifest")
        print("audio tracks: \(demuxer.audioTracks.map { $0.language })")
    }
}
