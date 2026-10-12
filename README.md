# <img src="docs/logo.svg" width="40" height="40" valign="bottom" /> Nits

A video player for macOS built on VideoToolbox, AVSampleBufferDisplayLayer, and Metal.

> [!NOTE]
> **Status: alpha.** Core playback, HDR tone mapping, audio pipeline, and text subtitles (SRT, WebVTT, embedded SubRip) are implemented.

## Roadmap

- [x] Rendering: Apple HDR passthrough and Metal BT.2390 EETF tone mapping
- [x] Video: HEVC 10-bit, H.264 8/10-bit, Dolby Vision Profile 5, HLG
- [x] Audio: master clock sync, multiple PCM tracks, Spatial Audio, 5.1/7.1
- [x] Diagnostics overlay: CPU/RAM, A/V drift, queue levels
- [x] Desktop UX: keyboard shortcuts, OSD, double-click fullscreen, cursor auto-hide
- [x] Now Playing & system media controls.
- [x] HTTP/HTTPS streaming with custom auth headers
- [x] Resume playback & start time position control (Watch Later)
- [x] Subtitles: embedded SubRip/MKV/MP4 & external SRT/WebVTT with styling & alignment
- [ ] Subtitles: advanced stylized ASS/SSA typesetting (`libass`) & bitmap formats (PGS/VOBSUB)
- [x] Dolby Vision: Profile 8 (8.1, 8.4) playback
- [x] Dolby Vision: dynamic metadata (RPU L1 and L2) scene-adaptive tone mapping
- [x] AV1 (`dav1d` on M1/M2)
- [ ] AV1 (VideoToolbox on M3 and later)
- [x] Playlist management
- [ ] Embedding the video view in a WKWebView-based client
- [ ] Bundling FFmpeg dylibs into the app

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

```swift
import NitsKit

let controller = PlayerWindowController()

// Stream remote media with custom auth headers, title, poster, and start time:
controller.openStream(
    url: URL(string: "https://media.server/stream.mkv")!,
    title: "Movie Title", // Optional; falls back to URL filename/host
    artworkURL: URL(string: "https://media.server/poster.jpg"), // Optional; displayed in Now Playing / Control Center
    headers: ["Authorization": "Bearer secret_token"],
    startTime: 120.0,     // Optional; overrides local resume history
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

// Observability and Event Callbacks:
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

### Logging

Player logs go through `AppLog`, which writes to `os.Logger` and to `~/Library/Application Support/Nits/player.log`. A host app can use it too:

```swift
AppLog.info(.host, "Session started")
LogViewerWindowController.shared.show() // or ⌥⌘L
```

Details: [docs/LOGGING.md](docs/LOGGING.md).

### Low-level Rendering Engine (`NitsCore`)

```swift
import NitsCore

let engine = PlayerEngine()

// Async loading for network streams:
await engine.loadAsync(
    path: "https://media.server/stream.mkv",
    headers: ["X-Api-Key": "my-key"],
    startTime: 300.0
)
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
| `--render-mode=auto\|system\|metal` | Initial render mode |
| `--no-tone-mapping` | Disable SDR tone mapping |
| `--sharpness=0.0–1.0` | Sharpening strength (default 0.5) |
| `--volume=0.0–1.0` | Initial volume |
| `--start-time=<sec>` | Start at a given position, ignoring history |
| `--no-resume` | Don't restore the saved position |
| `--audio-track=<id\|name>` | Pick audio track |
| `--subtitle-track=<id\|name\|off>` | Pick subtitle track |
| `--header="Key: Value"` | Custom HTTP header |

## Requirements

- macOS 15+
- Apple Silicon
- FFmpeg shared libraries (`brew install ffmpeg`)

## Building

```bash
swift build -c release
```

Build a signed `.app` bundle and launch it:

```bash
./scripts/bundle_app.sh --run
```

Tests and formatting check:

```bash
swift test
./scripts/format.sh check
```

## License

[MIT](LICENSE)
