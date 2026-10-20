#!/usr/bin/env bash
# Signiert fertige APKs mit Schlüsselwechsel (APK Signature Scheme v3):
# v1/v2 mit dem alten Schlüssel, v3 mit dem neuen Release-Schlüssel samt
# Nachweis (lineage). So lassen sich Updates über ältere, mit dem alten
# Schlüssel signierte Versionen installieren – ohne Datenverlust.
#
#   tool/sign_release.sh <keys-dir> <apk>...
# keys-dir enthält key.properties, jason_release.jks, lineage.bin und
# old.keystore (alter Schlüssel, Passwort in OLD_PASS, Standard: android).
set -euo pipefail
KEYS="$1"; shift
BT="${ANDROID_HOME:?}/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)"
PW=$(grep '^storePassword=' "$KEYS/key.properties" | cut -d= -f2-)
OLD_PASS="${OLD_PASS:-android}"
for apk in "$@"; do
  "$BT/apksigner" sign \
    --ks "$KEYS/old.keystore" --ks-pass "pass:$OLD_PASS" \
    --next-signer --ks "$KEYS/jason_release.jks" --ks-pass "pass:$PW" \
    --lineage "$KEYS/lineage.bin" --rotation-min-sdk-version 28 \
    "$apk"
  "$BT/apksigner" verify --print-certs "$apk" | grep -E "Signer|SHA-256" | head -4
done
