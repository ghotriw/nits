# Logging

All player logs go through `AppLog` (`NitsCore`). Each message is sent to:

- `os.Logger`, subsystem `com.nits.app`, category = the `LogCategory` name (`Video`, `Engine`, … — capitalized;
  `log` predicates are case-sensitive)
- an in-memory buffer of the last 2000 entries, used by the log viewer
- `~/Library/Application Support/Nits/player.log`, written asynchronously

Messages below `AppLog.minimumLogLevel` are not formatted (the message is an `@autoclosure`).

## Logging from a host app

```swift
import NitsCore

AppLog.info(.host, "Playback session started")
AppLog.warning("Network", "Retrying range request")  // ad-hoc category
```

`LogCategory` is `ExpressibleByStringLiteral`. To get a typed category:

```swift
extension LogCategory {
    static let emby = LogCategory("YourCategoryName")
}
```

Levels: `debug`, `info`, `notice`, `warning`, `error`.

The default minimum level is `.debug` in every build configuration. To change it at runtime:

```swift
AppLog.minimumLogLevel = .debug
```

## Log viewer

```swift
import NitsKit

LogViewerWindowController.shared.show()
```

The menu command `PlayerCommands.LogConsoleMenuCommand()` binds it to ⌥⌘L. The viewer can filter by level and category, search, copy, export and clear the log (clearing also truncates `player.log`).

## Reading logs from the terminal

```bash
tail -f ~/Library/Application\ Support/Nits/player.log

log stream --predicate 'subsystem == "com.nits.app"' --level debug
log show --predicate 'subsystem == "com.nits.app"' --last 10m --info --debug
```

`log show` only has what was persisted; debug messages usually are not, so use `log stream` (or `player.log`) for
them.

## Frame cadence diagnostics

Debug lines in the `Video` category that show how evenly frames reach the screen (see "Display pacing" in
`docs/ARCHITECTURE.md`):

```bash
log stream --level debug --predicate 'subsystem == "com.nits.app" AND category == "Video" AND (eventMessage CONTAINS "Cadence" OR eventMessage CONTAINS "Display clock" OR eventMessage CONTAINS "Frame held")'
```

- **`Cadence 5.0s: …`** every 5 s of continuous playback (`FrameCadenceStats`):
  - `on 118.96 Hz, link 8.403 ms mean (duration 8.333, 6.25…10.42, missed 16)` — vsync spacing measured from the
    link's target timestamps against what `CADisplayLink.duration` reports, with the spread of single intervals and
    vsyncs the link skipped. Every tick figure (holds, ideal pattern, spread) uses the measured spacing.
  - `held 2×75 3×50` — how many link ticks each frame stayed up, against the ideal pattern in brackets (25p on
    60 Hz: 2 and 3 ticks, 60/40). `off-pattern` counts other hold lengths, `skipped` frames that never showed.
  - `slack min…max` — how far past its pick threshold each frame was when picked. Steady playback with the phase
    lock keeps it inside one tick at the lattice centres (25p on 60 Hz: `1.6…15.0 ms`, `spread 0.80 ticks`).
  - `near tick edge`, `edge frames … with N side flips` — frames picked within 1–1.5 ms of a vsync, and how often
    such a frame landed on the other side of it than the one before: flips are frames jumping a tick.
  - `render call max` — time spent rendering or enqueueing on the display-link thread.
  - `GPU done after vsync N/M, min margin` — Metal mode only: frames the GPU finished after their target vsync.
- **`Display clock restarted from the raw clock at …s: …`** — the smoothed clock took a discontinuity: a seek or
  clock jump (with its size), a rate change, or a gap in link ticks.
- **`Frame held … ms (N ticks, cadence C) …`** — a frame stayed up two ticks or more past its cadence while the
  clock ran. The counters tell the cause apart: few callbacks and a large `max gap` — the link stopped calling;
  large `max tick` or `max clock read` — the tick was blocked on our side; `queue empty in` — no decoded frames.
