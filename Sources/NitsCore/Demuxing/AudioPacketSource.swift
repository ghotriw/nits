import CFFmpeg

/// What audio feeding reads the selected audio track from: the demuxer of the media, or of an audio file added to it.
/// `MediaDemuxer` is one.
protocol AudioPacketSource: AnyObject, Sendable {
    /// The next packet of the selected track; `nil` when none is there now (`isAudioEOF` tells the end).
    func nextAudioPacket() -> MediaDemuxer.DemuxedAudioPacket?
    /// The selected track's parameters with its time base, for its decoder; `nil` without one.
    func audioDecoderInput() -> (parameters: UnsafePointer<AVCodecParameters>, timebase: AVRational)?
    /// Drops the packets that end before `seconds` (playback timeline) as they are taken.
    func setTargetAudioPts(seconds: Double)
    /// Drops the packets queued that start before `seconds`.
    func purgeAudio(beforeSeconds seconds: Double)
    /// Every packet of the selected track has been taken, or none is selected.
    var isAudioEOF: Bool { get }
}

extension MediaDemuxer: AudioPacketSource {}
