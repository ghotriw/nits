import Foundation
import NitsCore
import NitsYTDLP

/// Runs the yt-dlp installed on the system (`YTDLPLocator`) as a process: macOS's `YTDLPRunner`. The locator is asked at
/// each call, so a yt-dlp installed while Nits runs is found without a restart.
struct ProcessYTDLPRunner: YTDLPRunner {
    var locator: YTDLPLocator

    var isAvailable: Bool { locator.executable() != nil }

    func run(arguments: [String]) async throws -> YTDLPOutput {
        guard let executable = locator.executable() else {
            throw MediaResolutionError("yt-dlp is gone", isAboutPage: false)
        }
        return try await YTDLPProcess.run(
            executable, arguments: arguments, path: locator.processPath(for: executable))
    }
}

extension YTDLPResolver {
    /// Plays the pages of video sites through the yt-dlp installed on the system.
    /// - Parameter customPath: The yt-dlp to run in place of the one found on the system (empty: search for it).
    public convenience init(
        customPath: String = "", sponsorBlock: Bool = true, liveHistory: Bool = false,
        streams: StreamProtocolPreference = .files
    ) {
        self.init(
            runner: ProcessYTDLPRunner(locator: YTDLPLocator(customPath: customPath)), sponsorBlock: sponsorBlock,
            liveHistory: liveHistory, streams: streams)
    }
}
