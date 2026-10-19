# <img src="docs/logo.svg" width="40" height="40" valign="bottom" /> Nits

A video player for macOS built on VideoToolbox, Metal and FFmpeg.

> [!NOTE]
> Pre-1.0: the `NitsKit` / `NitsCore` API may change between minor versions.

## Roadmap

**Video & HDR**
- [x] Codecs: AV1, VP9, HEVC, H.264
- [x] Legacy codecs: WMV/VC-1, MPEG-1/2, MPEG-4 Part 2 (DivX/Xvid), MS-MPEG4, H.263, Sorenson Spark, VP6, VP8, Theora, RealVideo, Motion JPEG, DV, Cinepak and any other video codec FFmpeg decodes
- [x] HDR output on Apple XDR displays, custom tone mapping to SDR on standard screens

**Dolby Vision**
- [x] Profile 5 and Profile 8 (8.1, 8.4) playback
- [x] Dynamic metadata (RPU L1 & L2) with scene-adaptive tone mapping

**Audio & subtitles**
- [x] Audio: multichannel 5.1/7.1, Spatial Audio, track switching, audio-only playback
- [x] Subtitles: embedded and external SRT / WebVTT with customizable styling; subtitle files next to the video are picked up automatically

**Player & system**
- [x] Keyboard shortcuts, OSD, frame stepping, quick settings, playlists, customizable control bar
- [x] macOS integration: Now Playing media keys, Control Center, sleep prevention
- [x] Network streaming over HTTP/HTTPS with custom headers
- [x] Playback history: resume where you left off
- [x] Media server client hooks: skip intro / next episode buttons, Up Next cards, host-driven episode queue

**Next**
- [ ] Styled ASS/SSA subtitles
- [ ] Bitmap subtitles (PGS / VOBSUB)
- [x] Audio sync delay adjustment
- [x] Subtitle sync delay adjustment
- [ ] Apple ProRes support
- [x] Timeline thumbnails
- [x] Timeline chapters
- [x] Picture-in-Picture
- [ ] Embedding in web clients (embeddable canvas and engine API; the JS bridge lives in the host)
- [x] Standalone app bundle with embedded FFmpeg

Details: [docs/ROADMAP.md](docs/ROADMAP.md).

## API Usage

Add `Nits` to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../nits") // or git repository URL
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "NitsKit", package: "nits")
        ]
    )
]
```

### High-level Window API (`NitsKit`)

#### Opening media

```swift
import NitsKit

let controller = PlayerWindowController()

// Stream remote media with custom auth headers, title, poster, and start time:
controller.openStream(
    url: URL(string: "https://media.server/stream.mkv")!,
    title: "Movie Title", // Optional; falls back to URL filename/host
    artworkURL: URL(string: "https://media.server/poster.jpg"), // Optional; displayed in Now Playing / Control Center
    headers: ["Authorization": "Bearer secret_token"],
    startTime: 120.0,     // Optional; overrides local resume history (0 starts from the beginning)
    audioTrack: "jpn",    // Optional; track id, "stream:N" (container stream index), or language/title; overrides history
    subtitleTrack: "eng"  // Optional; track id, "stream:N", language/title, or "off"/"none"; overrides history
)

// Open local media file (automatically extracts embedded cover art or accepts explicit artwork):
controller.openFile(
    url: fileURL,
    title: "Movie Title", // Optional; defaults to file name
    artworkData: nil, // Optional; falls back to embedded file artwork (MP4 covr / MKV attachment / ID3)
    startTime: nil // Pass nil to automatically resume from saved position (if enabled)
)
```

#### Events

```swift
controller.onTimeUpdate = { currentTime, duration in
    // Called periodically (every ~0.1s during active playback)
}

controller.onPlaybackStateChanged = { state in
    // .idle, .loading, .playing, .paused, .completed, .failed(String)
}

controller.onPlaybackEnded = {
    // Media finished playing to the end
}

controller.onClose = { finalTime, duration in
    // Window was closed by user; provides final playback time and duration before stop()
}
```

#### Media server clients

A host that plays episodes from its own server (Emby, Jellyfin, Plex) keeps the series, the markers and the queue;
Nits shows the controls and reports what the user did. Everything below is per load: each `openStream` replaces the
previous media's buttons and navigation, so pass them with it or set them once known. The types come from the
modules under `NitsKit`: `PlaybackActionButton` and `TrackNavigation` from `NitsCore`, `ControlsConfiguration` from
`NitsUI`.

Action buttons ("Skip Intro", "Next Episode") for spans of the timeline. The host decides where they go (e.g. from
its media server's intro / credits markers) and what they do. A button with a subtitle or artwork shows as an
"Up Next" card:

```swift
import NitsCore
import NitsKit
import NitsUI

controller.setActionButtons([
    PlaybackActionButton(id: "intro", title: "Skip Intro", start: 12, end: 72.5),
    PlaybackActionButton(
        id: "next", title: "Next Episode", start: 2666.5, // end: nil = to the end
        allowsAutoPress: false,                            // see below
        subtitle: "S2 · E5 · The Episode Name",            // Optional; makes it a card
        artworkURL: thumbnailURL),                         // Optional, 16:9; fetched without headers
])
controller.onActionButton = { id in
    if id == "intro" { controller.engine.seek(to: 72.5) } else { /* open the next episode */ }
}
```

The user picks how long a button stays up and whether it presses itself (Settings → General → Action Buttons).
Auto-press is meant for buttons like "Skip Intro"; pass `allowsAutoPress: false` for "Next Episode" unless cutting
the credits short is wanted.

Next / Previous from the host's queue. Setting `onTrackNavigation` makes the control bar, the Playback menu
(`⌘→` / `⌘←`), media keys and Control Center call the host instead of Nits' playlist; the host answers by opening
the item it moves to:

```swift
controller.onTrackNavigation = { direction in   // .next / .previous
    /* open the next or previous episode with openStream(...) */
}

controller.openStream(
    url: episodeURL,
    trackNavigation: TrackNavigation(hasNext: true, hasPrevious: true, nextTitle: "S2 · E6 · …"))

// Or later, once the host knows the next episode:
controller.setTrackNavigation(TrackNavigation(hasNext: true, hasPrevious: true, nextTitle: "S2 · E6 · …"))
```

- After calling the host, Next (or Previous) stays off until the next load, so repeated presses don't skip several
  episodes.
- Previous restarts the episode when it has played past 3 s or there's no previous one.
- With `onTrackNavigation` set the end of the media is left to the host: Nits doesn't repeat or advance, and
  `onPlaybackEnded` is the signal to auto-play the next episode.

Controls the host doesn't offer, set once at launch (not saved; the user's control bar layout is kept):

```swift
ControlsConfiguration.shared.unavailableItems = [.playlist, .playlistRepeat, .playlistShuffle]
```

They leave the control bar and the Controls settings. Without `.playlist` the side panel shows chapters only.

### Logging

Player logs go through `AppLog`, which writes to `os.Logger` and to `~/Library/Application Support/Nits/player.log`. A host app can use it too:

```swift
AppLog.info(.host, "Session started")
LogViewerWindowController.shared.showLogs() // or ⌥⌘L
```

Details: [docs/LOGGING.md](docs/LOGGING.md).

### Low-level Rendering Engine (`NitsCore`)

```swift
import NitsCore

let engine = PlayerEngine()

// Async loading for network streams:
await engine.loadAsync(
    MediaLoadRequest(
        path: "https://media.server/stream.mkv",
        headers: ["X-Api-Key": "my-key"],
        startTime: 300.0
    ))

// Events for a host UI (e.g. forwarded to a web view by the host's own bridge):
engine.onTracksChanged = {
    // engine.audioTracks, engine.subtitleTracks, engine.selectedAudioTrackId, engine.selectedSubtitleTrackId
}
engine.onBufferingChanged = { isBuffering in
    // Playback is held for data; playbackState stays .playing
}
engine.onTimeUpdate = { currentTime, duration in
    // engine.bufferedTime: how far media has been read ahead
}
```

## Command-Line Options

Arguments work with `swift run`, the bundle script, and `open --args`:

```bash
swift run Nits --no-osd ~/Movies/sample.mkv
./scripts/bundle_app.sh --run --render-mode=system --audio-track=jpn ~/Movies/movie.mkv
open build/Nits.app --args --start-time=120 ~/Movies/movie.mkv
```

| Option | Description |
| --- | --- |
| `[path or URL]` | Local file or `http(s)://` stream |
| `--no-osd` | Hide the OSD |
| `--osd-duration=<sec>` | How long OSD notifications stay visible (default 1.3) |
| `--debug-osd` | Mirror log messages to the OSD |
| `--debug-osd-level=debug\|info\|notice\|warning\|error` | Minimum level shown by the debug OSD (default warning) |
| `--debug-osd-duration=<sec>` | How long each debug OSD message stays visible (default 4) |
| `--render-mode=auto\|system\|metal` | Initial render mode |
| `--no-tone-mapping` | Disable SDR tone mapping |
| `--sharpness=0.0–1.0` | Sharpening strength (default 0.5) |
| `--dovi-trims` / `--no-dovi-trims` | Apply Dolby Vision L2 trims in SDR tone mapping (default off) |
| `--volume=0.0–1.0` | Initial volume |
| `--start-time=<sec>` | Start at a given position, ignoring history (`0` starts from the beginning) |
| `--no-resume` | Don't restore the saved position |
| `--audio-track=<id\|name>` | Pick audio track |
| `--subtitle-track=<id\|name\|off>` | Pick subtitle track |
| `--header="Key: Value"` | Custom HTTP header |

## Requirements

- macOS 15+
- Apple Silicon
- FFmpeg: the app bundle ships its own LGPL build (`scripts/setup_dependencies.sh`); plain
  `swift build` / `swift test` fall back to Homebrew (`brew install ffmpeg`), which also provides
  the `ffmpeg` CLI used to generate test media

## Building

```bash
swift build -c release
```

Build a signed `.app` bundle with embedded FFmpeg / dav1d and launch it:

```bash
./scripts/bundle_app.sh --run
```

To build and test against the same LGPL libraries that ship in the bundle:

```bash
./scripts/setup_dependencies.sh
export PKG_CONFIG_PATH="$PWD/.build/dependencies/lib/pkgconfig"
```

Tests and formatting check (`format.sh` picks up `.build/dependencies` automatically):

```bash
swift test
./scripts/format.sh check
```

## License

[MIT](LICENSE)

Bundled FFmpeg (LGPL-2.1+) and dav1d (BSD-2-Clause), and the mpv-derived tone-mapping shader
(LGPL-2.1+), keep their own licenses — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
