# HLS client and adaptive bitrate

Nits reads HLS with a client of its own (`Sources/NitsCore/Demuxing/HLS/`): playlists, segments, discontinuities,
live windows and renditions are its, and FFmpeg only demuxes each segment (its HLS demuxer is not built). Adaptive
bitrate (`AdaptiveBitrateLogic`) chooses the variant of an HLS ladder and of a DASH manifest alike.

This document is the one place for both: how they work and why, the decisions taken and the ones turned down, how they
are measured, and where they stand. What any input shares (`DemuxerInput`, the network read-ahead, the packet cache,
the engine's `LiveStream`) is in `docs/ARCHITECTURE.md`; the rules agents follow are in `AGENTS.md`.

- [The client](#the-client): opening, requests, renditions.
- [Timeline and discontinuities](#timeline-and-discontinuities)
- [Live playlists](#live-playlists)
- [Variant switches](#variant-switches)
- [Adaptive bitrate](#adaptive-bitrate)
- [Decisions](#decisions): what was chosen, what was turned down, and why.
- [Measuring](#measuring): the stands, the network profiles, the results.
- [State and known limitations](#state-and-known-limitations)

## The client

- **HLS opening.** `HLSInput` loads the master and every media playlist it needs at once (one request each, on
  `HTTPSessionTransport`), and probes lanes to describe their streams: the start of a lane's first segment, streamed
  (`HLSSegmentBody`) through an `AVIOContext` of ours into FFmpeg's analysis, which reads what it needs of it
  (`HLSLane.probe`). The probe's requests are the opening's (`HTTPSessionTransport.open(opening:)`: no adaptive-bitrate
  sample, but a measure of the link). A probe's segment is kept by its lane once the streams are described
  (`HLSLane.startBody`): the run that starts there replays it and goes on with the same download, and a lane that is not
  read drops it and downloads nothing more. The rung probed to start on is asked for whole and not held
  (`HTTPSessionInput.Opening.start`): its download is the start of playback, and what it brings after the opening a
  sample as any segment's; the others are held to a 256 KB buffer, asked for in pieces of it (`.held`), as they are
  read only as far as FFmpeg's analysis goes. FFmpeg's own HLS demuxer probed every variant one request after
  another, and Apple's AV1 example (36 playlists, 23 probes) opened in 54.5 s on a cold CDN cache and 12 s on a warm one.
  Here only the variants that switch with the best one (`HLSInput.ladder(of:)`: its video codec, `SUPPLEMENTAL-CODECS`,
  `VIDEO-RANGE`, rendition groups) and the renditions they refer to are loaded at all, and of such a ladder only the
  top rung is probed, with the audio renditions beside it (hls.js and ExoPlayer read the start variant alone):
  - *Clones.* The other rungs are described as the top (`HLSInput.cloneCandidates`): its table streams copied, the
    picture of the size the rung's `RESOLUTION` tells (0, unknown, without one). A rung whose `CODECS` tell other sound
    muxed into it is probed itself. A clone's variant is `pending` (`DemuxerInput.variantDescription(id:)`) until its
    first run: that run's streams replace the description in the table, the table's time base kept
    (`HLSInput.redescribe`, `HLSLane.describeFirstRun`), or, of other kinds or numbers, make it `rejected` and the lane
    reads nothing (`HLSLane.rejected`). Its runs are analysed as briefly as the top's (`HLSLane.analyzesAs`).
  - *The demuxer* starts only on a described variant (`adoptVariants`), and checks a switch to a pending one once its
    first read described it (`verifyVariantSwitchTarget`, in `readPacket`): rejected, or not `canSwitch` with the
    variant played, the switch is given up and the variant never chosen again (`VariantSelection.rejected`, out of
    adaptive bitrate and `selectVariant`). A seek during a switch to a variant still pending has the input probe it at
    the target (`describeVariant(id:at:)`), under `lock`, before it splices: its decoders are made from the table.
  - *A slow answer.* A top that has not answered in `HLSInput.answerLimit` (4 s; the request's own timeout is 10 s of
    silence) has the next rung down probed beside it (`ProbeRace`); the first to answer describes the ladder, the other's
    requests are stopped (`HLSSegmentLoader.aborting(when:)`) and it becomes a clone. A probe that fails on its own is
    left out, and the next rung down is probed. Apple's Dolby Vision top init went unanswered for 10 s at RTT +150 ms.
  - *A slow link* (`openingLinkRate`): the rung it starts on is probed too, before the demuxer chooses (the same rule,
    `HLSInput.startRung`), and the next one down when that probe fails; the download of the rung probed to start on
    stops.
  - *The link's rate* (`HTTPSessionTransport.waitForOpeningRate`, `OpeningLimit.linkRate`) is what the opening's
    transfers bring past their slow start (`skipSlowStart`): max(128 KB, what a link at `slowLinkLimit` carries in two
    round trips), the round trip TCP's handshake took on a new connection to the segments' host (QUIC's for HTTP/3;
    `HTTPSessionInput.roundTrip(of:)`, from the playlists' requests). A single probe on a fresh connection brought its
    first 256 KB at 2.6–5.2 Mbit/s on a fat link at 180 ms of round trip: TCP's window, not the link. Told over 256 KB
    past the skip, or once a link at the limit would have brought them and the skip (a link proven slower); the start's
    download goes on past its probe, and the opening waits for it (about a second at most at the limit); transfers that
    end first give the rate of what came (`rateOfWhatCame`, over half a second of transfer at least).
  A ladder `ladder(of:)` keeps whole (a rung that tells no codecs) has every rung probed side by side. A media playlist
  given alone is opened whole, as one lane. The first segment of the run a lane reads is kept (`HLSLane.startBody`), so
  the demuxer's rewind to the start after its opening scan replays what was read and goes on with the same download.
  `HLSInput.read` hands out the packet of the lane read that decodes first, so every lane holds its next packet (at a
  time two variants share, the one a switch catches up first: its keyframe splices before the old variant's picture of
  that time is handed out); a subtitle rendition's lane loads no segment that starts after the picture's and sound's
  next packet (`HLSLane.fill(before:)`): its cues are sparse, and a stretch without them would otherwise load a segment after
  another to find the next cue before any packet came out, or wait at a live edge while the picture's packets were ready.
  A playlist URL (`.m3u8`, `.m3u`) opens this way, over HTTP(S) or as a saved manifest (a file whose text is an HLS
  manifest); an address with no extension is asked for its first bytes (`HLSInput.sniffsAsPlaylist`, one small range
  request) and opens this way when they say `#EXTM3U`. A playlist served over HTTP(S) never reads a local file, whatever
  it lists (`HLSSegmentLoader.allowsFiles`).
- **Renditions** (`EXT-X-MEDIA` audio and subtitles) are playlists of their own, downloaded while one of their
  streams isn't discarded. Only the video, audio track and subtitle track selected are read (`applyStreamSelection`):
  on opening, at a variant switch (the new variant's video and the rendition of the selected audio track, not all its
  streams), and after a track selection, which the main thread only flags (`streamSelectionChanged`) for the reading
  thread to apply under `lock` at its next read or seek, as FFmpeg reads the discard flags inside `av_read_frame`. An
  audio track switch seeks anyway; a subtitle rendition selected on a network source seeks to the current frame too,
  or FFmpeg would start it at the read position.

## Timeline and discontinuities

A stream with ad insertions or splices may restart its timestamps (from zero, or another base) or jump at a
discontinuity. The client reads the tag: a **run** of segments (`HLSSegmentReader`) is one byte stream into one
FFmpeg container demuxer (`mpegts`, `mov`, …), and a run ends at a discontinuity, an init-section change or a gap, where
the lane starts the next with a demuxer of its own. The packets are moved onto the playlist's timeline by one offset
per discontinuity sequence, which all the lanes share (`HLSTimestampAnchors`, as hls.js's `initPTS[cc]` and ExoPlayer's
`TimestampAdjusterProvider`): the picture's first run in a sequence anchors it, where the playlist's durations put its
first segment minus the timestamp of its first picture (else its first stream's, else its first packet); every later
run of that sequence, of any lane and from any segment (a seek, a variant switched to, an audio rendition), takes it.
The variants' lanes are read first, and a rendition's run of a sequence not anchored yet waits until the picture is a
target duration past its start (`HLSLane.waitsForAnchor`), so the picture anchors whichever lane reaches a break first;
past the wait (numbers that don't match across playlists) a sound run anchors it. The sequence numbers are the server's
when it says them (`EXT-X-DISCONTINUITY-SEQUENCE`, which RFC 8216 makes the same across a stream's playlists), also
after a late reload that missed segments (`HLSTimeline.startRun`), so every lane keys the same sequence alike.
Packed audio (raw AAC, AC-3, MP3 segments) has timestamps from the run's first sample: its time on the media's clock is
the first segment's ID3 `PRIV` timestamp (`HLSPackedAudioTag`); without one it is placed by its playlist alone and
neither takes nor sets the shared offsets. The media's timestamps then place every run against the
others, whatever the `EXTINF`s summed to on the way (integer durations drift by a third of a second in five minutes),
and the playlist only says which segment to load: an audio rendition keeps its place against the picture, a variant
joins the old one where their timestamps meet, and a start where the sound leads the picture (an encoder's priming)
keeps the lead. A run that the offset puts more than a target duration from where the playlist does (variants with
timestamps of other bases, sequence numbers that don't match across playlists) is anchored anew and anchors the sequence
from then on. MPEG-TS's 33-bit timestamps are unwrapped (`TimestampUnwrapper`), from where the playlist puts the run,
so a run after the wrap takes an offset anchored before it. A WebVTT rendition has no timestamps of its own: its cues
are placed by `X-TIMESTAMP-MAP` and the offset of their segment's sequence, else the one the picture is read with (a
subtitle playlist without the picture's breaks). A subtitle run never anchors (cues are sparse: the first may be far into
its segment). The demuxer's timeline is therefore the playlist's: the engine, the read-ahead's measure
(`readAheadState` against `consumedSeconds`) and the packet cache see one, and the cache's `searchFloor` (a timestamp
going back) is a safety for what the client does not cover (a file of segments cut and joined, an MPEG-TS with a
reset). Segments of a live playlist that expired while the read was behind are skipped by the model
(`HLSTimeline.next(after:)` answers `.expired(resumingAt:)`), and what follows is placed where the playlist puts it
(`expiredSegmentsKeepTheTimeline`). The places of the segments are the playlist's durations summed, corrected from the
media as hls.js does from a fragment's PTS (`updateFragPTSDTS`): the reader reports where the first picture of each
segment of a run is (the first packet of its reference stream whose `pos` lies in the segment's bytes,
`HLSSegmentReader.noteSegmentStart`), `HLSTimeline.measure` takes it, and the entries between two measured places have
their durations scaled to fit, the others follow as listed (an integer `EXTINF` of a 6.006 s segment no longer drifts the
places). A seek chooses its segment by these places. The first segment of a run is measured as the run opens, from the
streams' start times before any packet is read, and when it turns out not to hold the target the lane restarts the run at
the segment that does (`HLSLane.segmentStarted`, `startRun`): nothing has been handed out by then, so a restart can't
roll the sound back. The segments after the first are measured by `pos` as they are read and only refine the places.
Entries are told apart across a restart by `HLSTimeline.Entry.epoch`, not by their place, which a measure moves. The
rendition aligned to the stream's start (`streamStart`) keeps the old zero when a measure moves the first entry. A
server that keeps its timestamps is not touched by any of it. The tests need no particular FFmpeg build.

The picture's size can change at a break too (an advertisement in another encoding): the parameter sets in the stream
change, and the demuxer starts a new format description where a keyframe carries others (`videoPacket(from:)`, for
H.264 and HEVC with the sets in band); the packets after it carry it, VideoToolbox follows with a session per
description, and `onVideoSizeChanged` tells the player the size, which it applies when playback gets there like a
variant's change (`videoSizeWillPlay`). The first keyframe after a slow seek tells its size whether or not the sets
changed, as the player may show the size of another stretch (content, an advertisement, content again) that the
reading, ahead, has left.

In fragmented MP4 the parameter sets are not in band but in the init section, and a playlist may renew `EXT-X-MAP` at the
break. A run has its own demuxer, so it reads its own init section: a later run with other extradata hands the first
keyframe of its video `AV_PKT_DATA_NEW_EXTRADATA`, which `refreshVideoFormat` takes like it takes in-band sets, and
everything after is the same path. An audio rendition with a playlist of its own has its breaks, and takes the offset
of each stretch that the picture anchored, so picture and sound meet where their timestamps put them, whatever the
`EXTINF`s of either playlist (`HLSDiscontinuityFMP4Tests` checks the first packets of the second stretch to keep the
first's lead of sound over picture within 20 ms on the synthetic stream, and no gap in either;
`audioRenditionSharesThePicturesOffset`, a rendition whose durations are listed 0.31 s too long).
An advertisement that is MPEG-TS with a PMT of its own (Mux's Deltatre DAI), whose packets FFmpeg's HLS demuxer dropped
as corrupt, plays: every run has a demuxer of its own. What breaks still leave is under "State and known limitations".

## Live playlists

What the engine makes of a live window (`LiveStream`: the edge, seeks into the window, recovery, the UI) is any live
stream's; see "Live streams" in `docs/ARCHITECTURE.md`. The playlist side is the client's:

- **The window comes from the client.** `HLSInput` keeps the playlist as a model (`HLSTimeline`: segments on the
  playlist's timeline, reloads merged by media sequence) and tells its window from it (`liveWindow`, after each
  `read`: the playlist is reloaded inside it): the first segment listed to the end of the last, with `hasSlid` (the
  playlist had slid when it was read: the start moves from the first load on) and `hasEnded` (`EXT-X-ENDLIST`: the last
  window stays, a recording). Timeline 0 is the first segment listed at the first load, so `timelineOrigin` is 0.
  `MediaDemuxer.publishLiveWindow` reads it on the reading thread into `liveWindowState`, a lock of its own like
  `readAheadState`, with the time it first saw the window (`LiveReport.loadedAt`: the load's, which the engine, reading
  it much later after a pause, moves the window on from). Only the variant playing's playlist sets it (an audio rendition
  has a window and an end of its own). The join is `edgeMargin` (3) target durations behind the edge (RFC 8216 6.3.3); a
  rewind goes back to that join point; a lane read behind the window reloads before its next segment (`reloadIfStale`),
  so segments that expired meanwhile are skipped rather than failed; a playlist unchanged for 3.5 target durations
  (ExoPlayer's coefficient) ends the lane with `-ETIMEDOUT`, and three failed reloads in a row stop it.
- **The read at the edge waits.** The client's lane, at the edge of a playlist that lists no new segment, reloads it
  every target duration (half after a reload that changed nothing) inside `read`, holding `lock`; a seek would wait for
  it (for a stalled stream forever). `seek` of a live stream takes the lock as `lockIO(yielding: true)`, which asks the
  interrupt context to `yieldIO()` while it waits: the lane's wait and `HTTPSessionTransport`'s requests poll the same
  (`shouldInterruptFFmpeg`) and answer `AVERROR_EXIT`, which the read-ahead thread does not take for an end of the input
  (it steps aside), and the seek repositions what it left. Only a seek yields: the read-ahead goes on from an
  interrupted read in a state only a seek puts right.

## Variant switches

- **HLS variants.** A switch splices at the read position, up to the read-ahead limit ahead of playback, so a
  manual switch seeks to the current frame instead (as an audio track switch does). The engine shows a splice when
  playback reaches it (`variantWillPlay`); the changes reach the main thread in order (`DispatchQueue.main`, not a
  task each). The splice rewrites the stream description (`timebase`, `formatDescription`, the audio track's streams,
  …) on the reading thread, under `queueLock`: the engine reads it before starting the read-ahead at the end of a
  load, and through `readingDescription` after that. An audio track selected during a switch is spliced to in place of
  the one selected when it began.

How a switch splices for DASH, whose demuxer orders the representations otherwise, is in "Network read-ahead" in `docs/ARCHITECTURE.md` (DASH variants).

## Adaptive bitrate

**Adaptive bitrate** (`AdaptiveBitrateLogic`, `MediaDemuxer+AdaptiveBitrate.swift`) chooses the variant while
  reading ahead, until one is chosen by hand.

- *Requests* go through `URLSession` (`HTTPSessionTransport`), not FFmpeg's HTTP: `HLSSegmentLoader` asks for each
  playlist, init section, key and segment, and for a DASH demuxer `FFmpegIOByteCounter`'s `io_open` hands FFmpeg an
  `AVIOContext` of a task's own (`HTTPSessionInput`). The call waits for the answer's headers; the body comes into a
  buffer while the reader reads at its own pace (suspended past 32 MB unread). The session keeps the connections open,
  and is replaced by a new one, with the cookies, when a connection is lost (`HTTPSessionHolder`). YouTube's servers
  close an HTTP/3 connection after a response, and a session would put the next request, retries included, on the
  dead one. The error that reports the loss can follow a body that came whole; that is no failure. A lane asks for
  one request at a time (over HTTP/1.1 the next segment's body comes with its answer and halves the rate of the one
  read). The requests carry the source's headers, and FFmpeg's user agent (`Lavf/…`) without one.
  Measured inside FFmpeg instead, the throughput was a guess from how long reads took: a read served from what the
  socket buffered counted at memory speed, a request over a kept connection waited for its answer inside the read
  (Apple's CDN answers after 0.6–0.8 s on a cold cache, `x-cache: hit-stale, miss`), and a live stream's edge
  looked like a stalled network. Each guess needed a heuristic, and each heuristic missed a case: Apple's AV1
  example came down to 1080p or lower within seconds of a start at 184 ms of round trip, and stalled for up to
  1.4 s, on a link carrying 4K many times over.
- *Throughput* is each request's transfer, from its answer to its last byte (`NetworkTransferMeter`), as VLC,
  hls.js and ExoPlayer measure their segments' downloads. A sample weighs the media its bytes are at the variant's
  `BANDWIDTH`: an audio segment a twentieth of a 4K video one's. Taken over every transfer together, or weighed by
  its seconds when slower than real time, half a megabyte of audio on a connection idle since its last (TCP starts
  it slowly again: 5.7 Mbit/s of 90 at 184 ms) weighed more than a 4K segment, and took the variant down to 864 wide
  two seconds in. The first estimate waits for a second of the variant's media: after the first video segment.
  A sample comes once a request ends: a link collapsing in the middle of a segment shows in the estimate only after
  it (the download under way is watched by *Giving a download up*, below).
  Transfers that run side by side share the link, each at a part of it: at a switch the old variant's segment is
  still read while the new one's comes (both are enabled until the splice). A sample's rate is the link's: all the
  bytes every transfer received while this one ran (`NetworkTransferMeter.received`, `Transfer.linkBytes`) over its
  seconds, however they divided it (a share assumed equal overrated a heavy segment beside a light one). Taken as
  each one's own, 1.5 Mbit/s read as 0.8–0.9 for the two transfers of the first switch and took the estimate under
  the variant switched to (0.95 of 1.05 < 1.08), down to the lowest (`switchOverlapIsNoCollapse`).
- *Latency*, the time inside `io_open` waiting for answers, counts as seconds per second of media read
  (`latencyShare`), the same for every variant: a variant fits when a second of it reads, transfer and latency,
  within its share of a second (dash.js weighs latency so too). A server slower to answer than its segments last
  brings the variant down however fast the link, to the lowest when the latency alone takes `safety` of the
  media, with no estimate yet too. A request counts once answered, ahead of its media: the share counts from 6 s
  of media read on. Answers for bodies under 16 KB (init sections, keys) are paid once, at the start and a switch,
  and count in no share: counted, two init sections' 0.76 s took the share from 0.29 s a second to 0.42 over the
  first 6 s of media, enough to bring 4K down. Openings while a variant switch catches the new variant up count
  neither: a cost of the switch, read without media.
- *Live edge*: the lane waits inside the read, reloading the playlist, until it lists a segment: a long read with
  next to no bytes (`isLiveEdgeWait`). It counts as a full read-ahead, which a live stream never reaches otherwise,
  and the reloads as no latency.
- *Decisions*: an estimate (the lower of two exponential averages, as dash.js and GStreamer) keeps a variant that
  reads within 0.95 of a second, as hls.js does (`abrBandWidthFactor`), and brings one that doesn't down while
  the read-ahead is under two thirds of its limit. It steps up to what reads within 0.7 of a second (hls.js's
  `abrBandWidthUpFactor`, ExoPlayer's `bandwidthFraction`) from 10 s of read-ahead (ExoPlayer's
  `minDurationForQualityIncrease`), 2 s after a switch. Without a recent estimate a full read-ahead probes one step
  up (at its limit the thread measures nothing, however fast the network), 10 s after a switch; a step up that
  comes down soon doubles the wait before the next. At 0.8 to be kept, a start on a cold cache came down from 4K
  on its first estimate (76 Mbit/s, before TCP had opened up; then 150–180): 4K's 38.5 Mbit/s read within 0.84 of a
  second, and the read-ahead grew all the same. Waiting for a full read-ahead to step up, the step back up came
  17 s in, and showed 21 s later still: a switch splices at the read position.
- *Stepping up past the estimate's reach*: a variant held at 0.7 to 0.85 of the link never climbed (the estimate
  steps up at 0.7, a full read-ahead probed only without a recent estimate): on a 25 Mbit/s link Apple's AV1 example
  stood on 1080p at 11.3 Mbit/s for 100 s, the link carrying 4K at 18.9. With a recent estimate, a full read-ahead
  (`highBuffer`) and `upSwitchInterval` (times the failed probes' backoff) after the last switch, the logic now tries
  the next variant of more bandwidth and no fewer pixels (21.5 Mbit/s at 2560 wide after 18.9 at 3840 isn't a step up;
  an unknown size counts as no fewer) when 0.85 of the estimate less the latency share fits it (`probeSafety`). Not
  at a live edge: there the read-ahead is raised to stand for a full one while seconds are buffered
  (`isReadAheadReal`).
- *Hysteresis*: a variant just stepped up to (within `failedProbeWindow`) is left only when it doesn't fit 1.0 of the
  estimate (`probeHoldSafety`, its peak bandwidth against the estimate), not 0.95, and when that has held for 5 s
  (`holdDebounce`), unless its bandwidth is over the estimate itself or the read-ahead is under `urgentBuffer`. A
  steady 25 Mbit/s link's estimate dipped to 20 for a second (23 to 20.7 with 0.1 of latency) and took 18.9 down 8
  to 13 s after the step. A variant reached by a step down has no such hold: with 0.15 of latency a second of 18.9
  costs 0.99 s of wall time at 22.4 Mbit/s, and leaving it is right.
- *Start on a slow link*: an HLS opening's probes (`HLSInput.openingLinkRate`, bodies only) follow
  the CDN's answer as much as the link (4.8 to 62 Mbit/s on fast links, 17–24 on a true 25, 1.6–1.9 on 2), so it
  proves a link slow and never fast. Under 3 Mbit/s (`slowLinkLimit`, below the lowest read on a fast link), past the slow
  start (see "HLS opening"), the start is the highest variant within `safety` of it (as DASH's `OpeningLimit.throughput`
  does), else the lowest; otherwise the best, as before. On 2 Mbit/s (NLC "DSL") a start on the top variant (39
  Mbit/s) stalled 62–70 s of 120, the first estimate coming after a 10 MB segment; on the variant the rate carries,
  0 s in two runs. A link between 3 Mbit/s and the best variant's bandwidth still starts on the best.
- *Giving a download up* (`MediaDemuxer+Abandonment.swift`, `AdaptiveBitrateLogic+Abandonment.swift`): `choose`
  decides between segments, so a segment that will not arrive before the buffer runs out (a heavy start, a link that
  drops with a full read-ahead) is checked while it downloads, by hls.js's `_abandonRulesCheck` (past half its
  duration; a lower segment sooner by a margin). Given up, its bytes stop and a lower variant reads the same segment
  from its start (`DemuxerInput.joinNext`); the old variant's queued tail is cut as ExoPlayer splices a chunk
  (`attemptSplice`): from the first picture in decode order presented at or after the new keyframe, refused while one
  at or after it is handed out, the old variant's own sound cut on its own (a rendition both share is not touched).
  With the position inside the segment the cut is at a keyframe of it still queued. The estimate learns the download
  given up (hls.js's `resetEstimator`), or `choose` climbs straight back. A switch given up before its splice reads the
  old segment again, spliced in at its first keyframe past what is handed out (`RestartSplice`). Inside the segment a
  lower variant is taken only when it reaches the cut and carries the rest of its segment in time (a late one leaves a
  hole, not a stall). A give-up that took the lowest is stepped back up from once the link since carries more
  (`AdaptiveBitrateLogic.Detour`): 1.5 Mbit/s held 480 at 1.08 between keeping and stepping up, and played 320 for some
  40 s. On by default (`NITS_ABR_ABANDON=0` only logs the decisions). Measured on Apple's HEVC example (2026-11-12): 3.5 Mbit/s and 207 ms,
  the start on 10 Mbit/s given up at 4 s, no stall (5.5 s before); 2 Mbit/s after 45 s with 40 s buffered, the segment
  given up 4 s after the drop, no picture hole, no step back up, no stall. Against hls.js 1.7.3 behind one shaping
  proxy (2026-11-13; three scenarios, each the same in its three runs, as the shaper is deterministic: from ~100 to
  2 or 1 Mbit/s at 12 or 45 s, every time with a full buffer): no stall for either. With hls.js's buffer capped at the
  same 30 s, both gave a download up 4 s into the segment where the rest did not fit (hls.js not in the 2 Mbit/s-at-45-s
  scenario, where the segment under way fitted and the next went lower); hls.js then plays one segment of its lowest
  rung before the rung it settles on, Nits goes to that rung at once. The rungs reached were of the same height in two
  scenarios and lower for Nits in one (360p against 432p); the ladders differ (AVC + AC-3 for Nits, HEVC + AAC for
  hls.js in Chrome), so their bitrates do not compare. hls.js by default buffers up to 60 MB (~75 s here,
  `maxBufferSize`; `maxBufferLength` is only its floor) and seldom needs to give up. After a segment downloaded slowly
  in full (29 s for 8 s of media at 2 Mbit/s) the estimate fell only from ~90 to 12.6–14.1 Mbit/s, and the next
  segment was asked for on the 10 Mbit/s top again, given up 4 s into it; hls.js's estimate, weighing its samples by
  their seconds, went down after one such segment. See "State and known limitations".
- Measured on Apple's AV1 example (2026-10-24, Wi-Fi, three runs each, 45 s from the start, time below 3840 wide):
  - 34 ms round trip, warm cache: FFmpeg's HTTP and the transport alike 3840 throughout; the estimate's lowest
    17–20 Mbit/s through FFmpeg, 276–286 through the transport.
  - 184 ms (Network Link Conditioner), warm cache: FFmpeg's HTTP 27–38 s below, down to 608–1920, stalls of 0.1
    and 1.4 s; the transport, its samples weighed by their seconds when slow, 27–41 s, down to 864; weighed by
    their media, 0 s.
  - 184 ms, cold cache (10 minutes apart): kept at 0.8 and stepped up on a full read-ahead, 27.5 s below; stepping
    up from 10 s, 12–15.5 s; latency paid once left out, 11.5–12 s; kept at 0.95, 0 s. No stall in any of these.
    A cold cache's origin sometimes sends the bodies slowly (36–51 Mbit/s): coming down to 1920–2560 there, with
    4K at 38.5, is right.
- FFmpeg hands out the packet a discarded variant held when it is enabled again, from back then: a splice comes
  only at a keyframe at or after the old variant's latest decode time.

## Decisions

What was chosen, on what evidence, and what was turned down; dates are when it was settled. The measurements named
here are summarised in "Measuring". Before reopening one, read why it was closed.

### The client

- **A client of our own; FFmpeg demuxes segments only** (2026-11-10, phases 1–7, FFmpeg's HLS demuxer removed with
  deps 1.7.0). FFmpeg's `hls.c` needed three patches of ours (live seeks, the timeline at a break, a renewed `EXT-X-MAP`)
  and workarounds around it (a playlist prefetcher, `hls_live` metadata, `http_multiple`, a program splice), and gave no
  hold on the opening, on what a request costs, or on where a segment's packets go. DASH stays on FFmpeg, with its
  patches.
- **A `DemuxerInput` seam first, not a "virtual `AVFormatContext`"** (the user, 2026-11-10): the shortcut would have
  worked sooner and been rewritten as the work went on. The input lists variants as its container groups them; the
  demuxer chooses and splices, for any input.
- **A lane per variant playlist, spliced by the demuxer** (phase 5): each variant's streams are in the input's table and
  the demuxer's splice (`+Variants`, `+VariantHold`) switches between them. *Turned down:* the client switching at a
  segment boundary itself and passing new parameter sets as `AV_PKT_DATA_NEW_EXTRADATA` (one stream for all variants).
- **Segments stream into FFmpeg as they arrive** (phase 5). *Turned down:* whole-segment loads: a segment's download
  came before the first picture (4 s at 1.5 Mbit/s for 0.7 MB; 3.3 s of stall where the test allows 1.5). Encrypted
  segments still arrive whole (AES-128 is decrypted in one call; streaming decryption is open).
- **One request at a time per lane.** Over HTTP/1.1 the next segment's body comes with its answer and halved the rate of
  the one read (a live stream at 1.5 Mbit/s: the read-ahead empty for 7 s).
- **A target of its own (`NitsHLS`) later, not a repository** (2026-11-11): no second consumer, the interface still
  moves (ABR's fixes touch it), and a repository would drag FFmpeg's dependency build and its LGPL terms along. First
  the shared pieces move down (HTTP transport, `NetworkTransferMeter`, `TimestampUnwrapper`, `AVStreamTable`), then the
  client stops naming `MediaDemuxer`; the FFmpeg boundary stays (the client hands out `AVPacket`s). A repository only
  with a second consumer.
- **Out of scope:** LL-HLS (parts, preload hints, blocking reloads), SAMPLE-AES / FairPlay, `I-FRAME-STREAM-INF` trick
  play, content steering, interstitials (the primary plays).

### Timeline

- **One offset per discontinuity sequence, shared by every lane** (hls.js's `initPTS[cc]`, ExoPlayer's
  `TimestampAdjusterProvider`). *Turned down:* an offset per run from the summed `EXTINF`s, which erased real offsets
  between playlists: synthetic presets were "in sync" only because of it. Fix such a preset's timestamps, not the
  expectation.
- **Subtitle runs never anchor a sequence**, and a rendition's run waits for the picture to anchor it: cues are sparse
  (the first may be far into its segment), and a sound run that anchored first put the picture off.
- **Packed audio is placed by its first segment's ID3 `PRIV`**, without one by its playlist and apart from the shared
  offsets: it starts at 0 whatever the picture's base, and took or overwrote the picture's offset before.
- **Segment places corrected from the media** (hls.js's `updateFragPTSDTS`, 8eee588): integer `EXTINF`s drift a third of a
  second in five minutes and put seeks late. The zero of the timeline is not moved (open).
- **Reloads follow ExoPlayer** (`isNewerThan`: merged only when newer than the window; numbers behind it a reset, past it a
  restart with a gap; a playlist unchanged for 3.5 target durations is stuck). *Turned down:* restarts by dates and a
  counter of stale reloads (round 6 of the parser's review replaced such heuristics with these rules).

### Opening

- **Probe the top rung only; describe the others from it** (candidate 2, 45b298c; hls.js and ExoPlayer read the start
  variant alone). Every rung probed took 6–7.5 s on a cold CDN. A clone is checked at its first read and given up when
  it differs. The next rung down is probed beside a top that has not answered in 4 s (`ProbeRace`): Dolby Vision's top
  init went unanswered for 10 s twice, and the opening failed with the top alone.
- **Lean analysis for a probed lane's runs** (candidate 1, dcbb04e): a seek's run on 4K fMP4 read 3.2 MB before its first
  packet, 0.43 MB after. MPEG-TS keeps FFmpeg's frame count: cut short, its ADTS sound lost its timestamps after the first
  packet.
- *Turned down:* **stopping a probe once analysed** (tried and reverted 2026-11-11): the second wave of probes started 5 s
  sooner at 2 Mbit/s, but the probes' bytes are what proves a link slow, and without them DV started on its 40 Mbit/s top.
- *Not built:* **lazy media playlists**: 0.8–1.3 s at RTT +150 ms; worth it only if a measurement shows it.
- **The link's rate is read past TCP's slow start** (`skipSlowStart`: max(128 KB, the limit's two round trips)), the limit
  stays 3 Mbit/s (five profiles, 2026-11-11). One probe on a fresh connection at 180 ms brought its first 256 KB at
  2.6–5.2 Mbit/s on a fat link: a false "slow" without the skip. *Turned down:* proving a link slow by the time past the
  skip (changes no outcome in the gap), a 256 KB cap on the skip (RTT +350 needs 278 KB), an early "not slow" (little
  gain).

### Adaptive bitrate

- **Start on the top rung; lower only on a link proven slow** (A-simple, 45d46ef; the user closed the question
  2026-11-07). The opening's rate follows the CDN's answers as much as the link (4.8–62 Mbit/s on fast links), so it can
  prove a link slow, never fast. *Turned down:* a start variant from that rate in general; a "bodies took ≥ 2 s" rule
  (a false positive margin of 1.84 s at RTT +150); a low start by default (hls.js, VLC, ExoPlayer: low quality for ~30 s
  on a fast link); a fixed middle rung. *Closed:* "C", an estimate from a request under way with a rollback to the
  current frame: A-simple covers slow links, and giving a download up now covers the heavy start.
- **Requests through `URLSession`, each transfer measured apart from its answer** (a7f3270): measured inside FFmpeg, a
  read from the socket's buffer counted at memory speed, a kept connection's answer wait counted as transfer, and a
  live edge looked like a stalled link; Apple's AV1 example came down from 4K within seconds on a link carrying it many
  times over.
- **A sample weighs its media, not its seconds**: weighed by seconds when slow, half a megabyte of audio on an idle
  connection (TCP's slow start again) outweighed a 4K segment and took the picture down to 864 wide two seconds in. The
  price, found 2026-11-13: a whole segment downloaded slowly moves the estimate little (see "State").
- **Transfers side by side count the link's bytes** (`Transfer.linkBytes`, ef9d174): taken as each one's own, 1.5 Mbit/s
  read as 0.8–0.9 during a switch and collapsed to the lowest rung.
- **The up-step's dead zone: a probe at 0.85 on a recent estimate**, no fewer pixels, not at a live edge, with a hold of
  1.0 for 5 s after a step up (45d46ef): a 25 Mbit/s link held 1080p at 11.3 Mbit/s for 100 s while carrying 4K at 18.9.
  *Accepted:* a rung at the edge flaps with a latency share of 0.15 (correct by the model: a second of it costs 0.99 s).

### Giving a download up

- **One mechanism for a heavy start and a drop with a full buffer: hls.js's abandon rule** (step 5, 2026-11-11 to 13; on
  by default 36d8aaf). The check runs inside the request's wait, from the read-ahead's idle step, and from a rendition's
  wait: with the buffer full the thread does not wait, and a 7 s wait on the audio rendition hid the picture's download
  from the check (it fired 12.5 s into the segment instead of 4 s).
- **The queued tail is cut at the splice, not at the abort** (ExoPlayer's `attemptSplice`): from the first picture in
  decode order presented at or after the new keyframe, refused while one at or after it is handed out. *Turned down:*
  re-reading from the current frame for every case ("(b)": a full-buffer drop would throw 6–9 s away and pause on a link
  just dropped); a hole to the next keyframe; a cut at an old keyframe of the same presentation time (the ladder was not
  keyframe-aligned at one boundary: a 1.1 s hole). *Not built:* (b) for the start, needed 0 times of 3; waits for a stream
  with 2–6 s GOPs that shows it.
- **The switch is made at the packet boundary, not inside the wait** (second opinion, 2026-11-12): the check fires inside
  `HLSInput.read`'s loop; only stopping the bytes is done there, and the interrupt passes as a yield (no new lane code,
  which every caller of `fill` would have to know).
- **Captions are decoded as pictures are handed out, not as they are read** (5b-0b): a cut tail had already reached the
  closed-caption decoder, whose screens build on each other; neither rolling the cues back nor deduplicating them mends it.
- **The estimate learns the download given up** (hls.js's `resetEstimator`, 51eba03): without it `choose` went back to
  the top within 10–25 s and the next top segment ran the buffer from 40 s down to 9.5. A give-up to the lowest rung is
  stepped back up from once the link carries more (`Detour`, 8d84506): 1.5 Mbit/s held 480 between keeping and stepping
  up, and played 320 for 40 s.
- **The pick after a give-up is hls.js's**: the highest rung within the buffer, else the lowest. *Turned down (tried):* the
  highest rung that merely beats the download under way: each second its segment loads is a second of stall, and over the
  link it is given up again at the next segment. A margin of max(1 s, 15 %) on the lower segment's time keeps from giving
  up for 0.5 s of gain.
- **Inside the segment, a lower rung only if it reaches the cut and carries the rest of its segment in time**, with no
  fallback to the lowest: there a late rung leaves a hole, not a stall.
- *Not wanted:* a margin on "the rest does not fit the buffer" (proposed and withdrawn 2026-11-13): of the two outcomes at
  the edge, keeping the download was the riskier one (the next segment on the top again, the lower rung arriving with
  ~7 s left), which is the estimate's problem, not the rule's.

## Measuring

Nothing here is decided from a guess: a change to the opening or to adaptive bitrate is measured on a real stream
before and after, on the network it is about. Unit tests and `TestHTTPServer`'s throttle check the logic; they do not
tell what a CDN and a real link do.

### The environment is part of the result

- **The network.** Network Link Conditioner (NLC) cannot be scripted: agree the profile with the person at the machine
  before each series and keep it until the series ends. The shaping proxy below needs no one, and is the first choice
  for anything a bandwidth schedule can express.
- **The CDN node.** `dig devstreaming-cdn.apple.com`, then `ping -c 10` each address: one node (17.253.39.143, ~24 ms)
  lost 20–80 % of pings and spoiled runs; measure on a node without loss (the ~50 ms ones), and write the RTT down.
- **The CDN's cache.** Apple's examples are `max-age=600`: a cold run needs ten minutes without a request before it,
  and the CDN's answer waits change by the minute on their own (median 1.8 s one minute, 0.13 s the next). Throw the
  first run of a series away, and interleave what is compared rather than running one mode after the other.
- **The build.** `PKG_CONFIG_PATH=$PWD/.build/dependencies/lib/pkgconfig`, so the tests run on the bundled, patched
  FFmpeg. NLC off for the local suites (it slows `TestHTTPServer` too).

### Tools

- **The shaping proxy and hls.js** (`scripts/hls-stand/`, its README): a bandwidth schedule from the first request, the
  same for any player behind it, every request logged; Nits or hls.js 1.7.3 in Chrome played through it, one command a
  run. Deterministic: a scenario's runs are one sample of it.
- **The probes** (`Tests/NitsCoreTests/Measurements/`, their README lists the variables): `ABRStartRealMeasurement`
  (opening, first picture, stalls, decided and shown variants, the estimate each second), `HLSOpeningMeasurement`
  (where the opening goes: playlists, probes, analysis, a seek's run), `RealStreamMeasurement` (a stream through the
  engine: playback against the wall clock, seeks), `LadderSeekMeasurement` (seeks on a ladder, cache or network).
- **Diagnostics** in the demuxer: `NITS_ABR_TRACE=1` (where the give-up checks came from, each second, and why a
  download was kept), `NITS_ABR_ABANDON=0` (decisions logged, nothing given up), the log lines `ABR abandon …`,
  `HLS opening rate:`, `HLS client: … opening N kbit/s`.

### Profiles and streams

NLC profiles used: off (Wi-Fi, RTT 31–55 ms to the CDN), "RTT +150" (180–187 ms, bandwidth unlimited), "RTT +350",
20 Mbit/s, 25 Mbit/s, 3.5 Mbit/s with RTT +150 (the gap between a slow link and the top rung), "DSL" 2 Mbit/s. The
proxy's schedules: ~100 Mbit/s, then 2 or 1 Mbit/s at 12 or 45 s.

Streams (`https://devstreaming-cdn.apple.com/videos/streaming/examples/`): `bipbop_adv_example_hevc/master.m3u8` (HEVC
and AVC ladders, 8 s segments; Nits plays its AVC + AC-3 ladder, top 1920×1080 at 10 Mbit/s), `av1-sample/av1-sample.m3u8`
(4K AV1 at 39 Mbit/s, 4 s segments, keyframes every 2 s), `adv_dv_atmos` (Dolby Vision, lowest rung 5186k),
`img_bipbop_adv_example_ts`, and JW Player's AES-128 `oceans_aes`. Real streams checked end to end (2026-11-13, all
clean): those Apple examples, Apple's interstitial sample, JW's AES with tracks, Mux DAI, Google DAI, YouTube live through
its HLS master.

### Results

| Date | Question | Profile, stream | Result |
|---|---|---|---|
| 2026-10-24 | Throughput inside FFmpeg against each transfer through `URLSession` | AV1, RTT 34 / 184 ms | 184 ms: FFmpeg 27–38 s below 4K with stalls to 1.4 s; the transport, samples weighed by media, 0 s below |
| 2026-11-07 | The dead zone of the step up | AV1, NLC 25 Mbit/s, 120 s | 100 s on 11.3 Mbit/s → climbs to 18.9 in 10–16 s and holds, 0 s stalled |
| 2026-11-07 | Start on a slow link | AV1, DSL 2 Mbit/s, 120 s | started on the top: 62–70 s stalled of 120 → on the rung the rate carries: 0 s |
| 2026-11-07 | The same rule on a fast link | AV1, NLC off | starts on the top, 0 s stalled: the rule does not fire |
| 2026-11-11 | Where the opening goes | 5 streams, NLC off / RTT +150 / 20 / 2 Mbit/s | warm 0.6–0.9 s on a fast link (the 6–7.5 s seen before was a cold CDN); RTT +150 3.35–4.2 s, playlists and probes in waves of 6 connections; 2 Mbit/s 6–28 s, nearly all probes |
| 2026-11-11 | Lean analysis of a probed lane's runs | AV1 / DV 4K, 20 Mbit/s | a seek's run 1.68 → 0.47 s (AV1), 2.24 → 1.33 s (DV) |
| 2026-11-11 | The opening's link rate, top rung only, past slow start | 5 streams, five profiles | fast links read 47–61 Mbit/s, RTT +150 5–10, 2 Mbit/s 1.7–2.0: limit 3 Mbit/s holds; openings faster (RTT +150 HEVC 3.35 → 2.4 s, 2 Mbit/s DV 8–13.8 → 2.5–3.0 s) |
| 2026-11-12 | Giving a heavy start up | HEVC, 3.5 Mbit/s + RTT +150 | given up ~4 s in, first picture 3.2–4.1 s, 0 s stalled (5.5 s before) |
| 2026-11-12 | A drop with a full buffer | HEVC, NLC off then 2 Mbit/s at 45 s | given up 4.1 s after the drop, clean cut, no step back up, 0 s stalled |
| 2026-11-13 | Against hls.js, drop with a full buffer | HEVC, proxy: ~100 → 2 / 1 Mbit/s at 45 s, → 2 at 12 s | 0 s stalled for both in all three; see *Giving a download up* in "Adaptive bitrate" for the rungs and the estimate |

Raw data, kept out of git: `.agents/hls-stand/` (the proxy stand), `.agents/hls-client/measurements/` (opening and give-up
series), `.agents/abr-measurements/` (2026-11-07). Not measured yet: a drop with a partly built buffer, a stream with 2–6
s GOPs (whether a re-read from the current frame is ever needed), links of 5–10 Mbit/s against a heavy top.

## State and known limitations

### Where it stands (2026-11-13)

The client is HLS's only path (FFmpeg's HLS demuxer is not built), merged into `main`; real streams run clean
(Apple's examples, Mux and Google DAI, JW AES, YouTube live). Giving a download up is on by default, and with a full
buffer a drop of the link stalls neither Nits nor hls.js behind the same shaped link. Open, in this order:

1. **The estimate after a slow segment** (first entry below): the next fix of adaptive bitrate.
2. **A drop with a partly built buffer**, measured on the shaping proxy (a first link of ~15 Mbit/s, then 1.5): until
   then "no stall" is shown for a full buffer only.
3. A live-stream test of `isReadAheadReal` (the probe up must not take a live edge's raised read-ahead for a full one).
   *Closed:* the burst of latency right after a switch (2026-11-07, latency share 15 → 100 ms/s, which took ABR off a
   rung twice) was seen through FFmpeg's HLS demuxer, before the client; never reproduced, and the client's nine
   switches of 2026-11-13 peaked at 25–54 ms/s. Look again only if a step up is left right after it on a steady link.
4. Then the client as a target of its own (`NitsHLS`, see "Decisions").

Decisions without a date: (b) AES-128 measures no link rate at the opening and its probes download whole segments
(the fix is streaming decryption); (c) the Dolby Vision ladder bottoms at 5186k, so a slow link has nothing in it to
go down to: whether to leave the ladder for another group (its low DV rung, 672×378 at 1.35 Mbit/s, differs mainly by
its audio group).

### Known limitations

- **The estimate hardly falls after a segment downloaded slowly in full.** A sample weighs its media, not its seconds
  (see *Throughput* in "Adaptive bitrate"): behind a shaping proxy (2026-11-13, ~100 then 2 Mbit/s with a full buffer) a
  segment of 8 s took 29 s, and the estimate went from ~90 only to 12.6–14.1 Mbit/s, which keeps the 10 Mbit/s top;
  the next segment was asked for on it again and given up 4 s in, with 15 s buffered, the lower rung arriving with
  ~7 s left. hls.js, weighing by seconds, went down after one such segment. No stall, but the margin came from giving
  up, not from the estimate. Whether a segment is kept or given up turns on fractions of a second (given up at
  29.4 s of rest against 29.2 s buffered, kept at 29 against 38); with a sound estimate the kept path would be safe
  too. Cause as the code reads (`AdaptiveBitrateLogic.addSample`), not checked by a test; nothing changed yet.
- **A link between 3 Mbit/s and the best variant's bandwidth starts on the best variant.** Only an opening rate under
  3 Mbit/s starts lower (`HLSInput.openingLinkRate`, `slowLinkLimit`): the rate follows the CDN's answers as much as the
  link (4.8 Mbit/s on a fast one, before the opening skipped TCP's slow start), so a higher limit would start low on fast links. A start segment that will not arrive in time is given up
  past half its duration for a lower variant's (see *Giving a download up* in "Adaptive bitrate"): on 3.5 Mbit/s
  with 207 ms the start on 10 Mbit/s was given up at 4 s with no stall (5.5 s before). What is left is that half a
  segment of waiting at the start (4 s for Apple's 8 s segments); a lower start by default (hls.js, VLC, ExoPlayer)
  would avoid it at the price of low quality for ~30 s on a fast link.
- **A variant at the edge of the link flaps.** With a latency share of 0.15 and an estimate of 22–23 Mbit/s, 18.9 Mbit/s
  fits neither the hold (0.95 less the share) nor leaves room, and the stream went 18.9 → 11.3 → 18.9 every 15–25 s in
  one of eight 25 Mbit/s runs. The probe's backoff only lengthens the climbs.
- **Variant switches at the edges** (read from the code; not seen on a stream). `.following(time)` past the end of a
  shorter VOD variant gives that lane's last segment, then `.ended`: the switch never splices (end of input cancels it
  cleanly, `endVariantSwitchAtEOF`). A lane unread for longer than a live window comes back as `.restarted(gap:)`, and
  without `PROGRAM-DATE-TIME` the gap is counted as segments × target duration, so the switch may join at the wrong
  segment.
- **A demux error inside a run resumes at `current`**, which may already be the next segment if the feed asked for it:
  the hole may be a segment longer than the error (telling the two apart by `reader.failure` is not done). A plain
  re-read of `current` would loop: `skipped` resets on every packet.
- **AES-128 segments arrive whole**: no streaming decryption, so a probe of an encrypted rung downloads its whole first
  segment (6 probes at 2 Mbit/s took 20 s of the opening) and the opening measures no link rate (decision (b) above).
- **Subtitle renditions outside playback** (`EmbeddedSubtitleReader`): VOD only, and only the stretches whose breaks the
  picture anchored (waits up to 2 s); live renditions are read by playback alone.
- **What the breaks leave.** Until 2026-11-11 the timeline at a break was a patch of FFmpeg's HLS demuxer (`has_discont`,
  `first_timestamp`, thresholds of half a target duration and 2 s / 1 s on a jump, a guard on late pictures, an estimate
  for expired segments); the patch is gone, and so are those limits. The client does not look for jumps in timestamps:
  it learns of a break from the playlist, from the tag (`EXT-X-DISCONTINUITY`, `EXT-X-DISCONTINUITY-SEQUENCE`) and from
  its numbering, and starts a run of its own at each (a change of discontinuity sequence or of init section, a gap,
  numbers that skip, `.expired`, a late reload that `startRun` counts as a break and numbers with
  `discontinuityCorrection` when the server does not declare the sequence). The offset is the discontinuity sequence's,
  not the run's: a run in a sequence already anchored takes it (a change of init section or a gap inside a sequence
  moves nothing), and only a run whose first packet it puts further than the tolerance anchors anew. Read 2026-11-13;
  what is run is said below.
- **HLS `EXT-X-DISCONTINUITY`: what the client leaves.** The client moves the timestamps of the segments after a
  discontinuity onto the playlist's timeline ("Timeline and discontinuities" above). Measured 2026-11-06, before the
  client: on FFmpeg's HLS demuxer without the timeline patch (`424a8ac`) the second segment of `hlsDiscontinuity`
  dropped ~89 frames and the picture stood at 7.99 s for the last four of 12 s; PlayOn's test stream
  (`s3.amazonaws.com/playon-test-videos/discont_test_new/discont_test.m3u8`) dropped 697 frames and stood at 8.0 s for a
  minute; a seek past the first break landed at the start of the file. With the patch (`23b51b9`) the picture followed
  the clock to the end in both and a seek landed in the right segment. On the client `hlsDiscontinuity` is kept so by
  `HLSDiscontinuityTests` (green in every full run); PlayOn's stream has not been run on it. Left:
  - Advertisements on streams of their own: played since the client (the advertisements entry below).
  - A segment in another size is played (the demuxer starts a new format description where the parameter sets in the
    band change, `MediaDemuxer.videoPacket(from:)`; on `hlsDiscontinuityResize`, 4 s at 320x180 then 4 s at 640x360, the
    picture stood at 4.0 s before that, 2026-11-06; the demuxer's, so the same with the client). Not covered: only H.264 and HEVC with the sets in band (MPEG-TS and the like; AV1 and VP9
    have their sequence headers in band too); the software decoder (FFmpeg follows an in-band change by itself; not
    run); a seek back across a change in the packet cache (the size the player has is the later one while the earlier
    pictures play; a slow seek reports the size at its landing, always: the first keyframe after it tells the size, so
    the player does not keep the size of another stretch, an advertisement the reading has left).
  - A keyframe seek (a held arrow key) that lands past its target across a change of size: the size comes with the
    picture it lands on (its second), and is applied when the clock gets to `chase.seconds + 0.1`; while scrubbing the
    clock stands, so the picture is of the new size and `media.video` is still the old one until the scrub ends.
  - A change of the picture's size, and of its parameter sets only, is followed by the decoder; the rest of an
    advertisement's properties is not, and the pictures play with the old ones: the frame rate (`nominalFrameDuration`
    and the display link's rate stay: a variant's change updates them, `variantDidChange`; a size change does not), the
    pixel aspect ratio (the event carries the stream's old one), the colour (the description is made from the codec
    parameters of the open), another codec after the change (the sets are parsed as the first codec's), and HEVC with
    Dolby Vision. A format description with other parameter sets for the same pictures is taken by VideoToolbox's session
    (`VTDecompressionSessionCanAcceptFormatDescription`): PlayOn's stream alternates its SPS (timing in the VUI), and
    made a session each time (3 in 40 s before, 1 after; 2026-11-06, on the patch, not rerun on the client).
  - fMP4/CMAF with a new `EXT-X-MAP` at the break: FFmpeg's mov sub-demuxer skipped the later `moov`, so the stream kept
    the first section's `avcC` (until 2026-11-11 a patch passed the new one on). The client's `HLSLane.attachNewExtradata`
    puts the extradata of a run whose init section differs from the lane's last (`lastExtradata`) on its first video key
    frame as `NEW_EXTRADATA`, and the size follows (`HLSDiscontinuityFMP4Tests`, also after a seek back into the first
    stretch). Only H.264 and HEVC (the sets come from `NEW_EXTRADATA` in `refreshVideoFormat`); AV1 and VP9 keep the
    open's `av1C` / `vpcC`; audio extradata that changes with the section (another AAC configuration) is not taken by the
    audio path. A run's streams are matched to the table by kind and by order among the streams of that kind
    (`HLSLane.slotIndex`), not by codec: a stream of another codec in the same place is handed to the decoder made for
    the first, and a stream more than the first run had is dropped. Not run on a real stream.
  - Not checked for fMP4 with a new `EXT-X-MAP`: a ladder of variants. Going back to a variant whose init section the lane
    read last compares equal to `lastExtradata`, so no side data comes; whether `spliceVariantVideo` then builds the
    description right is to settle with ladders. A seek back into the first stretch that the packet cache serves reports
    no size (`seekReportingCache`), so `media.video` keeps the later stretch's; the engine tests start at 5 s so that the
    seek back is a slow one (the read-ahead is held until the first seek), and the cached case is not tested. The timeline
    thumbnails (`ThumbnailGenerator`, a context of its own, also on network sources) do not read `NEW_EXTRADATA`: past
    such a break they are probably missing or broken.
  - A separate audio rendition with its own playlist and breaks (synthetic: video-only variant plus an `EXT-X-MEDIA`
    playlist, fMP4, init sections renewed in both): the sound starts at the 4 s the playlists put it at, has no gap over
    100 ms, and the second stretch keeps the first's lead within 20 ms (`audioRenditionMeetsThePicture`). The client
    shares one offset per discontinuity sequence across its lanes (`HLSTimestampAnchors`): the picture is at the 4 s of
    the break and the sound keeps the lead its timestamps give it (the AAC priming, 21 ms; the preset's sound is moved
    by the picture's reordering, as a packager's would be), and a rendition whose durations differ from the picture's
    keeps its place (`audioRenditionSharesThePicturesOffset`).
  - Limits of the shared offset (read from the code, 2026-11-11, not seen on a stream):
    - A run anchored anew (its first packet further than a target duration (1 s at least) from where the offset puts it:
      a variant with timestamps of another base) changes the offset for the runs after it only. A variant switched to that
      is anchored anew plays against an audio rendition still on the old offset, apart by the difference, until the next
      seek opens both again; the log says "anchored anew". hls.c and the client before kept an offset per playlist, with
      the same effect whenever the playlists' durations disagreed.
    - A seek chooses the segment by the timeline's places and lands by the timestamps. The places are corrected from the
      media (`HLSTimeline.measure`, hls.js's `updateFragPTSDTS`): the reader tells where the first picture of each segment
      is (`HLSSegmentReader.Anchoring.onSegmentStart`: the first packet of the reference stream whose `pos` falls in the
      segment's bytes), and the entries between two measured ones have their durations scaled to fit, those outside
      follow as listed. A seek whose first segment turns out not to hold the target (listed durations too long or too
      short, so the segment started after it or ended before it) restarts, as the run opens (the first segment is measured from
      the start times before any packet is read), at the one the corrected timeline picks
      (`HLSLane.segmentStarted`, at most twice; `seekCorrectsTheTimelineFromTheMedia`). What is not corrected: a place
      nothing has been read near (a seek far from every segment read still chooses by the listed sums, and costs the
      restart above), a measure further than a target duration from the entry (the media's clock jumped: the offset
      decides, as before), a run whose streams have no start time (its first segment is then measured by `pos` after
      packets went out, so it refines the places but decides no restart) and segments after the first whose `pos` is unset.
    - The timeline's zero still depends on where a sequence was first anchored: a stream whose `EXTINF`s say 6 for
      segments of 6.006 s, opened (or resumed) at 50 minutes, anchors there, and the first segment, once read, is at
      about -3 s. The entries are consistent with the media from then on, but the zero is not moved (the engine has
      been told 0 is the start); past a target duration of error (100 minutes here) a run is still anchored anew.
    - A subtitle playlist that lacks the picture's breaks (all its segments in sequence 0 while the picture has an
      advertisement) places the cues after the break by sequence 0's offset, which the picture's first stretch anchored:
      off by the break's change of timestamps. The picture's offset is the fallback only for a sequence nobody anchored.
      Placing cues by the sequence the picture's timeline has at the cue segment's start, not by the subtitle
      playlist's own number, would cover it (RFC 8216 wants the numbers to match, so only broken playlists need it).
    - Packed audio is placed by the `PRIV` of its run's first segment and then by its own sample count: the `PRIV`s of
      the segments after it in the same run are not read (a run drifts only as much as its samples do).
    - A subtitle run in a container (IMSC, MPEG-TS) is now cut at each segment by `fill(before:)`, and each opens
      FFmpeg's analysis anew (`avformat_find_stream_info`): small segments, but one context each.
  - Audio and frame rate across a break (2026-11-06, on the patch; the numbers are not re-measured on the client):
    Google's `ima-vod-skippable-test` has no audio and 25 fps in the content and the advertisement. On the 16 + 6 + 4 s
    synthetic (three timestamp domains) the audio had no gap or overlap over 100 ms through both breaks, and the
    pictures stepped one frame at each break after a bug of the patch (an offset from the DTS where the PTS belonged, a
    reordering delay of 67 ms) was fixed. `HLSDiscontinuityTests` keeps the audio timeline of the 4 + 8 s preset (no gap
    over 100 ms, ends past 11.5 s). A/V sync through a break by the `flashClick` method:
    `SyncPatternTests.acrossAnHLSBreak` (fMP4 with the sound in a rendition of its own, FLAC so that the clicks are
    exact, the second stretch's first whole second seen in picture and sound at its absolute place, as the seconds
    repeat). The trimming of AAC's priming samples after a break (about 21 ms) is not covered. The tests fail on the
    faults they were made for (checked on the patch by bringing each fault back): the audio left out of the offset
    (`HLSDiscontinuityTests`), the offset taken from the DTS instead of the PTS and the audio playlist's offset left out
    (`acrossAnHLSBreak`); the client anchors by the first PTS (`start_time`, else the first packet's `pts`), so the DTS
    one is the fault to guard against. Not done: a change of frame rate at a break (a variant's change sets
    `nominalFrameDuration` and the display link's rate; a break does not, and the pictures are paced by their timestamps
    meanwhile). The 67 ms lead of picture over sound at the start is of the synthetic streams (tracks encoded apart,
    only the video shifted); the tests hold the second stretch to the first's lead: positions to each other, not
    absolute sync.
  - Real streams. On the patch (2026-11-06): Google DAI (`ima-vod-skippable-test`, `POST
    https://dai.google.com/ondemand/hls/content/2483977/vid/ima-vod-skippable-test/streams`; the address expires; six
    segments of content, a break, three of advertisement, timestamps back from 51.40 to 0.00 s, 640x360) played its 90 s
    with no frame dropped (before: the picture stood at 60.0 s with 750 frames dropped); PlayOn's dropped the 240 frames
    of its segment without a tag (97.5 to 105.6 s). On the client (2026-11-13, `RealStreamMeasurement`, 20 s of play
    and seeks to 40 % and 10 %, so not through every break): Google DAI and Mux's Deltatre DAI played at the wall
    clock's pace with nothing dropped; PlayOn's was not run. Mux's
    (`test-streams.mux.dev/dai-discontinuity-deltatre/manifest.m3u8`) puts the later main content on timestamps already
    jumped by the length of the ads, so the offset its sequence anchors comes out as the content's before the ads, as it
    should (read from the code; Mux's whole 266 s played through the client on 2026-11-11, see the advertisements
    entry below). The content ids are in `.ref/exoplayer/demos/main/src/main/assets/media.exolist.json`; the
    `tears-of-steel` example is out of date (its content segments answer 404).
  - A segment whose timestamps restart with no `EXT-X-DISCONTINUITY` before it is not seen: PlayOn's stream has one (the 8 s
    segment before its last tag), which on the patch landed at -6.4 to 1.6 s and left a hole at 97.5 to 105.6 s. The client
    does not guess breaks from a jump: the segment stays in its run and takes the run's offset like the segments before
    it, so it lands where its restarted timestamps put it (probably the same hole); not run on the client.
  - A live stream with breaks (`HLSLiveDiscontinuityTests`, synthetic), in two kinds: every 4 s segment restarting its
    timestamps at 0, and server-side ad insertion (`hlsLiveAds`: content on a running timeline from 1000 s, two
    advertisement segments from 0 after every three of content, so the content after the advertisement is already on the
    stream's time, as Mux's is). A window of 10 segments sliding, opened after it had slid. The read from the edge,
    where the engine plays, is `edgeThroughAnAdvertisement`: content (number 10), the advertisement (13, 14), content
    again (15 on, already 8 s on): the steps stay under 0.2 s and the sound has no gaps. Picture and sound go on across
    the breaks (steps under 0.2 s, gaps under 0.15 s), keyframe seeks within the window land within a segment of the
    target, and the engine plays and seeks to the oldest place allowed (the clock goes on, the picture follows it, under
    20 dropped). `engineCrossesAnAdvertisement` takes the engine across both borders of the advertisement (seeks to 18
    and 26 s on the window's timeline, 2 s short of the entry at 20 s and the return at 28 s): the clock and the picture
    go on past each, under 20 dropped. The content is made up to segment 29, and a test's playlist must not reach past
    it. `expiredSegmentsKeepTheTimeline` slides its playlist a segment a second up to the advertisement preset's last
    segment (number 29), where the window stops: a read slow enough to still run 17 s after the open then finds no skip
    and the test fails as such, not on segments the server does not have. The lag check of the engine tests failed
    twice, in the first run after a build each time; the second message said 35 s at 0 s from the start, a first sample
    before the first picture (`currentFramePTS` is -1 until one is shown), which the check skips now; the first message
    was not kept. A live stream's window starts at 0 as it opens and everything after is positive (the engine reads
    `currentFramePTS >= 0` as "a picture is there": a seek into a negative part of the window once stood the clock):
    `HLSInput`'s `timelineOrigin` is 0 and its zero is the first segment listed at the first load (a negative start is
    not the origin: the `FFmpegInput.timelineOrigin(of:)` of MPEG-TS/PS and `EmbeddedSubtitleReader` is a different
    path); an EVENT playlist starts at 0 too (`eventPlaylistStartsAtZero`). Not covered: a live ladder with breaks
    (single variant only; see Ladders), a stream whose timestamps jump on without a break, audio of a rendition with its
    own live playlist, a live stream of fMP4, and a real stream (only synthetic ones).
  - Not read from the client in this review: how the playlists' breaks reach `EmbeddedSubtitleReader` (the entry below).
- **HLS subtitle renditions: a window past a break the pictures have not anchored waits for playback.** The window read
  (`EmbeddedSubtitleReader.readSubtitles(hls:…)`) reads only the stretch whose discontinuity sequences the pictures
  anchored (from the first such segment to the first that isn't), and waits up to 2 s for any: cues elsewhere would be
  placed by a wrong offset. Playback reads them when it gets there; only a negative subtitle delay shows the
  difference.
- **Advertisement segments on streams of their own: done by the client, not on every kind of stream.** Mux's Deltatre
  DAI stream (`test-streams.mux.dev/dai-discontinuity-deltatre/manifest.m3u8`: ads of 720x408, `METHOD=NONE` among
  AES-128 segments, MPEG-TS with their own PMT) lost the 180 s of ads to FFmpeg's HLS demuxer (the picture stood at
  36.2 s). Through `HLSInput` (2026-11-11) every run of segments has a demuxer of its own, and the stream plays to its
  end: 6651 pictures, 266 s, the position never going back. Not covered: a run whose streams differ in number or type
  from the first run's (they are mapped by order and type, as the run before's), and the picture's size change in
  a stream whose parameter sets are not in band.
