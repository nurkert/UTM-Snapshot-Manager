#!/usr/bin/env bash
#
# Creates the local code-signing certificate the build scripts look for.
#
# Why this exists
# ---------------
# macOS ties Privacy permissions — Documents access, controlling UTM — to an
# application's code signature. An ad-hoc signature (`codesign --sign -`) is
# derived from the binary itself, so it changes with every build: to the system
# each rebuild is a different application, and every permission has to be
# granted again. That turns a two-minute change into a trip through System
# Settings, every single time.
#
# Signing with a certificate instead makes the designated requirement name the
# certificate rather than the binary's hash. Rebuild as often as you like; the
# permissions stay.
#
# This is a *local development* certificate. It is not a Developer ID, it does
# not enable notarisation, and it means nothing on any other Mac. It only stops
# your own machine from treating each build as a stranger.
#
# To undo: delete "UTM Snapshot Manager Dev" from Keychain Access (login
# keychain, My Certificates). The build falls back to ad-hoc signing.

set -euo pipefail

CN="${USM_SIGN_IDENTITY:-UTM Snapshot Manager Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
green() { printf '\033[1;32m%s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$1" >&2; exit 1; }

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN"; then
  green "“${CN}” already exists — nothing to do."
  exit 0
fi

command -v openssl >/dev/null 2>&1 || fail "openssl not found."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bold "Creating a local code-signing certificate…"

# codeSigning is the extended key usage codesign insists on; without it the
# identity is imported but never offered.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
  -subj "/CN=$CN/O=Local Development" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 \
  || fail "Could not create the certificate."

# macOS's `security` cannot read OpenSSL 3's default PKCS#12 encryption, so the
# bundle is written with the older algorithms it does understand. The password
# only protects this temporary file, which is deleted on the way out.
openssl pkcs12 -export -out "$WORK/bundle.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:transient \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1 \
  || fail "Could not package the certificate."

security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P transient -A >/dev/null 2>&1 \
  || fail "Could not import into the login keychain."

security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN" \
  || fail "Imported, but codesign does not offer it. Check Keychain Access."

green "Done. “${CN}” is in your login keychain."
echo
echo "From now on Scripts/build-app.sh signs with it, and the Privacy"
echo "permissions you grant survive every rebuild."
echo
warn "You will be asked for Documents access and UTM control once more after"
warn "the next build — that build is the first one carrying the new signature."
