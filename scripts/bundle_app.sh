#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "==> Building Nits with swift build..."
CONFIG="release"
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --release) CONFIG="release" ;;
        *) echo "Usage: $0 [--debug|--release]" >&2; exit 1 ;;
    esac
done
CONFIG_DIR="$(echo "${CONFIG:0:1}" | tr "[:lower:]" "[:upper:]")${CONFIG:1}"
swift build -c "$CONFIG" --disable-sandbox

APP_DIR="$DIR/build/Nits.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

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
    </array>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> Codesigning Nits.app..."
codesign --force --deep -s - "$APP_DIR"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -f "$LSREGISTER" ]; then
    echo "==> Registering with LaunchServices..."
    "$LSREGISTER" -f "$APP_DIR"
fi

echo "==> Done! App bundle created at $APP_DIR"
if [ "$1" == "--run" ]; then
    shift
    echo "==> Launching Nits.app..."
    if [ $# -gt 0 ]; then
        open "$APP_DIR" --args "$@"
    else
        open "$APP_DIR"
    fi
fi
