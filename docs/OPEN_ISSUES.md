# Open Issues

Problems that still need data or a real-world check. Fixed issues live on in the code, `docs/ARCHITECTURE.md`,
`AGENTS.md` and git history; remove an entry here once it is resolved.

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

## Flaky tests to watch

- **`BackwardFrameSteppingTests`** failed once locally with `engine.stepFrameCache.count → 0` after a paused
  exact seek. Suspected: the pause did not hold (the seek ran as a resuming seek, which does not seed the cache) or
  feeding restarted after it (`startFeeding()` clears the cache). The failure message reports cache size, play
  state and current frame to tell these apart.
- **`FormatDescriptionCacheTests`** failed twice on CI with VideoToolbox returning 1–3 frames of 30 (always 30
  locally). The failure message now reports fed samples, session creation status, decode error statuses and the
  last callback status.
