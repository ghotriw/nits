import CoreMedia

/// Cuts the start off decoded audio, to the sample.
///
/// After a seek the picture runs ahead of the audio, which is flushed and refilled behind it; what was decoded for the
/// time that has passed meanwhile is not played. Whole buffers go (an AAC packet is 21 ms, an AC-3 one 32 ms), and the one
/// that straddles the cut is shortened, or the audio would run that much off the picture from one seek to the next.
enum AudioSampleTrim {
    enum Result {
        /// The buffer ends at or before the cut.
        case dropped
        /// The buffer starts at or after the cut, or could not be shortened (compressed audio): as it is.
        case whole(CMSampleBuffer)
        case trimmed(CMSampleBuffer)
    }

    /// `buffer` from `cut` on. Only constant-duration samples (decoded PCM) are shortened.
    static func trim(_ buffer: CMSampleBuffer, before cut: CMTime) -> Result {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        let duration = CMSampleBufferGetDuration(buffer)
        guard cut.isNumeric, start.isNumeric, duration.isNumeric, duration > .zero else { return .whole(buffer) }
        let end = start + duration
        if end <= cut { return .dropped }
        if start >= cut { return .whole(buffer) }

        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 1 else { return .whole(buffer) }
        // Samples of equal length: the buffer's duration divides evenly.
        let skipped = Int(((cut - start).seconds / duration.seconds * Double(count)).rounded(.up))
        guard skipped > 0 else { return .whole(buffer) }
        guard skipped < count else { return .dropped }
        var shortened: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleRange: CFRange(location: skipped, length: count - skipped), sampleBufferOut: &shortened)
        guard status == noErr, let shortened else { return .whole(buffer) }
        return .trimmed(shortened)
    }
}
