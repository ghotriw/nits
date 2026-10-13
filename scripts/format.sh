#!/usr/bin/env bash
set -euo pipefail

# Find swift-format (prefers toolchain / xcrun)
SWIFT_FORMAT_BIN="$(xcrun --find swift-format 2>/dev/null || which swift-format 2>/dev/null || true)"

if [[ -z "$SWIFT_FORMAT_BIN" ]]; then
    echo "Error: swift-format not found. Please install Xcode or run 'brew install swift-format'." >&2
    exit 1
fi

MODE="${1:-format}"
TARGETS=("Sources" "Tests")

# Filter existing directories
VALID_TARGETS=()
for t in "${TARGETS[@]}"; do
    if [[ -d "$t" ]]; then
        VALID_TARGETS+=("$t")
    fi
done

case "$MODE" in
    format|--format|-f)
        echo "Formatting Swift code..."
        "$SWIFT_FORMAT_BIN" format --in-place --recursive "${VALID_TARGETS[@]}"
        echo "Done formatting."
        ;;
    lint|--lint|-l)
        echo "Checking Swift code style..."
        "$SWIFT_FORMAT_BIN" lint --recursive --strict "${VALID_TARGETS[@]}"
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
