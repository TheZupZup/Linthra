#!/usr/bin/env bash
#
# verify_android.sh — run the same checks CI runs, locally.
#
# Order mirrors .github/workflows/ci.yml:
#   flutter pub get  ->  dart format (check)  ->  flutter analyze  ->  flutter test
#
# If an Android SDK is available it additionally builds a debug APK. A missing
# Android SDK only skips the APK build — it never fails verification. Any real
# failure (pub get / format / analyze / tests / APK build) makes this script
# exit non-zero.
#
# Flutter resolution: prefer the project-local SDK from setup_flutter.sh
# (.tool/flutter), otherwise fall back to Flutter on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOCAL_FLUTTER_BIN="$REPO_ROOT/.tool/flutter/bin/flutter"

info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Pick a Flutter binary and put its bin dir on PATH so `dart` resolves too.
resolve_flutter() {
  if [ -x "$LOCAL_FLUTTER_BIN" ]; then
    FLUTTER="$LOCAL_FLUTTER_BIN"
    PATH="$(dirname "$LOCAL_FLUTTER_BIN"):$PATH"
    export PATH
    info "Using project-local Flutter: $FLUTTER"
  elif command -v flutter >/dev/null 2>&1; then
    FLUTTER="$(command -v flutter)"
    info "Using Flutter from PATH: $FLUTTER"
  else
    die "Flutter not found. Run ./scripts/setup_flutter.sh first."
  fi
  "$FLUTTER" --version | head -1 || true
}

android_sdk_available() {
  if [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}" ]; then return 0; fi
  if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "${ANDROID_SDK_ROOT}" ]; then return 0; fi
  command -v sdkmanager >/dev/null 2>&1 && return 0
  command -v adb >/dev/null 2>&1 && return 0
  return 1
}

FAILED=()

# Run a labelled step; record (but don't abort on) failure so the contributor
# sees every problem in one pass. Returns the step's own exit status.
run_step() {
  local label="$1"; shift
  info "$label"
  if "$@"; then
    return 0
  fi
  warn "FAILED: $label"
  FAILED+=("$label")
  return 1
}

main() {
  cd "$REPO_ROOT"
  resolve_flutter

  run_step "flutter pub get" "$FLUTTER" pub get
  run_step "dart format --set-exit-if-changed ." dart format --set-exit-if-changed .
  run_step "flutter analyze" "$FLUTTER" analyze
  run_step "flutter test" "$FLUTTER" test

  if android_sdk_available; then
    run_step "flutter build apk --debug" "$FLUTTER" build apk --debug
  else
    warn "Android SDK not detected (ANDROID_HOME/ANDROID_SDK_ROOT unset, no sdkmanager/adb)."
    warn "Skipping 'flutter build apk --debug'. analyze/format/tests still ran above."
  fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    info "Verification FAILED (${#FAILED[@]} step(s)):"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi

  info "Verification passed."
}

main "$@"
