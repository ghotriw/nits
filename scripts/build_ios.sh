#!/usr/bin/env bash
# Builds and tests the iOS app (Apps/iOS). The project is generated from Apps/iOS/project.yml with XcodeGen.
#
# Usage:
#   build_ios.sh generate                 only (re)generate Apps/iOS/Nits.xcodeproj, to open in Xcode
#   build_ios.sh [simulator]              build for the iOS Simulator (default)
#   build_ios.sh device                   build for a device; signed with DEVELOPMENT_TEAM=<team id> (environment or .env), else unsigned
#   build_ios.sh ipa                      unsigned build/ios/Nits.ipa for a sideloader (SideStore, AltStore) that signs it on install
#   build_ios.sh test [--destination=…]   run the test plan (NitsStreamingTests + NitsTouchKitTests + NitsTouchUITests) on a simulator
# Options: --version=X.Y.Z[-suffix] (default: the latest vX.Y.Z tag, as bundle_app.sh), --destination='platform=iOS Simulator,name=…'
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# Local settings (DEVELOPMENT_TEAM=…), not committed (.gitignore).
if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi

MODE="simulator"
APP_VERSION=""
DESTINATION=""
for arg in "$@"; do
    case "$arg" in
        generate | simulator | device | ipa | test) MODE="$arg" ;;
        --version=*) APP_VERSION="${arg#--version=}" ;;
        --destination=*) DESTINATION="${arg#--destination=}" ;;
        -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: XcodeGen is needed to generate the project (brew install xcodegen)." >&2
    exit 1
fi

# The version comes only from the tag, as for the macOS app (bundle_app.sh): never hardcoded.
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
SHORT_VERSION="${APP_VERSION%%-*}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Generating Apps/iOS/Nits.xcodeproj..."
(cd Apps/iOS && xcodegen generate --quiet)
if [ "$MODE" = generate ]; then
    exit 0
fi

COMMON=(
    -project Apps/iOS/Nits.xcodeproj -scheme NitsiOS
    MARKETING_VERSION="$SHORT_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    # The frameworks are arm64 only (build_dependencies.sh), so no Intel simulator slice.
    ARCHS=arm64
)

case "$MODE" in
    simulator)
        echo "==> Building for the iOS Simulator (version $APP_VERSION, build $BUILD_NUMBER)..."
        xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS Simulator' build
        ;;
    device)
        echo "==> Building for a device (version $APP_VERSION, build $BUILD_NUMBER)..."
        SIGN_ARGS=()
        if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
            SIGN_ARGS=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates)
        else
            echo "==> No DEVELOPMENT_TEAM: building unsigned (compiles and links; it cannot be installed)."
            SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
        fi
        xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS' "${SIGN_ARGS[@]}" build
        ;;
    ipa)
        # Unsigned, for a sideloader (SideStore, AltStore, …) that signs it with its own certificate on install.
        OUT="$DIR/build/ios"
        # DerivedData stays outside OUT (which is cleared) so the next build is incremental.
        DERIVED="$DIR/build/ios-derived"
        rm -rf "$OUT"
        mkdir -p "$OUT"
        echo "==> Building an unsigned Release app (version $APP_VERSION, build $BUILD_NUMBER)..."
        xcodebuild "${COMMON[@]}" -configuration Release -destination 'generic/platform=iOS' \
            -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
        PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
        APP="$PRODUCTS/Nits.app"
        [ -d "$APP" ] || { echo "Error: $APP was not built." >&2; exit 1; }
        mkdir -p "$OUT/Payload"
        ditto "$APP" "$OUT/Payload/Nits.app"
        (cd "$OUT" && zip -qry Nits.ipa Payload)
        rm -rf "$OUT/Payload"
        # The symbols to read a user's crash reports with: part of what this mode makes (release.yml publishes both).
        [ -d "$PRODUCTS/Nits.app.dSYM" ] || { echo "Error: no Nits.app.dSYM (DEBUG_INFORMATION_FORMAT of Release?)." >&2; exit 1; }
        # --norsrc / --noextattr: no AppleDouble ._ files (symbolicators read ._Nits as a broken object file).
        ditto -c -k --norsrc --noextattr --keepParent "$PRODUCTS/Nits.app.dSYM" "$OUT/Nits.app.dSYM.zip"
        echo "==> $OUT/Nits.ipa"
        ;;
    test)
        if [ -z "$DESTINATION" ]; then
            # The first available iPhone simulator.
            SIM_ID="$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/ {print $2; exit}')"
            [ -n "$SIM_ID" ] || { echo "Error: no iPhone simulator available." >&2; exit 1; }
            DESTINATION="platform=iOS Simulator,id=$SIM_ID"
        fi
        echo "==> Running the test plan on $DESTINATION..."
        xcodebuild "${COMMON[@]}" -destination "$DESTINATION" test
        ;;
esac
