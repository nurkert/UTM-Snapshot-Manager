#!/usr/bin/env bash
#
# Launches the built application and checks that its content area draws
# something.
#
# This is the only test that touches the interface, and it exists because of a
# defect that twenty-five integration tests and two review passes missed: the
# window drew its toolbar and nothing else while every view body ran correctly.
# Two headless approaches were tried first and both passed the broken build —
# measuring views in an NSHostingView gives identical numbers with and without
# the defect. Launching the app and looking at the window is what worked.
#
# Needs a logged-in graphical session and Screen Recording permission. Without
# either it reports that it could not check rather than failing.

set -euo pipefail
cd "$(dirname "$0")/.."

green() { printf "\033[1;32m%s\033[0m\n" "$1"; }
fail()  { printf "\033[1;31m%s\033[0m\n" "$1" >&2; exit 1; }

APP="${1:-}"
if [ -z "$APP" ]; then
  APP="$(Scripts/build-app.sh | tail -1)"
fi
[ -d "$APP" ] || fail "No application bundle at ${APP}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -o "$WORK/smoke-test" Tests/Smoke/*.swift

"$WORK/smoke-test" "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
green "Smoke test passed."
