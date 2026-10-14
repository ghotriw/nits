#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deps_config.sh
source "$DIR/scripts/deps_config.sh"

PREFIX="${PREFIX:-$DIR/.build/dependencies}"
DIST_DIR="$DIR/.build/dist"
TAR_FILE="$DIST_DIR/$DEPS_ARCHIVE_NAME"

USAGE="Usage: $0 [--from-source] [--verify] [--prefix=/path/to/prefix]"
FROM_SOURCE=false
VERIFY_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --from-source) FROM_SOURCE=true ;;
        --verify) VERIFY_ONLY=true ;;
        --prefix=*) PREFIX="${arg#*=}" ;;
        -h|--help) echo "$USAGE"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; echo "$USAGE" >&2; exit 1 ;;
    esac
done

if [ "$VERIFY_ONLY" = true ]; then
    deps_verify "$PREFIX"
    echo "==> Dependencies in $PREFIX are valid ($DEPS_STAMP)"
    exit 0
fi

finish() {
    deps_relocate "$PREFIX"
    deps_verify "$PREFIX"
    echo "==> Dependencies ready in $PREFIX ($DEPS_STAMP)"
    exit 0
}

build_from_source() {
    "$DIR/scripts/build_dependencies.sh" --prefix="$PREFIX"
    finish
}

install_archive() {
    deps_clean_prefix "$PREFIX" "$DIR"
    mkdir -p "$PREFIX"
    tar -xzf "$1" -C "$PREFIX"
}

if [ "$FROM_SOURCE" = true ]; then
    echo "==> Building dependencies from source as requested..."
    build_from_source
fi

# Up to date: just make sure install names still point at this prefix (repo may have moved).
if deps_verify "$PREFIX" 2>/dev/null; then
    finish
fi

# Locally packaged archive (build_dependencies.sh --package): trusted, but must match the stamp.
if [ -f "$TAR_FILE" ]; then
    echo "==> Installing local package $TAR_FILE..."
    install_archive "$TAR_FILE"
    if deps_stamp_matches "$PREFIX"; then
        finish
    fi
    echo "==> Local package is stale, ignoring it"
fi

if [ -z "$DEPS_ARCHIVE_SHA256" ]; then
    echo "==> No published checksum for deps v$DEPS_VERSION; building from source..."
    build_from_source
fi

echo "==> Downloading prebuilt dependencies v$DEPS_VERSION..."
mkdir -p "$DIST_DIR"
DOWNLOAD="$TAR_FILE.download"
if ! curl -fsSL -o "$DOWNLOAD" "$DEPS_RELEASE_URL"; then
    rm -f "$DOWNLOAD"
    echo "==> Download failed; building from source..."
    build_from_source
fi

ACTUAL_SHA256="$(shasum -a 256 "$DOWNLOAD" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$DEPS_ARCHIVE_SHA256" ]; then
    rm -f "$DOWNLOAD"
    echo "Error: checksum mismatch for $DEPS_RELEASE_URL" >&2
    echo "  expected $DEPS_ARCHIVE_SHA256" >&2
    echo "  actual   $ACTUAL_SHA256" >&2
    echo "Re-run with --from-source to build locally." >&2
    exit 1
fi
echo "==> Checksum verified"
mv "$DOWNLOAD" "$TAR_FILE"
install_archive "$TAR_FILE"
finish
