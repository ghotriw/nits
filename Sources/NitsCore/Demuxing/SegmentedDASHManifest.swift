import Foundation

/// A DASH manifest (MPD) for streams a site gives as numbered segments of one URL, as YouTube's recording of a live
/// stream that just ended (`http_dash_segments` formats with `…&sq=N` segments), which yt-dlp lists but no HTTP file
/// holds. FFmpeg's DASH demuxer plays it: the streams (a picture and its audio) come out of one demuxer, and it seeks
/// by segment. Each segment holds the stream's initialization data. Given to the demuxer inline
/// (`MediaURL.inlineDASHManifest`): a format of the resolver's, not for hosts to open.
package struct SegmentedDASHManifest: Sendable {
    package struct Stream: Equatable, Sendable {
        package enum Kind: Equatable, Sendable { case video, audio }

        package var kind: Kind
        /// yt-dlp's format id.
        package var id: String
        /// The container's MIME subtype ("mp4", "webm"), from the format's extension.
        package var container: String
        /// The codec string yt-dlp tells ("avc1.4D4028"), nil when it tells none.
        package var codecs: String?
        /// Bits per second, nil when unknown.
        package var bandwidth: Int?
        package var width: Int?
        package var height: Int?
        package var frameRate: Double?
        package var sampleRate: Int?
        /// The URL of the segments, without their number: `sq=` and the number are added.
        package var url: String

        package init(
            kind: Kind, id: String, container: String, codecs: String? = nil, bandwidth: Int? = nil,
            width: Int? = nil, height: Int? = nil, frameRate: Double? = nil, sampleRate: Int? = nil, url: String
        ) {
            self.kind = kind
            self.id = id
            self.container = container
            self.codecs = codecs
            self.bandwidth = bandwidth
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.sampleRate = sampleRate
            self.url = url
        }
    }

    package var streams: [Stream]
    /// How long a segment lasts.
    package var segmentDuration: Double
    /// How many segments the streams have.
    package var segmentCount: Int
    /// The number of the first segment (`startNumber`): 0 for a recording, more for a window of a long stream.
    package var firstNumber = 0
    /// Where the first segment starts in the stream, in seconds. The manifest's timeline is the stream's, so that the
    /// demuxer seeks by the times the segments' own timestamps have.
    package var startTime = 0.0

    /// A run of segments of one length, as a `SegmentTimeline` says them.
    package struct Run: Equatable, Sendable {
        /// Seconds.
        package var duration: Double
        package var count: Int

        package init(duration: Double, count: Int) {
            self.duration = duration
            self.count = count
        }
    }

    /// The lengths of the segments when they are not one: a stream's own, found from the times of a few of them
    /// (`window(through:lastNumber:lastDuration:)`). Else `segmentCount` segments of `segmentDuration`.
    package var runs: [Run]?

    package init(streams: [Stream], segmentDuration: Double, segmentCount: Int) {
        self.streams = streams
        self.segmentDuration = segmentDuration
        self.segmentCount = segmentCount
    }

    /// The window from the first of `anchors` (segments whose start times are known, by number) to `lastNumber`: the
    /// segments between two anchors share the length that takes one to the other, so the timeline is right at every
    /// anchor and off by the unevenness of the stretch between (a run of 4.933 s segments in 5 s ones) elsewhere;
    /// the last segment lasts `lastDuration`. A stream's segments are not of one length (seconds off after an hour
    /// by a number times a length), and what the demuxer seeks by is this timeline.
    package static func window(
        through anchors: [SegmentTimeSearch.Point], lastNumber: Int, lastDuration: Double
    ) -> (firstNumber: Int, startTime: Double, runs: [Run])? {
        let sorted = anchors.sorted { $0.number < $1.number }.filter { $0.number <= lastNumber }
        guard let first = sorted.first, lastDuration > 0 else { return nil }
        var runs: [Run] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.number > a.number {
            let count = b.number - a.number
            runs.append(Run(duration: max(0.001, (b.time - a.time) / Double(count)), count: count))
        }
        let last = sorted[sorted.count - 1]
        runs.append(Run(duration: lastDuration, count: lastNumber - last.number + 1))
        return (first.number, first.time, runs)
    }

    /// The manifest's text.
    package func text() -> String {
        let lengths: [(seconds: Double, milliseconds: Int, count: Int)] =
            runs?.filter { $0.count > 0 }.map { ($0.duration, max(1, Int(($0.duration * 1000).rounded())), $0.count) }
            ?? [(segmentDuration, max(1, Int((segmentDuration * 1000).rounded())), segmentCount)]
        let total = Double(lengths.reduce(0) { $0 + $1.milliseconds * $1.count }) / 1000
        // Every run says where it starts, from the exact lengths before it, not from the rounded ones the demuxer adds up:
        // a length in whole milliseconds is up to half of one off, which over a run of an hour is a third of a second,
        // and over a day of runs would pile up to seconds.
        var start = startTime
        let timeline = lengths.map { run in
            let t = Int((start * 1000).rounded())
            start += run.seconds * Double(run.count)
            return #"<S t="\#(t)" d="\#(run.milliseconds)" r="\#(run.count - 1)"/>"#
        }.joined()
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" minBufferTime="PT2S" "#
                + #"profiles="urn:mpeg:dash:profile:isoff-live:2011" mediaPresentationDuration="PT\#(total)S">"#,
            "<Period>",
        ]
        for stream in streams {
            let kind = stream.kind == .video ? "video" : "audio"
            var attributes = [#"id="\#(Self.escaped(stream.id))""#]
            if let codecs = stream.codecs { attributes.append(#"codecs="\#(Self.escaped(codecs))""#) }
            if let width = stream.width, let height = stream.height {
                attributes.append(#"width="\#(width)" height="\#(height)""#)
            }
            if let frameRate = stream.frameRate, frameRate > 0 { attributes.append(#"frameRate="\#(frameRate)""#) }
            if let sampleRate = stream.sampleRate { attributes.append(#"audioSamplingRate="\#(sampleRate)""#) }
            attributes.append(#"bandwidth="\#(stream.bandwidth ?? 0)""#)
            let media = Self.escaped(LiveHistory.segmentAddress(stream.url, number: "$Number$"))
            // The timeline, not just a duration, ends the stream at its last segment: FFmpeg counts one segment more
            // from the duration alone, and asks the server for a segment that is not there.
            lines += [
                #"<AdaptationSet mimeType="\#(kind)/\#(Self.escaped(stream.container))" segmentAlignment="true">"#,
                "<Representation \(attributes.joined(separator: " "))>",
                #"<SegmentTemplate timescale="1000" startNumber="\#(firstNumber)" media="\#(media)">"#,
                "<SegmentTimeline>\(timeline)</SegmentTimeline>",
                "</SegmentTemplate>",
                "</Representation>",
                "</AdaptationSet>",
            ]
        }
        lines += ["</Period>", "</MPD>"]
        return lines.joined(separator: "\n")
    }

    /// `text` as XML character data in an attribute.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
