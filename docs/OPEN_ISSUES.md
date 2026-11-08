# Open Issues

Problems that still need data or a real-world check. Fixed issues live on in the code, `docs/ARCHITECTURE.md`,
`AGENTS.md` and git history; remove an entry here once it is resolved.

## PRIORITY: changing the audio delay while playing external audio starts buffering, and it can stay on

**Observed by hand (2026-11-01)**: playing a video with an external audio track (an added audio file) and turning the
audio delay (`stepAudioDelay` / `setAudioDelay`) shows the preloader, and sometimes everything stops: pause / play or a
seek helps. Seeks with external audio are fine. **Not caused by the seek / `AudioJoin` rework of that day**: reproduced
the same on the last commit before it (`c1917d3`). With the audio inside the video file it does not happen.

**Reproduction** (a test, not committed; the file is in `.agents/scratch/ExternalAudioDelayRepro.swift.txt`, to be
copied to `Tests/NitsCoreTests/` as a `.swift`; `.agents` is untracked, so only on this machine): `wideGOPH264` as the video, `multiTrackH264` attached as external
audio and selected, `waitForPlayback`, then 10 steps of ±0.1 s of delay, 150 ms apart, and poll `isBuffering` for 8 s.
Four trials: buffering in 4 of 4, still on after 6 s with the clock advanced 0.1–0.2 s in 1 of 4 (on both the current
code and `c1917d3`); the same with the audio inside the video: none.

**What is known, not verified:** for audio on an input of its own `BufferingPolicy.isStarved` takes the renderer running
dry as enough (`isAudioDry`), where for shared audio the frame queue has to be low too; `applyAudioDelay` flushes the
renderer under the running clock (`DelayedAudioSink.changeDelay`) and puts the held audio back, so the renderer is empty
for a moment and the check holds the clock. Why buffering does not end: unknown. Suspects: a second step of the delay
flushing again while the first replay is on its way (`decoder.requeue(_, generation:)` drops a replay of an older
generation), so the audio from the held position is not there when `isReadyToResume` wants `audioResume` seconds ahead of
it; or the feeder run being restarted while the clock is held.

**Directions:** the renderer emptied by a delay change is not a shortage (hold the starvation check, or the separate-audio
rule, for the length of the replay); and find why the resume does not come, starting from the reproduction above with
`NITS`-level logging of `bufferedEnd` and the held clock.

## Root cause of the hardware VP9 decoder stall

**Observed once** (October 2026) playing a 1080p50 VP9 MP4 with hardware decoding (supplemental decoder), after
heavy UI activity and a `sample` of the process. The feeder was blocked in `VTDecompressionSessionDecodeFrame →
RemoteVideoDecoder_DecodeFrameWithOptions → FigSemaphoreWaitRelative` while the session's `VTDecoderXPCService`
sat idle (0 % CPU): waiting for something, not decoding. `vmmap` showed no IOSurface build-up in Nits.

The stall itself is now recovered from (see "Stalls and buffering" in `docs/ARCHITECTURE.md`); the cause is
unknown. Hypotheses: output-buffer pool exhaustion (surfaces held by the display layer / a busy WindowServer), the
process suspension by `sample` disturbing the XPC exchange, or a VideoToolbox bug in the VP9 supplemental decoder.

**If it recurs:** the `Video decoder stalled: …` log line records the display layer's status and
`requiresFlushToResumeDecoding`, the session's frames in flight, the frame queue fill, frame and clock positions
and the playing / seeking / stepping state. The decoder is replaced within 3 s, so run
`sample VTDecoderXPCService` as soon as video freezes.

## `fontd` not answering libass' font requests

**Observed three times** (October 2026, macOS 27) in full test runs, never in the app: every libass thread of the
test process waited in `match_fonts → CopyMatchingFontDescriptors → XTCopyPropertiesForFontsMatchingRequest →
xpc_connection_send_message_with_reply_sync`, `fontd` at 0 % CPU; once 12 threads at once, the whole cooperative
pool, so the run hung. Killing the test process (or `fontd`) cleared it. A probe of 12 threads in 4 processes asking
Core Text for 20 000 unknown families didn't reproduce it. Hypothesis, unchecked: requests that reach `fontd` just
as launchd starts it (in the first hang its PID followed the test process's).

Since then libass calls run one at a time on their own queue, the engine shows the text cues for the rest of the
media once one is stuck (see "libass" in `docs/ARCHITECTURE.md`), and tests reach libass through `LibassRenderer`,
which fails a test after 20 s instead of holding a thread of the run.

**If it recurs:** the `libass has been stuck in a call for …` log line; `sample` the process and check whether `fontd`
was started at about the same time (`ps -o lstart -p $(pgrep fontd)`).

## The line between a Bluetooth device's start and its switch from a placeholder

`AudioOutputInterruptionDetector` re-anchors the clock when a Bluetooth output stops its IO under the started clock after
running `minimumRunDuration` (30 ms): that is how a start that waits for the real A2DP stream (a restart within ~10 ms,
or 24 ms on the built-in speakers, which the Bluetooth-only gate leaves out) is told from the switch away from a
placeholder (AirPods last used by an iPhone). The line is **empirical and drawn from one pair of AirPods**: the switch
came ~100 ms after the run began on 2026-10-24 and 41–43 ms on 2026-11-01 (four starts in a row), so 50 ms missed it,
and what it will be on the next macOS or other earbuds is not known.

A better criterion would be a property of the device that changes only at the switch. The HAL properties watched on
2026-10-24 (`livn`, `goin`, `gone`, `stpd`, `nsrt`, `fsiz`, `ltnc`, `saft`, `stm#`, `slay`) gave `goin` alone, and the
BT plugin reports the A2DP latency on the placeholder already (7680 frames), so the device latency tells nothing. The
IO gap does not separate them either (healthy restarts returned after 200–480 ms, switches after 660–900 ms).
Captures: `.agents/bluetooth-audio-logs/`.

**If choppy Bluetooth audio returns:** find the stop in `player.log` (`Output device N started its IO` → `stopped its
IO`), compare its run length with the line, and look for `Audio output restarted its IO under the running clock`;
record the run length here before moving the line.

## Buffering needs a real-world check

`PlayerEngine+Buffering` (holding the clock while media runs out) is covered only by tests that stop the
feeders. To check in the app:
- a network stream on a throttled connection (e.g. Network Link Conditioner) and a file on a slow share: the
  `Buffering at …` / `Buffering ended after …` log lines should bracket each stall, and playback should resume
  where it stopped;
- a video decoder too slow for realtime (e.g. software 8K AV1), which starves audio through the demuxer's
  read-ahead limit: expected to alternate between buffering and playing rather than drift;
- possible side effect: an audio track that ends before the video, with under 20 frames queued (decoder
  barely keeping up), would alternate between buffering and playing.

The UI does not show `isBuffering` yet.

## A 200 ms frame hold on the display link

**Observed once** (October 2026, 25p Dolby Vision over HTTP from Emby, LG UltraFine at 60 Hz, audio on AirPods): one
frame stayed up 12 ticks (200 ms) and the next four frames never showed
(`held 12×1`, `skipped 4`), with no buffering, network or drop messages; it followed a `−8.6 ms` clock jump. A
negative jump of that kind is what a tick blocked between reading the synchronizer clock and `CACurrentMediaTime()`
produces, so the display-link thread may have been blocked. Not seen in 6 minutes of later runs. The AirPods also
step the clock early in playback (see "Display pacing" in `docs/ARCHITECTURE.md`), so the audio device may matter:
note it when this recurs.

**If it recurs:** the `Frame held …` line (see `docs/LOGGING.md`) tells a link that stopped calling, a tick blocked
on our side (`max tick`, `max clock read`) and an empty frame queue apart.

## Known limitations

Accepted for now, noted for later.

- **A launch flag over a setting shows the saved value in Settings.** With `--no-osd`, the OSD switch reads "on"; the
  flag holds until that setting is changed (`LaunchArguments.dropOverrides`), so turning it on takes off-then-on.
- **Subtitles dropped with a playlist file are not attached.** `MediaOpenRequest.open` attaches them only to the path
  it loaded; a `.m3u` hands on to its first item, so `engine.currentPath` differs and they are only logged.
- **An exact seek into audio past the video's end lands on the last frame.** With audio longer than video (video to
  50 s, audio to 60 s), a seek to 54 s lands on the last frame's 49.96 s: the position is the picture's, while audio
  starts at 54 s, so playback resumes with ~4 s of silence, and the next arrow press steps from 49.96 s again, never
  into the audio-only part. The position after such a seek should be its target.
- **The packet cache serves files, single-variant streams and ladders within one variant's stretch; not live streams.**
  Seeks back (and forward into what was read) skip the input (`seekWithinCache`). A ladder's seek that would cross a
  variant splice is a slow one (`format.variantGeneration` of the landing keyframe against the cursor's), so after an
  adaptive switch a seek back past it reads the input again; a journal of variant changes would serve those too.
  Measured on Apple's `bipbop_adv_example_hevc` (54 variants, one variant played, 2026-11-06): exact seek back 10 s
  1.1–1.5 s (RTT 25 ms) / 4.4 s (RTT 175 ms) before, 7–10 ms after; keyframe seek back 0.6 s / 3.2 s before, 2 ms after;
  no bytes. Adaptive playback in real time with a seek back every 10-30 s (probe `LadderABRSeekMeasurement`, 2026-11-07):
  Wi-Fi alone, no switch, 60 of 60 served from the cache; with NLC "DSL" (2 Mbit/s) the stream mostly stalled (the
  start was the top variant, ~10 Mbit/s, before the slow-link start of 2026-11-07; one run lost a segment, "failed too many times") and the few switches came
  when the cursor was past them: 7 of 8 and 3 of 3 served. One seek of 8, at the up-switch the line's release caused
  (target before the splice at 68 s, cursor after it), was slow (447 ms, 1.3 MB); its reason was not recorded (it did not
  repeat), the splice rule explains it. How often seeks cross a splice on a real stream is therefore unmeasured; a
  journal of variant changes waits for that. Not done: history behind the splice stays until the size limit evicts it (up to the 64 MB); the engine's
  ABR sees the read-ahead as the cache holds it (frontier minus the cursor, larger after a seek back: a false step up
  is possible; not measured); live. mpv caches both (it picks one HLS variant at open), and keeps several
  cached ranges where we keep one. Live needs to agree with `LiveStream.clamp` and `trackLiveWindow` (a seek back would
  no longer depend on the playlist's window).
- **A link between 3 Mbit/s and the best variant's bandwidth starts on the best variant.** Only a prefetch rate under
  3 Mbit/s starts lower (`provenSlowRate`): the rate follows the CDN's answers as much as the link (4.8 Mbit/s on a
  fast one), so a higher limit would start low on fast links. The first estimate comes after a whole segment of the
  best variant, so a 5–10 Mbit/s link against a 39 Mbit/s top stalls until it (0 to 4.8 s in the plain runs at 25 Mbit/s;
  not measured at 5–10). The ways out are a lower start by default (hls.js, VLC, ExoPlayer do), which shows low
  quality for ~30 s on a fast link (the switch splices after the read-ahead), or an estimate from a request under way
  with a rollback to the current frame (not built; `PlayerEngine.selectVariant` is how a seek to it works).
- **A variant at the edge of the link flaps.** With a latency share of 0.15 and an estimate of 22–23 Mbit/s, 18.9 Mbit/s
  fits neither the hold (0.95 less the share) nor leaves room, and the stream went 18.9 → 11.3 → 18.9 every 15–25 s in
  one of eight 25 Mbit/s runs. The probe's backoff only lengthens the climbs.
- **How long a read-ahead takes to end after its server goes away is not known.** A test stopped the server mid-file
  and waited for `readAheadEnded` for 10 s; it did not come (the test was dropped, as a read error cannot be made to
  happen the same way every time). FFmpeg's reconnects or the input's read timeout (`rw_timeout`) may be waiting; not
  checked. Until it is, the time the picture stands after a dropped connection, and when `readAheadEnded` (so the
  cache's refusal of a seek short of the duration) takes effect, are guesses.
- **A timeline break leaves the read-ahead's measure on the old timeline.** After a discontinuity (HLS
  `EXT-X-DISCONTINUITY`: ad insertions, splices) FFmpeg passes the timestamps back from zero. `readAheadState` is the
  furthest time read and does not go back, while `consumedSeconds` follows the packets taken: after 20 minutes of
  media `readAheadState` stays at ~1200 s and `consumedSeconds` starts again from 0, so the next ~20 minutes read as
  "full" and the thread reads only when the queue is empty, with no margin. Expected from the code, not seen on a real
  stream: `bufferedTime` in the UI would be wrong, and adaptive bitrate would see a huge buffer and could step up
  instead of down. It predates the packet cache. A plain reset does not do: `consumedSeconds` stays on the old
  timeline while it plays out. Check before ladders, on a stream with ad insertions; also how the engine (clock,
  position, frame queue) takes the break at all, which the demuxer-level tests do not cover.
  For HLS the timeline patch (next entry) removes the break, and with it this; it stays for what the patch does not
  reach (an MPEG-TS file with a reset in it, a playlist with the discontinuity left out).
- **A stream with breaks gets no cache after the end of its input.** The end is trusted only when what was read reaches
  the container's duration (`cachedFrontierSeconds`), measured on the last timeline; with a break it falls short of the
  playlist's total, so the seek reads again. Safe (a slow seek), and only after the end of the input.
- **HLS `EXT-X-DISCONTINUITY`: what `ffmpeg-hls-timeline.patch` leaves.** The patch moves the timestamps of the segments
  after a discontinuity onto the playlist's timeline ("Discontinuities in HLS" in `docs/ARCHITECTURE.md`). Before it, on
  the engine (2026-11-06, also on `424a8ac`): the second segment of `hlsDiscontinuity` dropped ~89 frames and the
  picture stood at 7.99 s for the last four of 12 s; PlayOn's test stream (`s3.amazonaws.com/playon-test-videos/
  discont_test_new/discont_test.m3u8`) dropped 697 frames and stood at 8.0 s for a minute; a seek past the first break
  landed at the start of the file. After: the picture follows the clock to the end in both, a seek lands in the right
  segment. Left:
  - Advertisements that are not on the first segment's streams are dropped (next entry).
  - A segment in another size is played now (the demuxer starts a new format description where the parameter sets in the
    band change, `MediaDemuxer.videoPacket(from:)`; before, the picture stood at the last frame of the first size while
    nothing came out of the decoder: on `hlsDiscontinuityResize` 4 s at 320x180 then 4 s at 640x360 it stood at 4.0 s).
    Not covered: only H.264 and HEVC with the sets in band (MPEG-TS and the like; AV1 and VP9 have their sequence
    headers in band too); the software decoder (FFmpeg follows an in-band change by itself; not run); a seek back
    across a change in the packet cache (the size the player has is the later one while the earlier pictures play; a
    slow seek reports the size at its landing, always: the first keyframe after it tells the size, so the player does
    not keep the size of another stretch, an advertisement the reading has left).
  - A keyframe seek (a held arrow key) that lands past its target across a change of size: the size comes with the
    picture it lands on (its second), and is applied when the clock gets to `chase.seconds + 0.1`; while scrubbing the
    clock stands, so the picture is of the new size and `media.video` is still the old one until the scrub ends.
  - A change of the picture's size, and of its parameter sets only, is followed by the decoder; the rest of an
    advertisement's properties is not, and the pictures play with the old ones:
    the frame rate (`nominalFrameDuration` and the display link's rate stay: a variant's change updates them,
    `variantDidChange`; a size change does not), the pixel aspect ratio (the event carries the stream's old one), the
    colour (the description is made from the codec parameters of the open), another codec after the change (the sets are
    parsed as the first codec's), and HEVC with Dolby Vision. A format description with other parameter sets for the same pictures is taken by
    VideoToolbox's session (`VTDecompressionSessionCanAcceptFormatDescription`): PlayOn's stream alternates its SPS
    (timing in the VUI), and made a session each time before (3 in 40 s, 1 now).
  - fMP4/CMAF with a new `EXT-X-MAP` at the break (2026-11-06): FFmpeg's mov sub-demuxer skips the later `moov`, so the
    stream kept the first section's `avcC` and the second stretch (640x360 after 320x180) stood at the last picture;
    `ffmpeg-hls-update-init-extradata.patch` passes the new section's extradata on a key frame, and the size follows
    (`HLSDiscontinuityFMP4Tests`, also after a seek back into the first stretch). Only H.264 and HEVC (the sets come from
    `NEW_EXTRADATA` in `refreshVideoFormat`); AV1 and VP9 keep the open's `av1C` / `vpcC`; audio extradata that changes
    with the section (another AAC configuration) is passed on by the patch but not taken by the audio path. Streams
    are matched by position, type and codec: a stretch with other streams is not followed. Not run on a real stream.
  - Not checked for fMP4 with a new `EXT-X-MAP` (read from the code, 2026-11-06): a ladder of variants. Going back to a
    variant in the same stretch leaves `cur_init_section` as it is, so no side data comes, and `spliceVariantVideo`
    builds the description from `codecpar` (the first init section's), so the picture may stand: to settle with ladders.
    A seek back into the first stretch that the packet cache serves reports no size (`seekReportingCache`), so
    `media.video` keeps the later stretch's; the engine tests start at 5 s so that the seek back is a slow one (the
    read-ahead is held until the first seek), and the cached case is not tested.
    The timeline thumbnails (`ThumbnailGenerator`, a context of its own, also on network sources) do not read
    `NEW_EXTRADATA`: past such a break they are probably missing or broken.
  - A separate audio rendition with its own playlist and breaks (2026-11-06, synthetic: video-only variant plus an
    `EXT-X-MEDIA` playlist, fMP4, init sections renewed in both): the first packets of the second stretch, sound and
    picture, keep the lead the first stretch has (the picture 67 ms after its sound) within 20 ms, and the sound starts at the 4 s the playlists put it at (30 ms), and the sound has no gap over
    100 ms (`audioRenditionMeetsThePicture`). The offsets are per playlist, so they meet because the `EXTINF`s of
    both playlists agree; a rendition whose durations differ from the picture's would drift by the difference.
  - Audio and frame rate across a break (2026-11-06): Google's `ima-vod-skippable-test` has no audio and 25 fps in the
    content and the advertisement, so it says nothing of either. On the 16 + 6 + 4 s synthetic (three timestamp
    domains, packets read with the patched `ffprobe`) the audio has no gap or overlap over 100 ms through both breaks and
    ends 50 ms after the pictures (27.52 against 27.47 s); the pictures step 67 ms (two frames) more than usual at each
    break (17.37 to 17.43 s, 23.40 to 23.47 s); the first audio and picture packets after a break are 30 and 67 ms
    apart (17.40 / 17.43, 23.40 / 23.47). `HLSDiscontinuityTests` keeps the audio timeline of the 4 + 8 s preset
    (no gap over 100 ms, ends past 11.5 s; it fails when the audio is left out of the patch's offset, checked by taking
    it out). Audio and picture of a playlist are moved by one offset, so their positions to each other stay (a separate
    audio rendition with its own playlist has an offset of its own: see the entry above). Not done:
    a change of frame rate at a break (a variant's change sets `nominalFrameDuration`
    and the display link's rate; a break does not, and the pictures are paced by their timestamps meanwhile).
    The 67 ms step was a bug of the timeline patch, found with the fMP4 audio rendition (2026-11-06): the offset was taken
    from the first packet's DTS while `first_timestamp` is its PTS, so every segment after a break sat a reordering delay
    (67 ms here; 125 ms at 24 fps with three B-frames) later than the playlist puts it, against audio that has no delay
    (an audio rendition has an offset of its own, so the picture trailed its sound by that much). Now both use the PTS:
    the step at a break is one frame (muxed fMP4, rendition and TS, `HLSDiscontinuityTests` / `...FMP4Tests`). The
    numbers above are from before. A/V sync through a break by the `flashClick` method is measured (`SyncPatternTests.acrossAnHLSBreak`, fMP4 with the sound in a rendition of its own, the picture keeping its 2 frames of reordering in both stretches; it fails with the offset taken from the DTS, checked by putting that back).
    The test also needs the second stretch's first whole second (7 s) seen in picture and sound at its absolute place, as the
    seconds repeat; it fails with the audio playlist's offset left out (checked by taking it out). FLAC, so that the
    clicks are exact: the trimming of AAC's priming samples after a break (about 21 ms) is not covered.
    On the final patch (PTS, thresholds, audio/video-only jump), real streams (2026-11-06): Google DAI
    (`ima-vod-skippable-test`) plays its 90 s with no frame dropped, PlayOn's with the 240 dropped frames of the
    segment without a tag (97.5 to 105.6 s), Mux's (rerun on this patch) as before, 2150 packets; a real fMP4 stream with a new `EXT-X-MAP` was not found.
    The 67 ms lead of picture over sound at the start is of these synthetic streams (tracks encoded apart, only the
    video shifted); the tests hold the second stretch to the first's lead: positions to each other, not absolute sync.
  - An early break is placed differently when reading and after a seek (read from the code, not run). The first packet
    after a seek takes its offset only if the playlist's place for the segment differs from its timestamp by half a
    target duration or more. A 4 s pre-roll before content in a playlist with `TARGETDURATION:10`, restarting at zero,
    is 4 s against 5 s: reading on takes the offset (a jump of 2 s or more needs 1 s of difference, the jump itself
    shows the restart), a seek into the content does not, and the same content lands 4 s apart (with segments of 10 s, a seek to 20 s lands
    on raw 10 s and shows the picture that reading on puts at 24 s). Reading is right now; the landing is not.
    The preset `hlsDiscontinuity` (4 s then 8 s, target 8) sits exactly on the boundary for `seekPastTheBreak` (4.000
    against 4.000, taken since the comparison is `>=`): a first segment one frame shorter would fail it.
  - The jump that finds a break is looked for in audio and video only (read from the code, no test): data streams such as timed ID3
    come seconds apart, and a jump of 2 s in one would put the offset of a mid-segment timestamp on the playlist when
    a server keeps its timestamps. Mux's Deltatre DAI was rerun after the 1 s change: the same 2150 packets, the same
    jump from 36.2 to 216.3 s.
  - A segment whose timestamps restart with no `EXT-X-DISCONTINUITY` before it is not seen: PlayOn's stream has one (the
    8 s segment before its last tag), which lands at -6.4 to 1.6 s and leaves a hole at 97.5 to 105.6 s in the timeline.
    The tag is what tells where to take the offset; guessing from a jump alone is what the patch avoids.
  - A live stream with breaks (`HLSLiveDiscontinuityTests`, synthetic, 2026-11-06), in two kinds: every 4 s segment
    restarting its timestamps at 0, and server-side ad insertion (`hlsLiveAds`: content on a running timeline from 1000 s,
    two advertisement segments from 0 after every three of content, so the content after the advertisement is already on
    the stream's time, as Mux's is). A window of 10 segments sliding, opened after it had slid. FFmpeg opens a live
    playlist at the third segment before its end (the timestamp probed there is the origin: negative where that segment
    restarts its timestamps, 1012 s on content), and the demuxer then rewinds to the first segment listed, so a plain read
    goes through the window as it was at the open and never waits for the playlist. The read from the edge, where the
    engine plays, is `edgeThroughAnAdvertisement`: content (number 10), the advertisement (13, 14), content again (15 on,
    already 8 s on): the steps stay under 0.2 s and the sound has no gaps. That does not tell whether the offset the
    advertisement took is dropped or the timeline patch's guard keeps the packets' own timestamps (either way the stream
    plays right), so it was looked at once in the patch's debug log (`av_log_set_level(AV_LOG_DEBUG)`, 2026-11-06):
    segment 13 `offset 1051933333`, segment 14 `offset 1055933333` (the advertisement), segment 15 `expected at
    1060000000, packet at 1060000000: offset 0`: dropped, by the comparison with the playlist. Not a check the tests
    make. The content is made up to segment 29, and a test's playlist must not reach past it. Picture
    and sound go on across the breaks (steps under 0.2 s, gaps under 0.15 s), keyframe seeks within the window land
    within a segment of the target, and the engine plays and seeks to the oldest place allowed (the clock goes on, the
    picture follows it, under 20 dropped). A single run of 30 s through about eight breaks (the 4 s segments restarting)
    dropped nothing; the engine test watches 5 s). `engineCrossesAnAdvertisement` takes the engine across both borders
    of the advertisement (seeks to 18 and 26 s on the window's timeline, 2 s short of the entry at 20 s and the return
    at 28 s): the clock and the picture go on past each, under 20 dropped. The lag check of the engine tests failed twice,
    in the first run after a build each time; the message of the second said 35 s at 0 s from the start, a first sample
    before the first picture (`currentFramePTS` is -1 until one is shown), which the check skips now. The first
    failure's message was not kept: it may have been the same. One thing was wrong and is fixed: the window of a stream opened after it
    had slid started before 0 (the segments listed before the one reading begins at are placed earlier than its first
    timestamp, which is small when timestamps restart), and a seek into that part stood the clock (`currentFramePTS >= 0`
    means "a picture is there" throughout the engine). `MediaDemuxer.timelineOrigin(of:)` now takes the start of an
    HLS stream for the origin, negative or not (other formats flagged `AVFMT_TS_DISCONT` keep a positive one or none), so it starts at 0 as it opens and everything after is positive.
    An EVENT playlist (no `hls_live` tag, so `isLive` is false and it has a duration) had the same fault, its first
    picture at -2.5 s; it starts at 0 now (`eventPlaylistStartsAtZero`). Not covered: a live ladder with breaks (single
    variant only; see Ladders), a stream whose timestamps jump on without a break, an advertisement on a timeline of its
    own at a splice shorter than the 1 s threshold, audio of a rendition with its own live playlist, a live stream of
    fMP4 (the origin applies to it too: `AVFMT_TS_DISCONT` is on HLS, read from the code), and a real stream (only
    synthetic ones). A break close to the reading point, as after a seek, is moved only when the jump is over half a target
    duration: with a target duration of 10 s a 4 s segment near the point is not (early break, above). Not looked at:
    subtitles (their playlists are not moved).
  - A restart of timestamps by less than 2 s is not seen (the error is that small).
  - Mux's Deltatre DAI (`test-streams.mux.dev/dai-discontinuity-deltatre/manifest.m3u8`) puts the later main content on
    timestamps already jumped by the length of the ads: the patch takes no offset there (the difference is under half a
    target duration), as it should.
  - A real ad server, Google DAI (`ima-vod-skippable-test`, `POST https://dai.google.com/ondemand/hls/content/2483977/vid/
    ima-vod-skippable-test/streams`; the address expires; six segments of content, a break, three of advertisement,
    timestamps back from 51.40 to 0.00 s), 640x360 throughout: before the patch the picture stood at 60.0 s with 750
    frames dropped for the last 30 of 90 s; with it the picture follows the clock to the end, nothing dropped (engine,
    2026-11-06; audio not looked at). The content ids are in `.ref/exoplayer/demos/main/src/main/assets/media.exolist.json`;
    the `tears-of-steel` example is out of date (its content segments answer 404).
- **Advertisement segments whose streams differ from the first segment's are dropped by FFmpeg's HLS demuxer.** Mux's
  Deltatre DAI stream (`test-streams.mux.dev/dai-discontinuity-deltatre/manifest.m3u8`): the ads (720x408, `METHOD=NONE`
  among AES-128 segments) are MPEG-TS with their own PMT; the subdemuxer reports `Packet corrupt (stream = 3 ...)` for them
  and no packet of an advertisement reaches the player (2150 video packets in all, the 180 s of ads missing; the same
  with `ffprobe`), so the picture stands at 36.2 s whatever the timeline. Not looked into: probably the streams the
  subdemuxer adds after the header, which `hls.c` does not map (`n_main_streams`). With a change of the picture's
  size as well (above), the next to take after the timeline.

## Revisit only if

- **The picture's stop on an audio track switch is noticed.** A switch is an exact seek to the current frame, so the
  picture stands while it lands (barely visible). A track from an added file has a demuxer of its own
  (`PlaybackInputs`): switching to or from it needs no seek of the picture, only the audio input positioned at the
  picture and an audio join. A track of the media itself needs the seek unless the demuxer kept every audio stream's
  packets (`applyStreamSelection` reads only the selected one).
- **A second engine in one process** (e.g. a preview player): make `PlayerPerformanceMonitor` per engine instead of
  `.shared`.
- **A second view reading `currentMetrics` live**: `PlayerEngine.isCollectingMetrics` is one `Bool` set from
  `ContentView` (its `didSet` starts and stops `metricsTimer`); the first reader to turn it off would stop it for the
  other, so it would need to count its readers.

## Flaky tests to watch

- **`BackwardFrameSteppingTests`** failed once locally with `engine.frameStep.cache.count → 0` after a paused
  exact seek. Suspected: the pause did not hold (the seek ran as a resuming seek, which does not seed the cache) or
  feeding restarted after it (`startFeeding()` clears the cache). The failure message reports cache size, play
  state and current frame to tell these apart.
- **`PlaybackStressTests` "Holding backward seek key produces monotonic non-increasing time values..."** failed once
  in three runs, then none in ten (2026-11-06), and once in ten on the same build without the HLS timeline patch:
  `Expectation failed: curr <= prev + 0.05` (`PlaybackStressTests.swift:395`), a time that stepped forward by more than
  50 ms in a backward series. Not looked into; a local file, so no HLS in it. Fell again in a full run of 343 s (2026-11-06,
  after the origin change, which does not touch a Matroska/MP4 file): at 25.0 → 25.050201 s, the sixth press of ~15
  (the series goes 45, 43, 40, 35, 30, 25, 20 … 0), 0.2 ms over the allowance; the time then rose in microsecond steps to
  25.066596 (the PTS of the picture that landed), and the next press took it to 20.0. So the clock reads a little ahead
  of the seek target in the middle of a series, between two presses (30–70 ms apart), not at its end. 3 of 3 alone it
  passes (1.6 s against 9.95 s in the run). Cause not shown.
- **`ExternalAudioTests` "A dub next to the media is a track of it…"** failed once in a full local run (2026-11-01):
  the dub's first audio fed at 1.04 s against `fed < 1`; it passes alone. The dub is joined to the picture's clock
  (`AudioJoin`), which cuts the audio to where the clock is plus the output latency, so under load the first buffer
  moves on with the clock. If it recurs, judge it against the clock at the selection, not a fixed second.
- **`FormatDescriptionCacheTests`** failed twice on CI with VideoToolbox returning 1–3 frames of 30 (always 30
  locally). The failure message now reports fed samples, session creation status, decode error statuses and the
  last callback status.
- **The HTTP, HLS and DASH suites together, with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`** (`--filter
  "HLSOverHTTPTests|AdaptiveBitrateTests|DASH|MediaDemuxer|InlineDASH|LiveStreamTests"`, a one-thread pool, 121 tests,
  about 165 s) fail on timing at the last commit (33d5fe9, 2026-11-07, with the bundled FFmpeg 1.5.0 build), without any of
  the live-history work: run 1, `AdaptiveBitrateTests.swift:117` (`consumer.stalled - stalledSlow < 0.5`) and
  `DASHLadderTests.swift:289` (`consumer.stalled < 1.5`); run 2, `DASHLadderTests.swift:289` alone. With the live-history
  suites and their two loops (`seeksRepeatedlyWhileReading`, `cancelsAReadAtAnyMoment`, which hold a thread for 3 s and
  8 s) the failures were more, in two runs (2 and 4): `SegmentIndexTests.swift:334`, `DASHLadderTests.swift:289`, three
  tests of `HLSOverHTTPTests` (`engine.waitUntil` timeouts) and `AdaptiveBitrateTests.swift:146`. With the loops skipped
  (`notInStrictPool`, so in this mode they are) it was 2 and 1 again: `AdaptiveBitrateTests.swift:117` with
  `HLSOverHTTPTests.swift:312` (`waitForPlayback`, an engine playing an HLS URL: the one that also failed in the first
  run with the loops), then `DASHLadderTests.swift:289` alone. Each passes alone (`HLSOverHTTPTests` 18 of 18, twice, in
  the strict mode), and the run without the strict mode passes (134 and 140 tests). So the strict mode is at the edge of
  the pool by itself, and a suite that blocks its thread for seconds tips more tests over it. Not looked into: the stall
  measures of the two ladder tests are the ones to judge first; `HLSOverHTTPTests.swift:312` showed up in 2 of 6 runs with
  the live-history suites and in none of 2 without, too few to tell if they have a part in it. Two runs more with the head
  of the stream added (`LiveSegmentGate`, `YouTubeLive` suites; 4 and 2 failures): `DASHLadderTests.swift:289`,
  `HLSOverHTTPTests.swift:312` and `AdaptiveBitrateTests.swift:146` (twice); then one of the new engine tests, which
  asserted that a stream was not yet ended right after its load, that took 45 s there (fixed: a load in a one-thread pool
  can outlast any wait a test sets).

## Live streams: a window of a few segments, and an outage that stands the picture

**A live stream's history is capped at 1080p60 SDR H.264, as HLS is (2026-11-07).** The segments of the streams called 4K
or HDR hold more: 2160p in VP9 (WebM), and on one of seven, AV1 with HDR10 in MP4. Not taken: a WebM has no `moof` for
`FragmentStartTime` (its clusters' timecodes would be read instead), and AV1 at 4K60 is software decoding (dav1d) on a Mac
without a hardware decoder. To judge first: which formats the Mac decodes in hardware (`VideoDecoderFactory`), so that the
selector (`YTDLPResolver.liveHistorySelector`) asks for the best of those; HDR10 AV1 MP4 is the case that costs nothing in
the parser. The load times are logged by part now (`YouTubeLiveHistory.Timings` in the yt-dlp log, "Opened … in" in the
engine's), for the 43 s load seen once (the likeliest the search for the edge of the history, which takes 41 s on a
server that answers 404, 500 and 503 for seconds each: the line says "by looking for the edge of the history" if so).

**Not checked on a real stream (2026-11-04)**:

- A window shorter than about 10 s (three segments of 2 s) cannot be seeked in without the picture falling out of it
  again: the start moves on while the seek prerolls and lands a keyframe before its target, and
  `PlayerEngine.trackLiveWindow` brings the picture back at most every 15 s (`LiveStream.windowRecoveryInterval`), so it
  jerks back every 15 s. Such windows are rare (YouTube's is 15 minutes to an hour); a window that short is a stream to
  watch at its edge.
- While a live stream's playlist fails to load (a server error for a minute), the demuxer stops reading, the picture
  stands, the clock goes on and the badge says LIVE: `trackLiveWindow` seeks to the place to read again, ever less often
  (5 s, 10 s, 20 s, then 30 s apart, for as long as it lasts), and the stream plays again when the server does, but there
  is no buffering shown meanwhile, nor an error after a while. The clock is not held: `holdForBuffering` ends at once
  for an input that has ended (`isReadyToResumeAfterBuffering`), and the tick that drives recovery does not fire with the
  clock held.
- A live stream's variants numbered from other bases, on a playlist that grows from the stream's beginning and has not
  slid: the first switch to the other numbering moves the start of the window by all the time since the stream opened
  (`first_timestamp_updated` is set when `first_timestamp` is, and only a slide moves it), up to an hour. Needs both a
  growing playlist and variants that do not share a base; not seen.
