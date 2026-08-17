#!/bin/bash
#
# Builds "UTM Snapshot Manager.app" into build/Build/Products/Release.
# Used by install.sh, make-dmg.sh and CI, so the build itself is defined once.
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="UTM Snapshot Manager"
BUILD_DIR="${BUILD_DIR:-build}"
CONFIGURATION="${CONFIGURATION:-Release}"

blue()  { printf "\033[1;34m%s\033[0m\n" "$1"; }
fail()  { printf "\033[1;31m%s\033[0m\n" "$1" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || fail \
  "Xcode is required. Install it, then run: sudo xcode-select -s /Applications/Xcode.app"
command -v xcodegen >/dev/null 2>&1 || fail \
  "XcodeGen is required: brew install xcodegen"

blue "Generating app icon…"
swift Tools/MakeIcon.swift

blue "Generating Xcode project…"
xcodegen generate --quiet

blue "Building ($CONFIGURATION)…"
# Capture the compiler's exit status before anything else can clobber
# PIPESTATUS. The previous version inspected it after an intervening test,
# which happened to work but only by accident.
set +e
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  ARCHS="x86_64 arm64" \
  ONLY_ACTIVE_ARCH=NO \
  build 2>&1 | grep -E "(error:|warning: .*Sources|BUILD)"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

[ "$BUILD_STATUS" -eq 0 ] || fail "Build failed — nothing was produced."

PRODUCT="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
[ -d "$PRODUCT" ] || fail "Build reported success but produced no app bundle."

# macOS keys Privacy permissions to the code signature, and an ad-hoc signature
# is the binary's own hash — so every rebuild is a different application as far
# as the system is concerned, and Documents access and UTM control have to be
# granted all over again. During development that is the difference between
# testing a change and spending the session in System Settings.
#
# A local self-signed certificate fixes it: the designated requirement then
# names the certificate instead of the hash, and the grants survive every
# rebuild. Create it once with Scripts/make-signing-cert.sh.
#
# Falls back to ad-hoc when that certificate is not installed, so a fresh clone
# and the CI runner still build — they just pay the re-granting cost.
SIGN_IDENTITY="${USM_SIGN_IDENTITY:-UTM Snapshot Manager Dev}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  blue "Signing as “${SIGN_IDENTITY}”…"
  codesign --force --sign "$SIGN_IDENTITY" "$PRODUCT" >/dev/null 2>&1 || \
    fail "Signing with “${SIGN_IDENTITY}” failed."
else
  blue "Signing (ad-hoc — macOS will ask for permissions again after this build)…"
  codesign --force --sign - "$PRODUCT" >/dev/null 2>&1 || \
    fail "Ad-hoc signing failed."
fi

echo "$PRODUCT"
