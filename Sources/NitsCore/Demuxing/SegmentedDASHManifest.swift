import Foundation

/// A DASH manifest (MPD) for streams a site gives as numbered segments of one URL, as YouTube's recording of a live
/// stream that just ended (`http_dash_segments` formats with `…&sq=N` segments), which yt-dlp lists but no HTTP file
/// holds. FFmpeg's DASH demuxer plays it: the streams (a picture and its audio) come out of one demuxer, and it seeks
/// by segment. Each segment holds the stream's initialization data. Given to the demuxer inline
/// (`MediaURL.inlineDASHManifest`): a format of the resolver's, not for hosts to open.
package struct SegmentedDASHManifest {
    package struct Stream: Equatable {
        package enum Kind: Equatable { case video, audio }

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
    /// How many segments the streams have, numbered from 0.
    package var segmentCount: Int

    package init(streams: [Stream], segmentDuration: Double, segmentCount: Int) {
        self.streams = streams
        self.segmentDuration = segmentDuration
        self.segmentCount = segmentCount
    }

    /// The manifest's text.
    package func text() -> String {
        let milliseconds = max(1, Int((segmentDuration * 1000).rounded()))
        let total = Double(segmentCount * milliseconds) / 1000
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
            let separator = stream.url.contains("?") ? "&" : "?"
            let media = Self.escaped(stream.url + separator + "sq=$Number$")
            // The timeline, not just a duration, ends the stream at its last segment: FFmpeg counts one segment more
            // from the duration alone, and asks the server for a segment that is not there.
            lines += [
                #"<AdaptationSet mimeType="\#(kind)/\#(Self.escaped(stream.container))" segmentAlignment="true">"#,
                "<Representation \(attributes.joined(separator: " "))>",
                #"<SegmentTemplate timescale="1000" startNumber="0" media="\#(media)">"#,
                #"<SegmentTimeline><S t="0" d="\#(milliseconds)" r="\#(segmentCount - 1)"/></SegmentTimeline>"#,
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
