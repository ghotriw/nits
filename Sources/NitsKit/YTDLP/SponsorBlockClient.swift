import CryptoKit
import Foundation
import NitsCore

/// A span of a YouTube video SponsorBlock's community marked: a sponsor, an intro, … or a chapter.
struct SponsorBlockSegment: Sendable, Equatable {
    var category: String
    var start: Double
    var end: Double
    /// A chapter's title; `nil` for the other categories.
    var description: String?
    /// The length of the video the segment was marked on; `nil` when SponsorBlock doesn't know it.
    var videoDuration: Double?

    /// The segments marked on this version of a video `duration` long, their ends snapped to its start and end, as
    /// yt-dlp's SponsorBlock postprocessor does: a video re-uploaded with a cut moves the spans of the old one.
    static func matching(_ segments: [SponsorBlockSegment], duration: Double?) -> [SponsorBlockSegment] {
        segments.compactMap { segment in
            var segment = segment
            // An empty span (`[0, 0]`) or a reversed one has nothing to skip.
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start else { return nil }
            // A span marked from the start or to the end misses it by milliseconds.
            if segment.start <= 1 { segment.start = 0 }
            guard let duration, duration > 0 else { return segment }
            if duration - segment.end <= 1 { segment.end = duration }
            guard let marked = segment.videoDuration, marked > 0 else { return segment }
            let difference = abs(duration - marked)
            let matches = difference < 1 || (difference < 5 && difference / (segment.end - segment.start) < 0.05)
            return matches ? segment : nil
        }
    }

    /// The community's chapters among `segments`.
    static func chapters(in segments: [SponsorBlockSegment]) -> [MediaChapter.Raw] {
        segments.filter { $0.category == "chapter" }.map {
            MediaChapter.Raw(title: $0.description, start: $0.start, end: $0.end)
        }
    }

    /// Buttons that skip `segments`, seeking to their ends; chapters are markers, not buttons.
    static func actionButtons(from segments: [SponsorBlockSegment]) -> [PlaybackActionButton] {
        segments.enumerated().compactMap { index, segment in
            guard segment.category != "chapter" else { return nil }
            let title: String
            let allowsAutoPress: Bool
            switch segment.category {
            case "sponsor":
                title = "Skip Sponsor"
                allowsAutoPress = true
            case "intro":
                title = "Skip Intro"
                allowsAutoPress = true
            case "outro":
                title = "Skip Outro"
                allowsAutoPress = true
            case "selfpromo":
                title = "Skip Promotion"
                allowsAutoPress = true
            case "interaction":
                title = "Skip Interaction"
                allowsAutoPress = true
            case "preview":
                title = "Skip Preview"
                allowsAutoPress = false
            case "hook":
                title = "Skip Hook"
                allowsAutoPress = false
            case "filler":
                title = "Skip Filler"
                allowsAutoPress = false
            case "music_offtopic":
                title = "Skip Music"
                allowsAutoPress = false
            default:
                title = "Skip"
                allowsAutoPress = false
            }
            return PlaybackActionButton(
                id: "sponsorblock-\(index)", title: title, start: segment.start, end: segment.end,
                allowsAutoPress: allowsAutoPress, seeksToEnd: true)
        }
    }
}

/// Fetches a YouTube video's SponsorBlock segments from `sponsor.ajay.app`, in parallel with yt-dlp. It asks by the
/// first 4 hex digits of the id's SHA-256 (k-anonymity), so the server learns a bucket of videos, not the video.
/// Failing, it gives none: SponsorBlock never fails a load, and holds it up `timeout` at most.
struct SponsorBlockClient: Sendable {
    /// Skippable categories, and the community's chapters for videos whose author gave none.
    static let categories = [
        "sponsor", "intro", "outro", "selfpromo", "interaction", "preview", "hook", "filler", "music_offtopic",
        "chapter",
    ]
    /// Without it the API answers `skip` segments only, not chapters (action type `chapter`). Not `mute`: a span to
    /// play silenced, its picture worth watching, which a skip button would cut.
    static let actionTypes = ["skip", "chapter"]
    /// How long the whole request may take. It runs while yt-dlp does, which takes longer, so the load rarely waits for
    /// it; it does when yt-dlp is quick, or when the URL doesn't name the video and it is asked after yt-dlp.
    static let timeout: TimeInterval = 3

    /// Ephemeral (no cookies or cache to tell one asker from another); the resource timeout bounds the whole request,
    /// which a request's `timeoutInterval` doesn't (it bounds the idle time between packets).
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    init(session: URLSession = defaultSession) {
        self.session = session
    }

    static func requestURL(for videoID: String) -> URL? {
        let hash = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")
        components?.queryItems = [
            URLQueryItem(name: "categories", value: jsonArray(categories)),
            URLQueryItem(name: "actionTypes", value: jsonArray(actionTypes)),
        ]
        return components?.url
    }

    /// The segments of `videoID` in the answer for its hash prefix, which lists every video of the bucket.
    static func segments(in data: Data, videoID: String) throws -> [SponsorBlockSegment] {
        let videos = try JSONDecoder().decode([Video].self, from: data)
        guard let video = videos.first(where: { $0.videoID == videoID }) else { return [] }
        return video.segments.compactMap { segment in
            guard segment.segment.count >= 2 else { return nil }
            return SponsorBlockSegment(
                category: segment.category, start: segment.segment[0], end: segment.segment[1],
                description: segment.description?.isEmpty == false ? segment.description : nil,
                videoDuration: segment.videoDuration)
        }
    }

    func segments(for videoID: String) async -> [SponsorBlockSegment] {
        guard let url = Self.requestURL(for: videoID) else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            // 404: no segments in the bucket.
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return try Self.segments(in: data, videoID: videoID)
        } catch {
            AppLog.info(.ytdlp, "No SponsorBlock segments for \(videoID): \(error.localizedDescription)")
            return []
        }
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private struct Video: Decodable {
        var videoID: String
        var segments: [Segment]
    }

    private struct Segment: Decodable {
        var category: String
        var segment: [Double]
        var description: String?
        var videoDuration: Double?
    }
}
