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
echo "==> 1/7 Building dav1d $DAV1D_VERSION (macOS $DEPS_MIN_MACOS, $DEPS_ARCH)..."
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
echo "==> 2/7 Building FFmpeg $FFMPEG_VERSION (LGPL, macOS $DEPS_MIN_MACOS, $DEPS_ARCH)..."
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

# 3-7. libass and what it needs for text layout: FreeType, HarfBuzz, FriBidi, libunibreak. Built after FFmpeg, which
# doesn't link them. Text is shaped and rasterized by libass (ISC); fonts come from Core Text, so no Fontconfig.
# pkg-config sees only this prefix, or an optional library of the machine (glib, icu, png) would sneak in.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

fetch_source() { # name, version, archive suffix, url
    local archive="$1-$2.$3"
    cd "$SRC_DIR"
    if [ ! -f "$archive" ]; then
        curl -fsSL -o "$archive" "$4"
    fi
    rm -rf "$1-$2"
    tar -xf "$archive"
    cd "$1-$2"
}

echo "==> 3/7 Building FreeType $FREETYPE_VERSION..."
fetch_source freetype "$FREETYPE_VERSION" tar.xz \
    "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz"
meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    --default-library=shared \
    --buildtype=release \
    -Dc_args="$COMMON_CFLAGS" \
    -Dc_link_args="$COMMON_LDFLAGS" \
    -Dbrotli=disabled \
    -Dbzip2=disabled \
    -Dharfbuzz=disabled \
    -Dpng=disabled \
    -Dzlib=system \
    -Dtests=disabled
ninja -C build install

echo "==> 4/7 Building HarfBuzz $HARFBUZZ_VERSION..."
fetch_source harfbuzz "$HARFBUZZ_VERSION" tar.xz \
    "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz"
meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    --default-library=shared \
    --buildtype=release \
    -Dc_args="$COMMON_CFLAGS" \
    -Dc_link_args="$COMMON_LDFLAGS" \
    -Dcpp_args="$COMMON_CFLAGS" \
    -Dcpp_link_args="$COMMON_LDFLAGS" \
    -Dfreetype=enabled \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dcairo=disabled \
    -Dchafa=disabled \
    -Dicu=disabled \
    -Dgraphite=disabled \
    -Dcoretext=disabled \
    -Dsubset=disabled \
    -Draster=disabled \
    -Dvector=disabled \
    -Dgpu=disabled \
    -Dtests=disabled \
    -Dintrospection=disabled \
    -Ddocs=disabled \
    -Dutilities=disabled \
    -Dbenchmark=disabled
ninja -C build install

echo "==> 5/7 Building FriBidi $FRIBIDI_VERSION..."
fetch_source fribidi "$FRIBIDI_VERSION" tar.xz \
    "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz"
meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    --default-library=shared \
    --buildtype=release \
    -Dc_args="$COMMON_CFLAGS" \
    -Dc_link_args="$COMMON_LDFLAGS" \
    -Ddocs=false \
    -Dbin=false \
    -Dtests=false
ninja -C build install

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "==> 6/7 Building libunibreak $LIBUNIBREAK_VERSION..."
fetch_source libunibreak "$LIBUNIBREAK_VERSION" tar.gz \
    "https://github.com/adah1972/libunibreak/releases/download/libunibreak_${LIBUNIBREAK_VERSION//./_}/libunibreak-$LIBUNIBREAK_VERSION.tar.gz"
./configure --prefix="$PREFIX" --enable-shared --disable-static \
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS"
make -j"$NCPU"
make install

echo "==> 7/7 Building libass $LIBASS_VERSION..."
fetch_source libass "$LIBASS_VERSION" tar.xz \
    "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz"
./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-fontconfig --disable-test \
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS"
make -j"$NCPU"
make install

# License notices and build provenance, shipped in Nits.app/Contents/Resources/ThirdPartyLicenses
LICENSES_DIR="$PREFIX/share/licenses"
mkdir -p "$LICENSES_DIR/ffmpeg" "$LICENSES_DIR/dav1d" "$LICENSES_DIR/libass" "$LICENSES_DIR/freetype" \
    "$LICENSES_DIR/harfbuzz" "$LICENSES_DIR/fribidi" "$LICENSES_DIR/libunibreak"
cp "$SRC_DIR/ffmpeg-$FFMPEG_VERSION/LICENSE.md" "$SRC_DIR/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" \
    "$LICENSES_DIR/ffmpeg/"
cp "$SRC_DIR/dav1d-$DAV1D_VERSION/COPYING" "$LICENSES_DIR/dav1d/"
cp "$SRC_DIR/libass-$LIBASS_VERSION/COPYING" "$LICENSES_DIR/libass/"
cp "$SRC_DIR/freetype-$FREETYPE_VERSION/LICENSE.TXT" "$SRC_DIR/freetype-$FREETYPE_VERSION/docs/FTL.TXT" \
    "$LICENSES_DIR/freetype/"
cp "$SRC_DIR/harfbuzz-$HARFBUZZ_VERSION/COPYING" "$LICENSES_DIR/harfbuzz/"
cp "$SRC_DIR/fribidi-$FRIBIDI_VERSION/COPYING" "$LICENSES_DIR/fribidi/"
cp "$SRC_DIR/libunibreak-$LIBUNIBREAK_VERSION/LICENCE" "$LICENSES_DIR/libunibreak/"
{
    echo "Nits bundles unmodified FFmpeg, dav1d, libass, FreeType, HarfBuzz, FriBidi and libunibreak as dynamic libraries in Contents/Frameworks."
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
    echo "libass $LIBASS_VERSION — ISC License"
    echo "  Source: https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz"
    echo
    echo "FreeType $FREETYPE_VERSION — FreeType License (FTL); portions of the sources are BSD-licensed"
    echo "  Source: https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz"
    echo
    echo "HarfBuzz $HARFBUZZ_VERSION — \"Old MIT\" License"
    echo "  Source: https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz"
    echo
    echo "FriBidi $FRIBIDI_VERSION — GNU Lesser General Public License v2.1 or later"
    echo "  Source: https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz"
    echo
    echo "libunibreak $LIBUNIBREAK_VERSION — zlib License"
    echo "  Source: https://github.com/adah1972/libunibreak/releases/download/libunibreak_${LIBUNIBREAK_VERSION//./_}/libunibreak-$LIBUNIBREAK_VERSION.tar.gz"
    echo
    echo "Build: ./scripts/build_dependencies.sh in https://github.com/ghotriw/nits"
    echo "The source archives, byte-identical to the ones built, are attached to the release:"
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
