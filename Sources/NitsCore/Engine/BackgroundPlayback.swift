/// What the engine owes the app being in the background: with audio the sound plays on, and the picture is not wanted
/// (no video feeder, no decoder session, no frames, no display link), so the media is played as audio only until the
/// host comes back. See "Background playback" in `docs/ARCHITECTURE.md`.
struct BackgroundPlayback {
    /// The picture is dropped: the demuxer keeps video packets out of its queue (`MediaDemuxer.setVideoDropped`) and
    /// `PlayerEngine.hasPicture` is false. Cleared by every load (`resetMediaState`) and when the host comes back.
    var isVideoDropped = false
}
