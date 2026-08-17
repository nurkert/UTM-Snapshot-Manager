#!/bin/bash
#
# Packages the built app into a drag-to-Applications disk image.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="UTM Snapshot Manager"
BUILD_DIR="${BUILD_DIR:-build}"
PRODUCT="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DIST_DIR="dist"

blue() { printf "\033[1;34m%s\033[0m\n" "$1"; }
fail() { printf "\033[1;31m%s\033[0m\n" "$1" >&2; exit 1; }

[ -d "$PRODUCT" ] || fail "No app bundle at $PRODUCT — run Scripts/build-app.sh first."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PRODUCT/Contents/Info.plist" 2>/dev/null || echo "0.0")"
DMG="$DIST_DIR/UTM-Snapshot-Manager-$VERSION.dmg"

rm -rf "$DIST_DIR/stage" "$DMG"
mkdir -p "$DIST_DIR/stage"

cp -R "$PRODUCT" "$DIST_DIR/stage/"
ln -s /Applications "$DIST_DIR/stage/Applications"

# A short note travels with the image, because an ad-hoc signed app downloaded
# from the internet is quarantined and the first launch fails with a message
# that sounds far more alarming than the situation warrants.
cat > "$DIST_DIR/stage/First launch - read me.txt" <<'EOF'
Drag "UTM Snapshot Manager" onto the Applications folder.

The app is signed ad-hoc rather than with a paid Apple Developer ID, so the
first launch needs one extra step:

  Right-click the app in Applications, choose "Open", then confirm.

Only the first launch needs this. Double-clicking works from then on.
EOF

blue "Building ${DMG}…"

# hdiutil output is deliberately not silenced. On a build machine this is the
# only place a failure explains itself, and hiding it once cost an entire
# release run that could only be described as "step failed".
#
# The filesystem is stated explicitly: the default depends on the host's own
# volume format, which differs between a developer's Mac and a CI image, and an
# unexpected default is one of the ways this step fails there.
attempt_create() {
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DIST_DIR/stage" \
    -fs HFS+ \
    -ov -format UDZO \
    "$DMG"
}

if ! attempt_create; then
  # hdiutil occasionally loses a race with the system's own disk arbitration on
  # shared build machines. One retry costs seconds and turns a flaky red run
  # into a green one; a second failure is a real problem and is reported.
  printf "\033[1;33m%s\033[0m\n" "hdiutil failed — retrying once…"
  sleep 5
  rm -f "$DMG"
  attempt_create || fail "Could not create the disk image."
fi

rm -rf "$DIST_DIR/stage"

[ -f "$DMG" ] || fail "hdiutil reported success but produced no image."
hdiutil verify "$DMG" || fail "The disk image did not verify."

shasum -a 256 "$DMG" | tee "$DMG.sha256"
blue "Done: $DMG"
