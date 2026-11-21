import Foundation
import NitsCore
import Testing
import os

@testable import NitsYTDLP

/// The resolver over a `YTDLPRunner` that is no process: what a host on iOS gives it. The runner answers canned JSON.
@Suite("yt-dlp resolver over a runner")
struct YTDLPRunnerTests {
    static let page = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!

    /// A page's answer with a picture and its audio as separate HTTPS files, as YouTube's.
    static let separateStreams = """
        {"_type": "video", "id": "aqz-KE-bpKQ", "title": "Big Buck Bunny", "extractor_key": "Youtube",
         "requested_formats": [
           {"url": "https://media.example/video", "protocol": "https", "vcodec": "av01.0.13M.08", "acodec": "none",
            "downloader_options": {"http_chunk_size": 10485760}},
           {"url": "https://media.example/audio", "protocol": "https", "vcodec": "none", "acodec": "opus",
            "language": "en", "format_note": "English (US) original (default), medium",
            "downloader_options": {"http_chunk_size": 5242880}}
         ]}
        """

    /// What a runner of a test does: answers with `answer`, and notes what it was asked and cancelled.
    final class Runner: YTDLPRunner {
        struct Record {
            var arguments: [[String]] = []
            var wasCancelled = false
        }
        struct Failure: Error {}

        enum Behaviour {
            /// Answers at once.
            case answer(YTDLPOutput)
            /// Waits (so it honours cancellation) and throws `Failure` when cancelled, not `CancellationError`.
            case waitsAndThrowsOwnError
        }

        let record = OSAllocatedUnfairLock(initialState: Record())
        let behaviour: Behaviour
        let isAvailable: Bool

        init(_ behaviour: Behaviour, isAvailable: Bool = true) {
            self.behaviour = behaviour
            self.isAvailable = isAvailable
        }

        static func answering(_ json: String) -> Runner {
            Runner(.answer(YTDLPOutput(status: 0, stdout: Data(json.utf8), stderr: Data())))
        }

        static func failing(_ stderr: String) -> Runner {
            Runner(.answer(YTDLPOutput(status: 1, stdout: Data(), stderr: Data(stderr.utf8))))
        }

        func run(arguments: [String]) async throws -> YTDLPOutput {
            record.withLock { $0.arguments.append(arguments) }
            switch behaviour {
            case .answer(let output): return output
            case .waitsAndThrowsOwnError:
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    record.withLock { $0.wasCancelled = true }
                    throw Failure()
                }
                return YTDLPOutput(status: 1, stdout: Data(), stderr: Data())
            }
        }
    }

    @Test("A page is resolved from what the runner answered, to the arguments of the command line")
    func resolvesFromTheRunnersOutput() async throws {
        let runner = Runner.answering(Self.separateStreams)
        let resolved = try #require(try await YTDLPResolver(runner: runner).resolve(Self.page, headers: [:]))
        #expect(resolved.path == "https://media.example/video")
        #expect(resolved.audioFiles.map(\.url.absoluteString) == ["https://media.example/audio"])
        #expect(resolved.historyKey == "youtube:aqz-KE-bpKQ")
        let arguments = try #require(runner.record.withLock { $0.arguments }.first)
        #expect(arguments.contains("--dump-single-json"))
        #expect(arguments.last == Self.page.absoluteString)
    }

    @Test("Without a runner that can run nothing is resolved, and the loader does not ask the resolver")
    func unavailableResolvesNothing() async throws {
        let runner = Runner.answering(Self.separateStreams)
        let unavailable = Runner(.answer(YTDLPOutput(status: 0, stdout: Data(), stderr: Data())), isAvailable: false)
        let resolver = YTDLPResolver(runner: unavailable)
        #expect(resolver.order(for: Self.page) == nil)
        #expect(try await resolver.resolve(Self.page, headers: [:]) == nil)
        #expect(unavailable.record.withLock { $0.arguments }.isEmpty)
        #expect(YTDLPResolver(runner: runner).order(for: Self.page) == .beforeOpening)
        #expect(
            YTDLPResolver(runner: runner).order(for: URL(string: "https://jellyfin.example/Videos/1/stream")!)
                == .afterOpeningFails)
    }

    @Test("A failed run gives yt-dlp's reason from its stderr; a page it finds none in opens as it is")
    func failedRuns() async throws {
        let unavailable = Runner.failing("ERROR: [youtube] gone: Video unavailable\n")
        await #expect(throws: MediaResolutionError("Video unavailable")) {
            try await YTDLPResolver(runner: unavailable).resolve(Self.page, headers: [:])
        }
        let unsupported = Runner.failing("ERROR: Unsupported URL: https://a.example/x\n")
        #expect(try await YTDLPResolver(runner: unsupported).resolve(Self.page, headers: [:]) == nil)
    }

    @Test("A page asked again for a live stream goes through the runner too")
    func renewalsGoThroughTheRunner() async throws {
        let runner = Runner.answering(#"{"id": "live", "extractor_key": "Youtube", "is_live": false}"#)
        let resolver = YTDLPResolver(runner: runner)
        #expect(try await resolver.liveStreamIsOver(page: Self.page, headers: [:]))
        #expect(runner.record.withLock { $0.arguments }.count == 1)
    }

    @Test("A run that outlasts the timeout is cancelled and the load fails with the timeout, whatever the runner threw")
    func timeout() async throws {
        let runner = Runner(.waitsAndThrowsOwnError)
        let resolver = YTDLPResolver(runner: runner, timeout: .milliseconds(50))
        let error = await #expect(throws: MediaResolutionError.self) {
            try await resolver.resolve(Self.page, headers: [:])
        }
        // Not the runner's own error, and not about the page (the demuxer's reason stays shown).
        #expect(error?.message.hasPrefix("yt-dlp didn't answer") == true)
        #expect(error?.isAboutPage == false)
        #expect(runner.record.withLock { $0.wasCancelled })
    }

    @Test("A run that ends before the timeout gives its output: the cancelled sleep is no time being up")
    func runBeforeTimeout() async throws {
        let runner = Runner.answering(Self.separateStreams)
        let resolver = YTDLPResolver(runner: runner, timeout: .seconds(30))
        let started = ContinuousClock.now
        #expect(try await resolver.resolve(Self.page, headers: [:]) != nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("A cancelled load is a CancellationError, not the error the runner threw when it was cancelled")
    func outsideCancellation() async throws {
        let runner = Runner(.waitsAndThrowsOwnError)
        let resolver = YTDLPResolver(runner: runner)
        let resolving = Task { try await resolver.resolve(Self.page, headers: [:]) }
        try await Task.sleep(for: .milliseconds(100))
        resolving.cancel()
        await #expect(throws: CancellationError.self) { try await resolving.value }
        #expect(runner.record.withLock { $0.wasCancelled })
    }
}
