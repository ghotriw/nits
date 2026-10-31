#!/usr/bin/env bash
set -euo pipefail

# scripts/profile.sh - Automated Instruments profiling for Nits
# Records Time Profiler / App Launch traces on synthetic or custom media.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

DURATION=5
TEMPLATE="Time Profiler"
REBUILD=false
OPEN_GUI=false
CUSTOM_OUTPUT=""
TARGET_INPUT=""

SYNTH_DIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp/}")NitsSyntheticMedia"

usage() {
    cat <<EOF
Usage: $0 [options] [preset-or-filepath]

Presets:
  hevc_hdr       HEVC 10-bit HDR video (default)
  h264_60        H.264 60fps video
  subtitles      4K HDR with 5 subtitle tracks
  ass            MKV with ASS subtitles
  <filepath>     Path to any local video file or URL

Options:
  -d, --duration <sec>     Recording duration in seconds (default: 5)
  -t, --template <name>    Instruments template or .tracetemplate path (default: "Time Profiler")
  -o, --output <path>      Output .trace file path
  --rebuild                Force rebuilding Nits.app before recording
  -O, --open               Open the resulting trace in Instruments GUI immediately
  -h, --help               Show this help message

Examples:
  $0                                   # 5s Time Profiler on HEVC HDR synthetic media
  $0 subtitles -O                      # Profile subtitles and open trace in Instruments
  $0 -d 10 ~/Movies/sample.mkv         # Profile custom media file for 10 seconds
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        --duration=*)
            DURATION="${1#*=}"
            shift
            ;;
        -t|--template)
            TEMPLATE="$2"
            shift 2
            ;;
        --template=*)
            TEMPLATE="${1#*=}"
            shift
            ;;
        -o|--output)
            CUSTOM_OUTPUT="$2"
            shift 2
            ;;
        --output=*)
            CUSTOM_OUTPUT="${1#*=}"
            shift
            ;;
        --rebuild)
            REBUILD=true
            shift
            ;;
        -O|--open)
            OPEN_GUI=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            TARGET_INPUT="$1"
            shift
            ;;
    esac
done

APP_DIR="$DIR/build/Nits.app"
APP_BIN="$APP_DIR/Contents/MacOS/Nits"

# 1. Build app bundle if missing or rebuild requested
if [[ ! -x "$APP_BIN" || "$REBUILD" == true ]]; then
    echo "==> Building Nits.app in release configuration..."
    ./scripts/bundle_app.sh --release --no-dylibs
fi

if [[ ! -x "$APP_BIN" ]]; then
    echo "Error: Binary not found at $APP_BIN" >&2
    exit 1
fi

# 2. Resolve media target
MEDIA_PATH=""
TARGET_PRESET=""
case "$TARGET_INPUT" in
    hevc_hdr|"")
        TARGET_PRESET="hevc_hdr"
        MEDIA_PATH="$SYNTH_DIR/synth_hevc_10bit_hdr.mp4"
        ;;
    h264_60)
        TARGET_PRESET="h264_60"
        MEDIA_PATH="$SYNTH_DIR/synth_h264_60fps.mp4"
        ;;
    subtitles)
        TARGET_PRESET="subtitles"
        MEDIA_PATH="$SYNTH_DIR/synth_uhd_hdr_5subs.mkv"
        ;;
    ass)
        TARGET_PRESET="ass"
        MEDIA_PATH="$SYNTH_DIR/synth_ass_subtitles.mkv"
        ;;
    *)
        MEDIA_PATH="$TARGET_INPUT"
        ;;
esac

# If synthetic file is missing, attempt to synthesize the requested preset rather than silently substituting
if [[ ! -f "$MEDIA_PATH" && ! "$MEDIA_PATH" =~ ^https?:// ]]; then
    if [[ -n "$TARGET_PRESET" ]]; then
        echo "==> Synthetic preset '$TARGET_PRESET' not found in cache ($SYNTH_DIR)."
        echo "==> Generating synthetic test media via SyntheticMediaWarmupTests (this may take 1-2 minutes on first run)..."
        swift test --disable-sandbox --filter SyntheticMediaWarmupTests || true
    fi

    if [[ ! -f "$MEDIA_PATH" ]]; then
        echo "Error: Media file not found: $MEDIA_PATH" >&2
        if [[ -n "$TARGET_PRESET" ]]; then
            echo "Run 'swift test --filter SyntheticMediaWarmupTests' or verify FFmpeg installation to generate it." >&2
        fi
        exit 1
    fi
fi

# 3. Configure output path
mkdir -p "$DIR/tmp"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
SANITIZED_TEMPLATE="${TEMPLATE// /_}"
if [[ -n "$CUSTOM_OUTPUT" ]]; then
    OUTPUT_TRACE="$CUSTOM_OUTPUT"
else
    OUTPUT_TRACE="$DIR/tmp/profile_${SANITIZED_TEMPLATE}_${TIMESTAMP}.trace"
fi

# 4. Execute xctrace record
echo "============================================================"
echo " Starting Recording via Instruments (xctrace)"
echo " Template:  $TEMPLATE"
echo " Duration:  ${DURATION}s"
echo " Target:    $MEDIA_PATH"
echo " Output:    $OUTPUT_TRACE"
echo "============================================================"

set +e
xcrun xctrace record \
    --template "$TEMPLATE" \
    --time-limit "${DURATION}s" \
    --output "$OUTPUT_TRACE" \
    --launch -- "$APP_BIN" "$MEDIA_PATH"
XCTRACE_STATUS=$?
set -e

# Exit code 54 is expected when recording stops by --time-limit
if [[ $XCTRACE_STATUS -ne 0 && $XCTRACE_STATUS -ne 54 ]]; then
    echo "Error: xctrace failed with exit code $XCTRACE_STATUS" >&2
    exit $XCTRACE_STATUS
fi

echo ""
echo "============================================================"
echo " Profiling Completed!"
echo " Trace saved: $OUTPUT_TRACE"
echo ""
echo " To inspect the results in Instruments GUI:"
echo "   open \"$OUTPUT_TRACE\""
echo "============================================================"

if [[ "$OPEN_GUI" == true ]]; then
    open "$OUTPUT_TRACE"
fi
