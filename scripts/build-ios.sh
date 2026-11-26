#!/usr/bin/env bash
# Build the iOS app (iOS/PhotosBackup.xcodeproj).
#
#   scripts/build-ios.sh --simulator      Debug build for the iOS Simulator; prints the .app path
#   scripts/build-ios.sh [--out DIR]      Release build for devices, packaged as an UNSIGNED
#                                         Photos-Backup-<VERSION>-iOS.ipa (+ .sha256) in DIR
#                                         (default build/), then checked
#
# The IPA is deliberately unsigned: AltStore, SideStore, Feather or a signing
# service re-sign it with the installer's own Apple ID. The version comes from
# VERSION; BUILD_NUMBER (default 1) becomes CFBundleVersion. xcodebuild uses
# DEVELOPER_DIR when it is set, as CI does to pick its Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/iOS/PhotosBackup.xcodeproj"
SCHEME=PhotosBackup
BUNDLE_ID=io.github.ayush5harma.PhotosBackup
MINIMUM_OS=17.0

usage() {
  echo "usage: build-ios.sh [--simulator] [--out DIR]" >&2
  exit 2
}

SIMULATOR=0
OUT="$ROOT/build"
while [ $# -gt 0 ]; do
  case "$1" in
    --simulator) SIMULATOR=1 ;;
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'build-ios: invalid release version in VERSION' >&2; exit 2; }
BUILD_NUMBER="${BUILD_NUMBER:-1}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo 'build-ios: BUILD_NUMBER must be numeric' >&2; exit 2; }
DERIVED="${IOS_DERIVED_DATA:-$ROOT/build/ios-derived}"
echo "build-ios: $(xcodebuild -version | head -n 1) at $(xcode-select -p)${DEVELOPER_DIR:+ (DEVELOPER_DIR)}" >&2

if [ "$SIMULATOR" = 1 ]; then
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -quiet build >&2
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/PhotosBackup.app"
  [ -d "$APP" ] || { echo "build-ios: no app at $APP" >&2; exit 1; }
  echo "$APP"
  exit 0
fi

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet build >&2
APP="$DERIVED/Build/Products/Release-iphoneos/PhotosBackup.app"
[ -d "$APP" ] || { echo "build-ios: no app at $APP" >&2; exit 1; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
IPA="Photos-Backup-$VERSION-iOS.ipa"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/stage/Payload"
ditto "$APP" "$TEMP/stage/Payload/PhotosBackup.app"
rm -f "$OUT/$IPA" "$OUT/$IPA.sha256"
(cd "$TEMP/stage" && zip -qry -X "$OUT/$IPA" Payload)

# Check what was packaged, not what was built: unpack the IPA and read it.
fail() { echo "build-ios: $*" >&2; exit 1; }
mkdir -p "$TEMP/check"
ditto -x -k "$OUT/$IPA" "$TEMP/check"
CHECKED="$TEMP/check/Payload/PhotosBackup.app"
[ -d "$CHECKED" ] || fail "the IPA has no Payload/PhotosBackup.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$CHECKED/Info.plist" 2>/dev/null || true; }
EXECUTABLE="$(plist CFBundleExecutable)"
[ -f "$CHECKED/$EXECUTABLE" ] || fail "the executable '$EXECUTABLE' is missing"
ARCHS="$(lipo -archs "$CHECKED/$EXECUTABLE")"
[ "$ARCHS" = arm64 ] || fail "the executable is '$ARCHS', not arm64"
file "$CHECKED/$EXECUTABLE" | grep -q 'Mach-O 64-bit executable arm64' || fail "the executable is not an arm64 Mach-O"
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || fail "CFBundleShortVersionString is '$(plist CFBundleShortVersionString)', not $VERSION"
[ "$(plist CFBundleVersion)" = "$BUILD_NUMBER" ] || fail "CFBundleVersion is '$(plist CFBundleVersion)', not $BUILD_NUMBER"
[ "$(plist MinimumOSVersion)" = "$MINIMUM_OS" ] || fail "MinimumOSVersion is '$(plist MinimumOSVersion)', not $MINIMUM_OS"
[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "CFBundleIdentifier is '$(plist CFBundleIdentifier)', not $BUNDLE_ID"
[ ! -e "$CHECKED/_CodeSignature" ] || fail "the app is signed (_CodeSignature present)"
[ ! -e "$CHECKED/embedded.mobileprovision" ] || fail "the app carries a provisioning profile"
# The debug hooks (fixture, sandbox, the E2E account and fake Google) are
# compiled out of Release; their names in the binary would mean one is not.
if strings -a "$CHECKED/$EXECUTABLE" | grep -q -E 'PHOTOS_BACKUP_|e2e-synthetic'; then
  fail "the Release binary carries a debug hook's name"
fi

(cd "$OUT" && shasum -a 256 "$IPA" > "$IPA.sha256")
echo "build-ios: checked arm64, version $VERSION ($BUILD_NUMBER), iOS $MINIMUM_OS+, $BUNDLE_ID, unsigned, no debug hooks" >&2
printf 'Packaged %s\n' "$OUT/$IPA"
