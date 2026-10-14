#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deps_config.sh
source "$DIR/scripts/deps_config.sh"
cd "$DIR"

CONFIG="release"
BUNDLE_DYLIBS=true
RUN_APP=false
RUN_ARGS=()
FROM_SOURCE=false
APP_VERSION=""

USAGE="Usage: $0 [--debug|--release] [--no-dylibs] [--from-source] [--version=X.Y.Z] [--run [args...]]"

while [ $# -gt 0 ]; do
    case "$1" in
        --debug)
            CONFIG="debug"
            shift
            ;;
        --release)
            CONFIG="release"
            shift
            ;;
        --no-dylibs|--skip-dylibs)
            BUNDLE_DYLIBS=false
            shift
            ;;
        --from-source)
            FROM_SOURCE=true
            shift
            ;;
        --version=*)
            APP_VERSION="${1#--version=}"
            shift
            ;;
        --run)
            RUN_APP=true
            shift
            RUN_ARGS=("$@")
            break
            ;;
        -h|--help)
            echo "$USAGE"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "$USAGE" >&2
            exit 1
            ;;
    esac
done

# Version: --version (release workflow passes the tag), else the latest `vX.Y.Z` tag via
# `git describe`, else 0.0.0. Builds past a tag keep its X.Y.Z; the build number tells them apart.
if [ -z "$APP_VERSION" ]; then
    if GIT_DESCRIBE="$(git describe --tags --match 'v[0-9]*' 2>/dev/null)"; then
        APP_VERSION="$GIT_DESCRIBE"
    else
        APP_VERSION="0.0.0"
    fi
fi
APP_VERSION="${APP_VERSION#v}"
if ! [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.+)?$ ]]; then
    echo "Error: invalid version '$APP_VERSION' (expected X.Y.Z or X.Y.Z-suffix)." >&2
    exit 1
fi
# CFBundleShortVersionString must be numeric, so prerelease / describe suffixes are dropped there.
SHORT_VERSION="${APP_VERSION%%-*}"
# Monotonic build number; needs full history (shallow clones count 1).
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "==> Version $APP_VERSION (CFBundleShortVersionString $SHORT_VERSION, build $BUILD_NUMBER)"

DEPS_PREFIX="$DIR/.build/dependencies"
if [ "$BUNDLE_DYLIBS" = true ]; then
    echo "==> Setting up LGPL dependencies (macOS 15.0+)..."
    SETUP_OPTS=(--prefix="$DEPS_PREFIX")
    if [ "$FROM_SOURCE" = true ]; then
        SETUP_OPTS+=("--from-source")
    fi
    "$DIR/scripts/setup_dependencies.sh" "${SETUP_OPTS[@]}"
    export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

echo "==> Building Nits with swift build ($CONFIG)..."
CONFIG_DIR="$(echo "${CONFIG:0:1}" | tr "[:lower:]" "[:upper:]")${CONFIG:1}"
swift build -c "$CONFIG" --disable-sandbox

APP_DIR="$DIR/build/Nits.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo "==> Packaging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

BIN_PATH="$DIR/.build/out/Products/$CONFIG_DIR/Nits"
if [ ! -f "$BIN_PATH" ]; then
    # Fallback to standard swiftpm path if custom out path is absent
    BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/Nits"
fi

cp "$BIN_PATH" "$MACOS_DIR/Nits"
chmod +x "$MACOS_DIR/Nits"

# Swift Build links via `swiftc` without SDKROOT, so clang records the deployment target (15.0) as
# the SDK version. AppKit/SwiftUI gate the current design (Liquid Glass) on the linked SDK, so such a
# binary runs in the legacy look on macOS 26+. Stamp the real SDK version.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS="$(otool -l "$MACOS_DIR/Nits" | awk '/cmd LC_BUILD_VERSION/ {f=1} f && /minos/ {print $2; exit}')"
LINKED_SDK="$(otool -l "$MACOS_DIR/Nits" | awk '/cmd LC_BUILD_VERSION/ {f=1} f && /sdk/ {print $2; exit}')"
if [ "$LINKED_SDK" != "$SDK_VERSION" ]; then
    echo "==> Setting linked SDK version $LINKED_SDK -> $SDK_VERSION (minos $MIN_OS)..."
    vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace -output "$MACOS_DIR/Nits" "$MACOS_DIR/Nits"
fi

# Copy any resource bundles
for b in "$DIR/.build/out/Products/$CONFIG_DIR/"*.bundle; do
    if [ -d "$b" ]; then
        cp -R "$b" "$RESOURCES_DIR/"
    fi
done

# Copy app icon if present in project resources
APP_ICON="$DIR/Sources/NitsApp/Resources/AppIcon.icns"
if [ -f "$APP_ICON" ]; then
    echo "==> Including AppIcon.icns..."
    cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
fi

# About panel credits and third-party notices (LGPL code is shipped even with --no-dylibs)
cp "$DIR/Sources/NitsApp/Resources/Credits.rtf" "$RESOURCES_DIR/Credits.rtf"
mkdir -p "$RESOURCES_DIR/ThirdPartyLicenses"
cp "$DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/ThirdPartyLicenses/"

# Bundle dynamic libraries into Contents/Frameworks
if [ "$BUNDLE_DYLIBS" = true ]; then
    echo "==> Bundling dynamic libraries into Contents/Frameworks..."
    mkdir -p "$FRAMEWORKS_DIR"
    DEPS_LIB="$DEPS_PREFIX/lib"

    # Non-system load commands of a Mach-O, excluding a dylib's own install name.
    non_system_deps() {
        local self
        self="$(otool -D "$1" | tail -n +2)"
        otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dep; do
            case "$dep" in
                /System/*|/usr/lib/*|@*|"$self") ;;
                *) echo "$dep" ;;
            esac
        done
    }

    rpaths() {
        otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print}'
    }

    # 1. Copy transitive dependencies. All of them must come from the LGPL prefix: anything else
    #    (e.g. Homebrew's GPL FFmpeg picked up by a stale build) must never ship.
    QUEUE=("$MACOS_DIR/Nits")
    i=0
    while [ $i -lt ${#QUEUE[@]} ]; do
        while read -r dep; do
            BASE="$(basename "$dep")"
            DEST="$FRAMEWORKS_DIR/$BASE"
            [ -e "$DEST" ] && continue
            if [ "$dep" != "$DEPS_LIB/$BASE" ] || [ ! -f "$dep" ]; then
                echo "Error: $(basename "${QUEUE[$i]}") links $dep, expected $DEPS_LIB/$BASE" >&2
                echo "Run 'swift package clean' and bundle again." >&2
                exit 1
            fi
            cp -L "$dep" "$DEST"
            chmod 755 "$DEST"
            QUEUE+=("$DEST")
        done < <(non_system_deps "${QUEUE[$i]}")
        i=$((i + 1))
    done

    # 2. Rewrite load commands to @rpath and drop build-machine rpaths (Xcode toolchain etc.),
    #    keeping only @-relative and /usr/lib ones.
    relink() {
        local file="$1" own_rpath="$2" args=() dep rpath has_own=false
        while read -r dep; do
            args+=(-change "$dep" "@rpath/$(basename "$dep")")
        done < <(non_system_deps "$file")
        while read -r rpath; do
            case "$rpath" in
                "$own_rpath") has_own=true ;;
                @*|/usr/lib/*) ;;
                *) args+=(-delete_rpath "$rpath") ;;
            esac
        done < <(rpaths "$file")
        if [ "$has_own" = false ]; then
            args+=(-add_rpath "$own_rpath")
        fi
        case "$file" in
            *.dylib) args+=(-id "@rpath/$(basename "$file")") ;;
        esac
        deps_install_name_tool "${args[@]}" "$file"
    }

    relink "$MACOS_DIR/Nits" "@executable_path/../Frameworks"
    for dylib in "$FRAMEWORKS_DIR/"*.dylib; do
        relink "$dylib" "@loader_path"
        codesign --force -s - "$dylib"
    done

    # 3. Verify: only system libraries, bundled @rpath libraries and relative/system rpaths remain.
    echo "==> Verifying bundled dylib dependencies..."
    for f in "$MACOS_DIR/Nits" "$FRAMEWORKS_DIR/"*.dylib; do
        while read -r dep; do
            case "$dep" in
                /System/*|/usr/lib/*) ;;
                @rpath/*) [ -f "$FRAMEWORKS_DIR/${dep#@rpath/}" ] || { echo "Error: $f needs missing $dep" >&2; exit 1; } ;;
                *) echo "Error: non-portable dependency in $f: $dep" >&2; exit 1 ;;
            esac
        done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
        while read -r rpath; do
            case "$rpath" in
                @*|/usr/lib/*) ;;
                *) echo "Error: non-portable LC_RPATH in $f: $rpath" >&2; exit 1 ;;
            esac
        done < <(rpaths "$f")
    done
    echo "==> Verification passed: no non-portable references"

    # 4. License notices (LGPL requires shipping them with the libraries)
    cp -R "$DEPS_PREFIX/share/licenses/." "$RESOURCES_DIR/ThirdPartyLicenses/"
fi

# Create Info.plist with valid bundle identifier
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Nits</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.ghotriw.nits</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Nits</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video Media</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.video</string>
                <string>public.audiovisual-content</string>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.avi</string>
                <string>org.matroska.mkv</string>
                <string>org.webmproject.webm</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp4</string>
                <string>mkv</string>
                <string>mov</string>
                <string>avi</string>
                <string>webm</string>
                <string>m4v</string>
                <string>flv</string>
                <string>wmv</string>
                <string>ts</string>
                <string>ogv</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio Media</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.mp3</string>
                <string>com.microsoft.waveform-audio</string>
                <string>public.aiff-audio</string>
                <string>org.xiph.flac</string>
                <string>org.xiph.ogg</string>
                <string>org.xiph.opus</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp3</string>
                <string>flac</string>
                <string>wav</string>
                <string>m4a</string>
                <string>aac</string>
                <string>ogg</string>
                <string>opus</string>
                <string>alac</string>
                <string>aif</string>
                <string>aiff</string>
                <string>wma</string>
                <string>ape</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Playlist Media</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.playlist</string>
                <string>public.m3u-playlist</string>
                <string>com.soundflavor.bestplaylist-format</string>
                <string>org.xiph.xspf</string>
                <string>org.videolan.pls</string>
                <string>com.cdrwin.cue</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>m3u</string>
                <string>m3u8</string>
                <string>pls</string>
                <string>xspf</string>
                <string>cue</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.matroska.mkv</string>
            <key>UTTypeDescription</key>
            <string>Matroska Video</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.movie</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mkv</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.webmproject.webm</string>
            <key>UTTypeDescription</key>
            <string>WebM Video</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.movie</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>webm</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.xiph.flac</string>
            <key>UTTypeDescription</key>
            <string>FLAC Audio</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.audio</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>flac</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.xiph.ogg</string>
            <key>UTTypeDescription</key>
            <string>Ogg Audio</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.audio</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>ogg</string>
                    <string>oga</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.xiph.opus</string>
            <key>UTTypeDescription</key>
            <string>Opus Audio</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.audio</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>opus</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.videolan.pls</string>
            <key>UTTypeDescription</key>
            <string>PLS Playlist</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.playlist</string>
                <string>public.text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>pls</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.xiph.xspf</string>
            <key>UTTypeDescription</key>
            <string>XSPF Playlist</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.playlist</string>
                <string>public.xml</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>xspf</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.cdrwin.cue</string>
            <key>UTTypeDescription</key>
            <string>CUE Sheet</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.playlist</string>
                <string>public.text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>cue</string>
                </array>
            </dict>
        </dict>
    </array>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

echo "==> Codesigning Nits.app..."
codesign --force --deep -s - "$APP_DIR"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -f "$LSREGISTER" ]; then
    echo "==> Registering with LaunchServices..."
    "$LSREGISTER" -f "$APP_DIR"
fi

echo "==> Done! App bundle created at $APP_DIR"
if [ "$RUN_APP" = true ]; then
    echo "==> Launching Nits.app..."
    if [ ${#RUN_ARGS[@]} -gt 0 ]; then
        open "$APP_DIR" --args "${RUN_ARGS[@]}"
    else
        open "$APP_DIR"
    fi
fi
