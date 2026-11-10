import CFFmpeg
import Foundation

/// Streams described as `AVStream`s, by index: what the decoders are made from (parameters, time base). See
/// `DemuxerInput`, which refines it.
protocol StreamDescriptions: AnyObject {
    var streamCount: Int { get }
    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>?
}

/// `AVStream`s of an input that demuxes by other means than an `AVFormatContext` of its own: a context only allocated,
/// never opened, holds them (FFmpeg makes a stream only in one). Not thread-safe: added to behind its owner's lock,
/// read once added.
final class AVStreamTable: StreamDescriptions, @unchecked Sendable {
    private var context: UnsafeMutablePointer<AVFormatContext>?

    init?() {
        guard let context = avformat_alloc_context() else { return nil }
        self.context = context
    }

    deinit {
        avformat_free_context(context)
    }

    /// A new stream, at index `streamCount - 1`; its parameters are empty.
    func addStream() -> UnsafeMutablePointer<AVStream>? {
        avformat_new_stream(context, nil)
    }

    var streamCount: Int {
        context?.streamCount ?? 0
    }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? {
        context?.stream(at: index)
    }
}

extension UnsafeMutablePointer where Pointee == AVFormatContext {
    var streamCount: Int { Int(pointee.nb_streams) }

    /// Stream `index`, nil out of range.
    func stream(at index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, index < Int(pointee.nb_streams) else { return nil }
        return pointee.streams[index]
    }
}
