#!/usr/bin/env bash
#
# One check, for one bug that has now shipped twice.
#
# In a UTF-8 locale bash keeps consuming bytes after `$NAME` while they still
# look like name characters, and the leading bytes of “ ” … — all do. So
# `blue "Building $DMG…"` expands the variable `DMG<0xe2><0x80>`, which under
# `set -u` aborts the script. It cost a release run and, in install.sh, a
# successful install that reported itself as a failure.
#
# Braces end the name explicitly: "${DMG}…".

set -euo pipefail
cd "$(dirname "$0")/.."

if ! matches="$(grep -rnP '\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7F])' \
    --include='*.sh' . 2>/dev/null)"; then
  printf '\033[1;32m%s\033[0m\n' "Shell lint passed."
  exit 0
fi

printf '\033[1;31m%s\033[0m\n' "A variable is followed by a non-ASCII character; brace it as \${NAME}:" >&2
printf '%s\n' "$matches" >&2
exit 1
