#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deps_config.sh
source "$DIR/scripts/deps_config.sh"

PREFIX="${PREFIX:-$DIR/.build/dependencies}"
SRC_DIR="$DIR/.build/src"
VENV_DIR="$DIR/.build/venv"
DIST_DIR="$DIR/.build/dist"

USAGE="Usage: $0 [--package] [--package-only] [--prefix=/path/to/prefix]"
BUILD=true
PACKAGE=false
for arg in "$@"; do
    case "$arg" in
        --package) PACKAGE=true ;;
        --package-only) PACKAGE=true; BUILD=false ;;
        --prefix=*) PREFIX="${arg#*=}" ;;
        -h|--help) echo "$USAGE"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; echo "$USAGE" >&2; exit 1 ;;
    esac
done

package_prefix() {
    deps_verify "$PREFIX"
    mkdir -p "$DIST_DIR"
    local tar_path="$DIST_DIR/$DEPS_ARCHIVE_NAME"
    echo "==> Packaging $PREFIX into $tar_path..."
    tar -czf "$tar_path" -C "$PREFIX" .
    (cd "$DIST_DIR" && shasum -a 256 "$DEPS_ARCHIVE_NAME" > "$DEPS_ARCHIVE_NAME.sha256")
    echo "==> SHA-256: $(awk '{print $1}' "$tar_path.sha256")"
}

if [ "$BUILD" = false ]; then
    package_prefix
    exit 0
fi

deps_clean_prefix "$PREFIX" "$DIR"
mkdir -p "$PREFIX" "$SRC_DIR"

echo "==> Ensuring build tools (meson, ninja, pkg-config)..."
if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
    if [ ! -f "$VENV_DIR/bin/meson" ] || [ ! -f "$VENV_DIR/bin/ninja" ]; then
        echo "==> Installing meson and ninja into $VENV_DIR..."
        python3 -m venv "$VENV_DIR"
        "$VENV_DIR/bin/pip" install --disable-pip-version-check meson ninja
    fi
    export PATH="$VENV_DIR/bin:$PATH"
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

COMMON_CFLAGS="-arch $DEPS_ARCH -mmacosx-version-min=$DEPS_MIN_MACOS -O3"
# Header padding lets setup_dependencies.sh / bundle_app.sh rewrite install names to longer paths.
COMMON_LDFLAGS="-arch $DEPS_ARCH -mmacosx-version-min=$DEPS_MIN_MACOS -Wl,-headerpad_max_install_names"

# 1. dav1d (BSD-2-Clause)
echo "==> 1/2 Building dav1d $DAV1D_VERSION (macOS $DEPS_MIN_MACOS, $DEPS_ARCH)..."
cd "$SRC_DIR"
if [ ! -f "dav1d-$DAV1D_VERSION.tar.bz2" ]; then
    curl -fsSL -o "dav1d-$DAV1D_VERSION.tar.bz2" \
        "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.bz2"
fi
rm -rf "dav1d-$DAV1D_VERSION"
tar -xjf "dav1d-$DAV1D_VERSION.tar.bz2"
cd "dav1d-$DAV1D_VERSION"

meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    --default-library=shared \
    --buildtype=release \
    -Dc_args="$COMMON_CFLAGS" \
    -Dc_link_args="$COMMON_LDFLAGS" \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false
ninja -C build install

# 2. FFmpeg (LGPL-2.1-or-later: no --enable-gpl, no --enable-version3)
echo "==> 2/2 Building FFmpeg $FFMPEG_VERSION (LGPL, macOS $DEPS_MIN_MACOS, $DEPS_ARCH)..."
cd "$SRC_DIR"
if [ ! -f "ffmpeg-$FFMPEG_VERSION.tar.xz" ]; then
    curl -fsSL -o "ffmpeg-$FFMPEG_VERSION.tar.xz" \
        "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
fi
rm -rf "ffmpeg-$FFMPEG_VERSION"
tar -xf "ffmpeg-$FFMPEG_VERSION.tar.xz"
cd "ffmpeg-$FFMPEG_VERSION"

FFMPEG_CONFIGURE_FLAGS=(
    --prefix="$PREFIX"
    --arch="$DEPS_ARCH"
    --target-os=darwin
    --cc=clang
    --enable-shared
    --disable-static
    --disable-programs
    --disable-doc
    --disable-encoders
    --disable-muxers
    --disable-gpl
    --disable-nonfree
    --enable-libdav1d
    --enable-audiotoolbox
    --enable-videotoolbox
    --enable-network
    --disable-xlib
    --disable-sdl2
    --disable-avdevice
    --disable-avfilter
    --extra-cflags="$COMMON_CFLAGS -I$PREFIX/include"
    --extra-ldflags="$COMMON_LDFLAGS -L$PREFIX/lib"
)
./configure "${FFMPEG_CONFIGURE_FLAGS[@]}"

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
make -j"$NCPU"
make install

# 3. License notices and build provenance, shipped in Nits.app/Contents/Resources/ThirdPartyLicenses
LICENSES_DIR="$PREFIX/share/licenses"
mkdir -p "$LICENSES_DIR/ffmpeg" "$LICENSES_DIR/dav1d"
cp "$SRC_DIR/ffmpeg-$FFMPEG_VERSION/LICENSE.md" "$SRC_DIR/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" \
    "$LICENSES_DIR/ffmpeg/"
cp "$SRC_DIR/dav1d-$DAV1D_VERSION/COPYING" "$LICENSES_DIR/dav1d/"
{
    echo "Nits bundles unmodified FFmpeg and dav1d as dynamic libraries in Contents/Frameworks."
    echo "You may replace them with your own builds of the same major versions."
    echo
    echo "FFmpeg $FFMPEG_VERSION — GNU Lesser General Public License v2.1 or later"
    echo "  Source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    echo "  Configure flags (paths elided):"
    for flag in "${FFMPEG_CONFIGURE_FLAGS[@]}"; do
        case "$flag" in --prefix=*|--extra-*) continue ;; esac
        echo "    $flag"
    done
    echo
    echo "dav1d $DAV1D_VERSION — BSD 2-Clause License"
    echo "  Source: https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.bz2"
    echo
    echo "Build: ./scripts/build_dependencies.sh in https://github.com/ghotriw/nits"
    echo "Both source archives, byte-identical to the ones built, are attached to the release:"
    echo "  https://github.com/ghotriw/nits/releases/tag/deps-v$DEPS_VERSION"
} > "$LICENSES_DIR/NOTICE.txt"

echo "$DEPS_STAMP" > "$PREFIX/$DEPS_STAMP_FILE"
deps_verify "$PREFIX"

echo "==> Dependencies built into $PREFIX:"
for dylib in "$PREFIX/lib/"*.dylib; do
    [ -f "$dylib" ] && [ ! -L "$dylib" ] || continue
    echo "    $(basename "$dylib") (minos: $(deps_minos "$dylib"))"
done

if [ "$PACKAGE" = true ]; then
    package_prefix
fi
