#!/usr/bin/env bash
#
# doctor.sh — quick read-only report of the dev toolchain state.
# Tells you what's pinned, which Flutter would be used, and whether an
# Android SDK is present. Makes no changes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$REPO_ROOT/.flutter-version"
LOCAL_FLUTTER_BIN="$REPO_ROOT/.tool/flutter/bin/flutter"

line() { printf '%-22s %s\n' "$1" "$2"; }

required="(none)"
[ -f "$VERSION_FILE" ] && required="$(tr -d '[:space:]' < "$VERSION_FILE")"
line "Pinned version:" "$required"

if [ -x "$LOCAL_FLUTTER_BIN" ]; then
  line "Project-local Flutter:" "$LOCAL_FLUTTER_BIN"
  line "  version:" "$("$LOCAL_FLUTTER_BIN" --version 2>/dev/null | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p' | head -1)"
else
  line "Project-local Flutter:" "not installed (run ./scripts/setup_flutter.sh)"
fi

if command -v flutter >/dev/null 2>&1; then
  line "Flutter on PATH:" "$(command -v flutter)"
  line "  version:" "$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p' | head -1)"
else
  line "Flutter on PATH:" "none"
fi

if [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}" ]; then
  line "Android SDK:" "ANDROID_HOME=$ANDROID_HOME"
elif [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "${ANDROID_SDK_ROOT}" ]; then
  line "Android SDK:" "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
elif command -v adb >/dev/null 2>&1 || command -v sdkmanager >/dev/null 2>&1; then
  line "Android SDK:" "tools on PATH (adb/sdkmanager)"
else
  line "Android SDK:" "not detected (APK build will be skipped)"
fi
