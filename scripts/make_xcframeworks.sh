#!/usr/bin/env bash
# Wraps the iOS and iOS Simulator FFmpeg / dav1d prefixes (build_dependencies.sh --platform=ios|ios-simulator) into one
# dynamic xcframework per library, named like the library (`libavformat.xcframework` holds `libavformat.framework`), so a
# C shim's `#include <libavformat/avformat.h>` resolves through the framework, and so do FFmpeg's own `<libavutil/…>`.
#
# With --zip also one zip per xcframework (`<lib>.xcframework.zip`, the release assets Package.swift downloads) and the
# checksums to paste into Package.swift.
#
# Usage: make_xcframeworks.sh [--out=DIR] [--zip]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deps_config.sh
source "$DIR/scripts/deps_config.sh"

OUT_DIR="$DIR/.build/ios-frameworks"
ZIP=false
for arg in "$@"; do
    case "$arg" in
        --out=*) OUT_DIR="${arg#*=}" ;;
        --zip) ZIP=true ;;
        -h | --help) echo "Usage: $0 [--out=DIR] [--zip]"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

PLATFORMS=(ios ios-simulator)
WORK_DIR="$DIR/.build/ios-frameworks-work"
LIBS=()
for file in "${DEPS_IOS_REQUIRED_LIBS[@]}"; do
    LIBS+=("${file%%.*}") # libavformat.63.dylib -> libavformat
done

for platform in "${PLATFORMS[@]}"; do
    deps_ios_verify "$DIR/.build/dependencies-$platform" "$platform"
done

rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

# $1 prefix, $2 platform, $3 library
make_framework() {
    local prefix="$1" platform="$2" lib="$3"
    local fw="$WORK_DIR/$platform/$lib.framework" real dep dep_base args=() sdk_name
    case "$platform" in ios) sdk_name=iPhoneOS ;; *) sdk_name=iPhoneSimulator ;; esac
    mkdir -p "$fw/Headers"
    real="$(ls "$prefix"/lib/"$lib".*.dylib | grep -v -E "$lib\.[0-9]+\.[0-9]+\.[0-9]+\.dylib" | head -1)"
    cp -L "$real" "$fw/$lib"
    args+=(-id "@rpath/$lib.framework/$lib")
    # Libraries refer to each other by absolute prefix paths: point them at the sibling frameworks.
    while read -r dep; do
        dep_base="$(basename "$dep")"
        case "$dep" in
            "$prefix"/lib/*) args+=(-change "$dep" "@rpath/${dep_base%%.*}.framework/${dep_base%%.*}") ;;
        esac
    done < <(otool -L "$fw/$lib" | tail -n +3 | awk '{print $1}')
    deps_install_name_tool "${args[@]}" "$fw/$lib"
    # Headers sit flat: `<lib/header.h>` is framework-style, `Headers/header.h`. FFmpeg's own includes are `libX/…`.
    local include_dir="$prefix/include/${lib/#lib/}"
    case "$lib" in
        libdav1d) include_dir="$prefix/include/dav1d" ;;
        *) include_dir="$prefix/include/$lib" ;;
    esac
    cp "$include_dir"/*.h "$fw/Headers/"
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$lib</string>
    <key>CFBundleIdentifier</key><string>com.nits.deps.$lib</string>
    <key>CFBundleName</key><string>$lib</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$DEPS_IOS_VERSION</string>
    <key>CFBundleVersion</key><string>$DEPS_IOS_VERSION</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$sdk_name</string></array>
    <key>MinimumOSVersion</key><string>$DEPS_MIN_IOS</string>
</dict>
</plist>
PLIST
    codesign --force -s - "$fw"
}

for lib in "${LIBS[@]}"; do
    echo "==> $lib.xcframework"
    xc_args=()
    for platform in "${PLATFORMS[@]}"; do
        make_framework "$DIR/.build/dependencies-$platform" "$platform" "$lib"
        xc_args+=(-framework "$WORK_DIR/$platform/$lib.framework")
    done
    xcodebuild -create-xcframework "${xc_args[@]}" -output "$OUT_DIR/$lib.xcframework" >/dev/null
done

# License notices travel with the frameworks (the app bundle ships them).
mkdir -p "$OUT_DIR/licenses"
cp -R "$DIR/.build/dependencies-ios/share/licenses/." "$OUT_DIR/licenses/"
rm -rf "$WORK_DIR"

if [ "$ZIP" = true ]; then
    ZIP_DIR="$DIR/.build/dist/ios"
    rm -rf "$ZIP_DIR"
    mkdir -p "$ZIP_DIR"
    echo "==> Release assets in $ZIP_DIR (upload to $DEPS_IOS_RELEASE_URL):"
    for lib in "${LIBS[@]}"; do
        # ditto keeps the bundles' symlinks and permissions; the zip holds the xcframework at its top level.
        ditto -c -k --keepParent "$OUT_DIR/$lib.xcframework" "$ZIP_DIR/$lib.xcframework.zip"
        echo "    .binaryTarget(name: \"$lib\", url: \"$DEPS_IOS_RELEASE_URL/$lib.xcframework.zip\"," \
            "checksum: \"$(swift package compute-checksum "$ZIP_DIR/$lib.xcframework.zip")\"),"
    done | tee "$ZIP_DIR/Package-snippet.txt"
    ditto -c -k --keepParent "$OUT_DIR/licenses" "$ZIP_DIR/licenses.zip"
    # The sources the libraries were built from, byte-identical, for the LGPL source offer.
    cp "$DIR/.build/src/ffmpeg-$FFMPEG_VERSION.tar.xz" "$DIR/.build/src/dav1d-$DAV1D_VERSION.tar.bz2" "$ZIP_DIR/"
fi
echo "==> xcframeworks in $OUT_DIR"
