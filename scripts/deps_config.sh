# shellcheck shell=bash
# Shared configuration for the bundled LGPL FFmpeg / dav1d build.
# Sourced by build_dependencies.sh, setup_dependencies.sh and bundle_app.sh; must stay bash 3.2 compatible.
#
# Bump DEPS_VERSION whenever versions or configure flags change, run the "Build and Release
# Dependencies" workflow, then paste the SHA-256 it prints into DEPS_ARCHIVE_SHA256.

DEPS_VERSION="1.0.0"
FFMPEG_VERSION="9.0.2"
DAV1D_VERSION="1.5.0"
DEPS_ARCH="arm64"
DEPS_MIN_MACOS="15.0"

# SHA-256 of the release asset for DEPS_VERSION. Empty = not published yet: setup builds from source.
DEPS_ARCHIVE_SHA256="20710574bb5f579d788c7cd2e9790ce04f4391d4373cf92e793ce0110b7b704d"

DEPS_ARCHIVE_NAME="nits-deps-macos15-${DEPS_ARCH}-v${DEPS_VERSION}.tar.gz"
DEPS_RELEASE_URL="https://github.com/ghotriw/nits/releases/download/deps-v${DEPS_VERSION}/${DEPS_ARCHIVE_NAME}"

# Written into the prefix by build_dependencies.sh; a mismatch means the prefix is stale.
DEPS_STAMP_FILE=".nits-deps"
DEPS_STAMP="deps=${DEPS_VERSION} ffmpeg=${FFMPEG_VERSION} dav1d=${DAV1D_VERSION} arch=${DEPS_ARCH} minos=${DEPS_MIN_MACOS}"

DEPS_REQUIRED_LIBS=(
    "libavformat.63.dylib"
    "libavcodec.63.dylib"
    "libavutil.61.dylib"
    "libswresample.7.dylib"
    "libswscale.10.dylib"
    "libdav1d.7.dylib"
)

deps_stamp_matches() {
    [ -f "$1/$DEPS_STAMP_FILE" ] && [ "$(cat "$1/$DEPS_STAMP_FILE")" = "$DEPS_STAMP" ]
}

# Removes a prefix before a fresh install. Refuses anything that isn't a previous deps install or a
# directory under the repo's .build/, so a mistyped --prefix can't wipe e.g. /usr/local.
deps_clean_prefix() {
    local prefix="$1" repo_dir="$2"
    [ -e "$prefix" ] || return 0
    case "$prefix" in
        "$repo_dir/.build/"*) ;;
        *)
            if [ ! -f "$prefix/$DEPS_STAMP_FILE" ]; then
                echo "Error: refusing to clear $prefix (not a Nits dependencies prefix)" >&2
                return 1
            fi
            ;;
    esac
    rm -rf "$prefix"
}

# install_name_tool without the expected "will invalidate the code signature" warning (callers
# re-sign); real errors are still printed.
deps_install_name_tool() {
    local out
    if ! out="$(install_name_tool "$@" 2>&1)"; then
        echo "$out" >&2
        return 1
    fi
}

# Points every install name in $prefix/lib at $prefix/lib. Archives built elsewhere (CI) carry the
# build machine's absolute paths; this makes `swift build`/`swift test` and bundling work wherever the
# prefix is extracted or moved. Idempotent.
deps_relocate() {
    local lib_dir="$1/lib" dylib id dep dep_base
    for dylib in "$lib_dir"/*.dylib; do
        [ -f "$dylib" ] && [ ! -L "$dylib" ] || continue
        local args=()
        id="$(otool -D "$dylib" | tail -n +2)"
        if [ "$id" != "$lib_dir/$(basename "$id")" ]; then
            args+=(-id "$lib_dir/$(basename "$id")")
        fi
        while read -r dep; do
            dep_base="$(basename "$dep")"
            if [ -e "$lib_dir/$dep_base" ] && [ "$dep" != "$lib_dir/$dep_base" ]; then
                args+=(-change "$dep" "$lib_dir/$dep_base")
            fi
        done < <(otool -L "$dylib" | tail -n +3 | awk '{print $1}')
        if [ ${#args[@]} -gt 0 ]; then
            deps_install_name_tool "${args[@]}" "$dylib"
            codesign --force -s - "$dylib" 2>/dev/null
        fi
    done

    if [ -d "$lib_dir/pkgconfig" ]; then
        for pc in "$lib_dir/pkgconfig/"*.pc; do
            [ -f "$pc" ] && sed -i '' "s|^prefix=.*|prefix=$1|" "$pc"
        done
    fi
}

deps_minos() {
    otool -l "$1" 2>/dev/null | grep -A 4 LC_BUILD_VERSION | awk '/minos/ {print $2; exit}'
}

deps_verify() {
    local prefix="$1" lib lib_path minos
    if ! deps_stamp_matches "$prefix"; then
        echo "Error: $prefix/$DEPS_STAMP_FILE doesn't match '$DEPS_STAMP'" >&2
        return 1
    fi
    for lib in "${DEPS_REQUIRED_LIBS[@]}"; do
        lib_path="$prefix/lib/$lib"
        if [ ! -f "$lib_path" ]; then
            echo "Error: required library $lib_path is missing" >&2
            return 1
        fi
        minos="$(deps_minos "$lib_path")"
        if [ "$minos" != "$DEPS_MIN_MACOS" ]; then
            echo "Error: $lib has minos '$minos' (expected $DEPS_MIN_MACOS)" >&2
            return 1
        fi
    done
}
