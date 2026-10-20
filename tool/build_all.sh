#!/usr/bin/env bash
# Lokal alle 6 APKs bauen und signieren (wie der GitHub-Workflow).
#   tool/build_all.sh <schlüssel-ordner> <ziel-ordner>
set -euo pipefail
KEYS="$1"; OUT="$2"; mkdir -p "$OUT"
V=$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
R="--dart-define=UPDATE_REPO=JasonConsultant/jason-stream-player"
b(){ flutter build apk "$@" || { echo "Retry …"; flutter build apk "$@"; }; }
C="--release --target-platform android-arm,android-arm64 --obfuscate $R"
b --flavor standard $C --split-per-abi --split-debug-info=build/symbols
b --flavor turkish --dart-define=DEFAULT_LANG=tr $C --split-per-abi --split-debug-info=build/symbols-tr
O=build/app/outputs/flutter-apk
cp $O/app-arm64-v8a-standard-release.apk   "$OUT/JasonStreamPlayer_${V}_arm64.apk"
cp $O/app-armeabi-v7a-standard-release.apk "$OUT/JasonStreamPlayer_${V}_arm32.apk"
cp $O/app-arm64-v8a-turkish-release.apk    "$OUT/JasonStreamPlayer_TR_${V}_arm64.apk"
cp $O/app-armeabi-v7a-turkish-release.apk  "$OUT/JasonStreamPlayer_TR_${V}_arm32.apk"
b --flavor standard $C --split-debug-info=build/symbols-uni
b --flavor turkish --dart-define=DEFAULT_LANG=tr $C --split-debug-info=build/symbols-uni-tr
cp $O/app-standard-release.apk "$OUT/JasonStreamPlayer_TV_${V}.apk"
cp $O/app-turkish-release.apk  "$OUT/JasonStreamPlayer_TR_TV_${V}.apk"
tool/sign_release.sh "$KEYS" "$OUT"/*_${V}*.apk
rm -f "$OUT"/*.idsig
