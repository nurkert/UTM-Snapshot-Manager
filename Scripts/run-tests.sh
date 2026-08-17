#!/bin/bash
#
# Integration tests. Builds the app's own service layer together with a test
# driver and runs it against real qcow2 images in a temporary directory.
#
# These are deliberately not mocked: the whole point of this app is what
# qemu-img actually does to a disk, and a fake qemu-img would test the fake.
#
set -euo pipefail

cd "$(dirname "$0")/.."

green() { printf "\033[1;32m%s\033[0m\n" "$1"; }
fail()  { printf "\033[1;31m%s\033[0m\n" "$1" >&2; exit 1; }

command -v qemu-img >/dev/null 2>&1 || fail "qemu-img is required: brew install qemu"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/integration-tests"

Scripts/lint-shell.sh

swiftc -o "$BIN" \
  Sources/Services/*.swift \
  Sources/Model/*.swift \
  Tests/Integration/main.swift

"$BIN"
green "Integration tests passed."

# The interface is checked separately, by launching the app — see
# Scripts/smoke-test.sh for why it cannot be done headlessly.
#
# Only when a build is already lying around. This script otherwise compiles just
# the service and model layer, and having it build a whole application on the
# side turns a fifteen-second test run into a two-minute one — and fails outright
# on a machine set up only to run the tests, which is what the CI test job is.
APP="build/Build/Products/Release/UTM Snapshot Manager.app"
if [ "${USM_SKIP_SMOKE:-}" = "1" ]; then
  echo "Smoke test skipped (USM_SKIP_SMOKE=1)."
elif [ -d "$APP" ]; then
  Scripts/smoke-test.sh "$APP" || fail "Smoke test failed."
else
  echo "Smoke test skipped (no build — run Scripts/smoke-test.sh after building)."
fi
