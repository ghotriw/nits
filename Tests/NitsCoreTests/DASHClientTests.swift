import CoreMedia
import Foundation
import Testing
import os

@testable import NitsCore

/// The client playing a DASH manifest told as playlists (`DASHPlaylists` into `HLSInput`): the `dashLadder` preset
/// (three rungs, a keyframe at each 1 s segment, segments that each hold their initialization) from `TestHTTPServer`,
/// as the resolver's manifest of it.
@Suite("DASH client", .serialized, .networkServer)
struct DASHClientTests {
    private static var count: Int { SyntheticTestMediaFactory.dashLadderSegmentCount }

    static func server() throws -> TestHTTPServer? {
        guard let first = SyntheticTestMediaFactory.ensureMedia(preset: .dashLadder) else { return nil }
        let root = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent()
        return try TestHTTPServer(root: root)
    }

    /// The ladder's manifest (`rungs` of it), as the resolver writes it.
    static func manifest(_ server: TestHTTPServer, rungs only: [Int]? = nil) -> String {
        var streams = SyntheticTestMediaFactory.dashLadderRungs.enumerated().filter {
            only?.contains($0.offset) ?? true
        }.map { index, rung in
            SegmentedDASHManifest.Stream(
                kind: .video, id: "v\(index)", container: "mp4", codecs: "avc1.64001e", bandwidth: rung.bitrate,
                width: rung.width, height: rung.height, url: server.url("video\(index)"))
        }
        streams.append(.init(kind: .audio, id: "a", container: "mp4", codecs: "mp4a.40.2", url: server.url("audio")))
        return SegmentedDASHManifest(streams: streams, segmentDuration: 1, segmentCount: count).text()
    }

    /// A demuxer of the client opened on `source`.
    static func demuxer(_ source: DASHPlaylists) -> MediaDemuxer? {
        let interrupt = FFmpegInterrupt()
        guard
            let input = HLSInput(
                master: source.masterURL, playlists: source, source: source.address.absoluteString, allowsFiles: false,
                headers: [:], interrupt: interrupt, streamingName: "DASH")
        else { return nil }
        return MediaDemuxer(
            input: input, interruptContext: interrupt, ownsInterruptContext: true, audioOnly: false, liveHistory: nil,
            liveWindowState: OSAllocatedUnfairLock(initialState: nil))
    }

    /// A demuxer of the client opened on the ladder's manifest (`rungs` of it), inline as the resolver hands it.
    static func demuxer(_ server: TestHTTPServer, rungs: [Int]? = nil) -> MediaDemuxer? {
        let text = manifest(server, rungs: rungs)
        return demuxer(DASHPlaylists(address: URL(string: server.url("manifest.mpd"))!, inline: Data(text.utf8)))
    }

    private static func presentationTimes(of demuxer: MediaDemuxer) -> [Double] {
        var times: [Double] = []
        while let sample = demuxer.nextVideoSample() {
            times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        return times
    }

    static func manifestRequests(_ server: TestHTTPServer) -> Int {
        server.requests.filter { $0.path.hasSuffix("manifest.mpd") }.count
    }

    @Test("The ladder opens as variants and plays every picture once, with its sound")
    func playsTheLadder() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(Self.demuxer(server))
        #expect(demuxer.variants.count == SyntheticTestMediaFactory.dashLadderRungs.count)
        #expect(abs(demuxer.durationSeconds - Double(Self.count)) < 0.1)
        #expect(demuxer.hasAudio)
        let times = Self.presentationTimes(of: demuxer).sorted()
        #expect(times.count == 25 * Self.count)
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(steps.allSatisfy { abs($0 - 0.04) < 0.002 }, "irregular steps")
    }

    @Test("A seek lands on the segment that holds the target, read from its own address")
    func seeks() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let demuxer = try #require(Self.demuxer(server, rungs: [0]))
        demuxer.seek(to: 7.5, exact: false)
        let sample = try #require(demuxer.nextVideoSample())
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        #expect(time >= 6.9 && time <= 7.1, "landed at \(time)")
    }

    @Test("A manifest at an address is read once for the opening's playlists, asked for side by side")
    func readsTheManifestOnce() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let text = Self.manifest(server)
        server.setResponder(forPath: "manifest.mpd") { Data(text.utf8) }
        let source = DASHPlaylists(address: URL(string: server.url("manifest.mpd"))!)
        let demuxer = try #require(Self.demuxer(source))
        #expect(demuxer.variants.count == SyntheticTestMediaFactory.dashLadderRungs.count)
        #expect(Self.manifestRequests(server) == 1)
    }

    @Test("A read given up by its caller's abort is no answer: one waiting for it reads again itself")
    func abortedReadIsReadAgain() throws {
        guard let server = try Self.server() else { return }
        defer { server.stop() }
        let text = Self.manifest(server)
        server.setResponder(forPath: "manifest.mpd") { Data(text.utf8) }
        // The first read is never answered: only its caller's abort ends it.
        server.setBehavior(.init(failure: .hang), forPaths: { $0.hasSuffix("manifest.mpd") })
        let address = URL(string: server.url("manifest.mpd"))!
        let source = DASHPlaylists(address: address)
        let transport = HTTPSessionTransport(source: address.absoluteString, headers: [:]) { false }
        let loader = HLSSegmentLoader(transport: transport)
        let aborted = OSAllocatedUnfairLock(initialState: false)
        let first = loader.aborting { aborted.withLock { $0 } }

        /// Waits (in steps, without sleeping a pool thread) until `condition` holds, ten seconds at most.
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let step = DispatchSemaphore(value: 0)
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                guard ContinuousClock.now < deadline else { return false }
                _ = step.wait(timeout: .now() + .milliseconds(10))
            }
            return true
        }
        let outcomes = OSAllocatedUnfairLock<[String: Result<Bool, HLSPlaylistSourceError>]>(initialState: [:])
        let group = DispatchGroup()
        func ask(_ name: String, through reader: HLSSegmentLoader) {
            group.enter()
            DispatchQueue.global().async {
                let result = Result { () throws(HLSPlaylistSourceError) in
                    if case .master = try source.playlist(at: source.masterURL, variables: [:], loader: reader) {
                        return true
                    }
                    return false
                }
                outcomes.withLock { $0[name] = result }
                group.leave()
            }
        }
        ask("first", through: first)
        #expect(waitUntil { Self.manifestRequests(server) == 1 }, "the first read was not asked for")
        ask("second", through: loader)
        #expect(waitUntil { source.waitingReaders > 0 }, "the second did not wait for the first")
        // Answered from now on; then the first gives up.
        server.setBehavior(.init(), forPaths: { $0.hasSuffix("manifest.mpd") })
        aborted.withLock { $0 = true }
        #expect(group.wait(timeout: .now() + 10) == .success)
        let results = outcomes.withLock { $0 }
        #expect(results["first"] == .failure(.load(.interrupted)))
        #expect(results["second"] == .success(true))
        #expect(Self.manifestRequests(server) == 2)
    }

    // MARK: - Routing (`MediaDemuxer.init`)

    @Test("A demuxer opens the resolver's manifest with the client, with the address it came from")
    func demuxerOpensWithTheClient() throws {
        guard MediaDemuxer.dashInput != .ffmpeg, let server = try Self.server() else { return }
        defer { server.stop() }
        let address = try #require(URL(string: server.url("manifest.mpd")))
        let demuxer = try #require(
            MediaDemuxer(url: MediaURL.inlineDASHManifest(Self.manifest(server), source: address)))
        let input = try #require(demuxer.input as? HLSInput)
        #expect(input.streamingName == "DASH")
        #expect(demuxer.variants.count == SyntheticTestMediaFactory.dashLadderRungs.count)
        #expect(demuxer.isNetworkSource)
        #expect(Self.manifestRequests(server) == 0, "An inline manifest is not fetched")
    }

    @Test("What the client refuses is left to FFmpeg's demuxer; a manifest that fails to load is the opening's failure")
    func refusalFallsBackToFFmpeg() throws {
        guard MediaDemuxer.dashInput == .auto, let made = SingleFileDASHTests.make() else { return }
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let server = try TestHTTPServer(root: made.directory)
        defer { server.stop() }
        // One file per representation (`SegmentBase`) whose index range holds no index: the client refuses the picture,
        // which the others depend on. FFmpeg's demuxer reads the file from its start.
        let manifest = SingleFileDASHTests.manifest(made, brokenIndex: true)
        server.setResponder(forPath: "dash.mpd") { Data(manifest.utf8) }
        let demuxer = try #require(MediaDemuxer(url: server.url("dash.mpd")))
        #expect(demuxer.input is FFmpegInput)
        #expect(demuxer.nextVideoSample() != nil)

        let before = server.requests.count
        #expect(MediaDemuxer(url: server.url("missing.mpd")) == nil)
        let asked = server.requests.dropFirst(before).filter { $0.path.hasSuffix("missing.mpd") }
        #expect(asked.count == 1, "Asked again by FFmpeg's demuxer: \(asked.count) requests")

        // A refusal recorded by an earlier attempt on the same context is not this one's: still no FFmpeg.
        let interrupt = FFmpegInterrupt()
        interrupt.recordError(code: HLSPlaylistSourceError.unsupported("").code, message: "an earlier refusal")
        let again = server.requests.count
        #expect(MediaDemuxer(url: server.url("missing.mpd"), interruptContext: interrupt) == nil)
        #expect(server.requests.dropFirst(again).filter { $0.path.hasSuffix("missing.mpd") }.count == 1)
        #expect(interrupt.lastError?.code != HLSPlaylistSourceError.unsupported("").code, "The failure is the load's")

        // After a refusal, FFmpeg's outcome is the opening's: the refusal is not left as its error.
        let fallback = FFmpegInterrupt()
        _ = try #require(MediaDemuxer(url: server.url("dash.mpd"), interruptContext: fallback))
        #expect(fallback.lastError == nil, "\(String(describing: fallback.lastError))")
    }
}
