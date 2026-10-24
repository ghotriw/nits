#!/usr/bin/env bash
set -euo pipefail

# Find swift-format (prefers toolchain / xcrun)
SWIFT_FORMAT_BIN="$(xcrun --find swift-format 2>/dev/null || which swift-format 2>/dev/null || true)"

if [[ -z "$SWIFT_FORMAT_BIN" ]]; then
    echo "Error: swift-format not found. Please install Xcode or run 'brew install swift-format'." >&2
    exit 1
fi

MODE="${1:-format}"

# Build and test against the bundled LGPL FFmpeg (scripts/setup_dependencies.sh) when present,
# so checks cover what ships instead of Homebrew's build.
DEPS_PKGCONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/dependencies/lib/pkgconfig"
if [[ -d "$DEPS_PKGCONFIG" ]]; then
    export PKG_CONFIG_PATH="$DEPS_PKGCONFIG:${PKG_CONFIG_PATH:-}"
fi
TARGETS=("Sources" "Tests")

# Filter existing directories
VALID_TARGETS=()
for t in "${TARGETS[@]}"; do
    if [[ -d "$t" ]]; then
        VALID_TARGETS+=("$t")
    fi
done

# NitsCore stays portable across Apple platforms: UI frameworks, IOKit, the CoreAudio HAL and their types go only
# in Sources/NitsCore/Platform/<os>/ (see "Layer boundaries" in AGENTS.md). Nothing builds NitsCore for another
# platform yet, so the compiler would not catch a leak. Besides imports and UI types it lists the one-platform
# members of shared frameworks that NitsCore has used; comment-only lines don't count.
check_platform_boundary() {
    local imports='^\s*(@preconcurrency )?import (AppKit|Cocoa|UIKit|IOKit|CoreAudio)\b'
    local appkit='\bNS(App|Application|Bitmap[A-Za-z]*|Color|Cursor|Event|Font|GraphicsContext|Image|Menu[A-Za-z]*|Pasteboard|Responder|Screen|View|Window|Workspace)\b'
    local uikit='\bUI(Application|Color|Device|Font|Image|Screen|View|Window)\b'
    local members='\bAudioObject[A-Za-z]*\(|\bCVDisplayLink|\bCGDisplay|\bCGMainDisplayID\b|\baudioOutputDeviceUniqueID\b|\bdisplaySyncEnabled\b'
    local leaks
    # grep prints path:line:text, so the path filter stops at the first ':' and the comment filter reads the text.
    leaks="$(grep -rnE "$imports|$appkit|$uikit|$members" Sources/NitsCore --include='*.swift' \
        | grep -vE '^Sources/NitsCore/Platform/[^/:]+/' | grep -vE '^[^:]+:[0-9]+:\s*//' || true)"
    if [[ -n "$leaks" ]]; then
        echo "Platform-specific code outside Sources/NitsCore/Platform/<os>/:" >&2
        echo "$leaks" >&2
        return 1
    fi
}

case "$MODE" in
    format|--format|-f)
        echo "Formatting Swift code..."
        "$SWIFT_FORMAT_BIN" format --in-place --recursive "${VALID_TARGETS[@]}"
        echo "Done formatting."
        ;;
    lint|--lint|-l)
        echo "Checking Swift code style..."
        "$SWIFT_FORMAT_BIN" lint --recursive --strict "${VALID_TARGETS[@]}"
        check_platform_boundary
        echo "Lint check passed."
        ;;
    typecheck|--typecheck|-t)
        echo "Type-checking and building Swift targets (strict concurrency)..."
        swift build --build-tests -Xswiftc -strict-concurrency=complete --disable-sandbox
        echo "Type-check passed."
        ;;
    check|--check|-c)
        echo "1. Checking Swift code style..."
        "$SWIFT_FORMAT_BIN" lint --recursive --strict "${VALID_TARGETS[@]}"
        check_platform_boundary
        echo "2. Type-checking targets with strict concurrency..."
        swift build --build-tests -Xswiftc -strict-concurrency=complete --disable-sandbox
        echo "3. Running test suite..."
        swift test --disable-sandbox
        echo "All checks passed! CI ready."
        ;;
    *)
        echo "Usage: $0 [format|lint|typecheck|check]"
        exit 1
        ;;
esac
