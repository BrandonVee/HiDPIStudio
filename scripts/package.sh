#!/bin/bash
set -euo pipefail
STUDIO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUDIO_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$STUDIO_ROOT/Resources/Info.plist")"
STUDIO_EXPECTED_VERSION="${1:-$STUDIO_VERSION}"
STUDIO_OUTPUT="${2:-$STUDIO_ROOT/dist}"
if [[ ! "$STUDIO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$STUDIO_VERSION" != "$STUDIO_EXPECTED_VERSION" ]]; then
    printf 'Version mismatch: requested %s, Info.plist contains %s\n' "$STUDIO_EXPECTED_VERSION" "$STUDIO_VERSION" >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    printf 'Release packaging requires an Apple Silicon (arm64) Mac.\n' >&2
    exit 1
fi
mkdir -p "$STUDIO_ROOT/.build" "$STUDIO_OUTPUT"
STUDIO_OUTPUT="$(cd "$STUDIO_OUTPUT" && pwd)"
STUDIO_WORK="$(mktemp -d "$STUDIO_ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$STUDIO_WORK"' EXIT
STUDIO_APP="$STUDIO_WORK/HiDPI Studio.app"
STUDIO_BINARY="$STUDIO_APP/Contents/MacOS/HiDPIStudio"
STUDIO_ARCHIVE="HiDPIStudio-v$STUDIO_VERSION-macOS-arm64.zip"
STUDIO_CHECKSUMS="HiDPIStudio-v$STUDIO_VERSION-SHA256SUMS.txt"

"$STUDIO_ROOT/build.sh" "$STUDIO_APP"
"$STUDIO_BINARY" --test-ci
[[ "$(/usr/bin/lipo -archs "$STUDIO_BINARY")" == arm64 ]]
/usr/bin/codesign --verify --strict "$STUDIO_APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STUDIO_APP" "$STUDIO_WORK/$STUDIO_ARCHIVE"
# Verify the actual distributable after a round trip through ZIP.
/usr/bin/ditto -x -k "$STUDIO_WORK/$STUDIO_ARCHIVE" "$STUDIO_WORK/unpacked"
/usr/bin/codesign --verify --strict "$STUDIO_WORK/unpacked/HiDPI Studio.app"
mv "$STUDIO_WORK/$STUDIO_ARCHIVE" "$STUDIO_OUTPUT/$STUDIO_ARCHIVE"
(
    cd "$STUDIO_OUTPUT"
    /usr/bin/shasum -a 256 "$STUDIO_ARCHIVE" > "$STUDIO_CHECKSUMS"
    /usr/bin/shasum -a 256 --check "$STUDIO_CHECKSUMS"
)
printf 'Packaged: %s/%s\n' "$STUDIO_OUTPUT" "$STUDIO_ARCHIVE"
