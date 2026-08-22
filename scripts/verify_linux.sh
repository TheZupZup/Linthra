#!/usr/bin/env bash
#
# verify_linux.sh — run the Linux desktop checks locally, the way CI runs them.
#
# The twin of scripts/verify_android.sh, for the other platform. Order mirrors
# .github/workflows/linux-desktop-build.yml:
#
#   flutter pub get --enforce-lockfile  ->  dart format (check)  ->
#   flutter analyze  ->  flutter test  ->  Linux runner config check  ->
#   native audio lifecycle smoke (build + run) -> flutter build linux --release
#
# The shared checks (format/analyze/test) are deliberately repeated here rather
# than delegated: someone working on the desktop build should be able to run one
# script and know whether they broke anything, without also remembering to run
# the Android one.
#
# Native toolchain: `flutter build linux` needs clang, cmake, ninja, pkg-config
# and the GTK 3 development headers, plus libsecret for encrypted credential
# storage. `just_audio_media_kit`/media_kit additionally dlopen the libmpv
# runtime at process startup (lib/core/services/linux_playback_controller.dart)
# rather than link it at build time, so a build can "succeed" on a machine that
# cannot actually play audio. All of these are checked up front and a missing
# one *skips* the build and the audio smoke test with a clear message instead
# of failing the whole script — the same shape as verify_android.sh skipping
# the APK when there is no Android SDK. See docs/linux-desktop.md for the
# Fedora, Debian/Ubuntu and Arch package names.
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

# Whether the libmpv runtime that media_kit/just_audio_media_kit dlopen at
# startup can actually be loaded. media_kit resolves it by trying
# DynamicLibrary.open() against "libmpv.so", then "libmpv.so.2", then
# "libmpv.so.1", in that order (media_kit's
# lib/src/player/native/core/native_library.dart) — it is a runtime dlopen,
# not a build-time link, so `flutter build linux` succeeds without it and a
# pkg-config module name (which describes the *development* package, and
# isn't consistently named across distributions) would not actually tell us
# whether that dlopen will work. Probing with the same libc call media_kit
# uses is the reliable check.
libmpv_runtime_available() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - <<'PY'
import ctypes
import sys

for name in ("libmpv.so", "libmpv.so.2", "libmpv.so.1"):
    try:
        ctypes.CDLL(name)
    except OSError:
        continue
    else:
        sys.exit(0)
sys.exit(1)
PY
}

# Report the native build/runtime prerequisites that are missing, one per
# line. Empty output means the Linux build and the audio smoke test can run.
missing_native_deps() {
  local missing=()
  local tool
  for tool in clang cmake ninja pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if command -v pkg-config >/dev/null 2>&1; then
    pkg-config --exists gtk+-3.0 || missing+=("gtk+-3.0 development headers")
    pkg-config --exists libsecret-1 || missing+=("libsecret-1 development headers")
  fi
  libmpv_runtime_available ||
    missing+=("libmpv runtime (libmpv.so / libmpv.so.2 / libmpv.so.1)")
  printf '%s\n' "${missing[@]+"${missing[@]}"}"
}

# Mirrors the CI job's "Run native audio lifecycle smoke" step: run the bundle
# that "Build native audio lifecycle smoke" just produced from
# tool/linux_audio_backend_smoke.dart. CI always runs it under xvfb-run
# because its runner is headless; locally, prefer xvfb-run when present so the
# behaviour matches CI exactly, but fall back to running it directly, since a
# developer's machine already has a real display CI doesn't.
run_audio_smoke() {
  local binary="$REPO_ROOT/build/linux/x64/release/bundle/linthra"
  local alsa_null_conf
  alsa_null_conf="$(mktemp)"
  trap 'rm -f "$alsa_null_conf"' RETURN
  printf '%s\n' \
    'pcm.!default { type plug; slave.pcm "null" }' \
    'pcm.null { type null }' \
    'ctl.!default { type null }' \
    > "$alsa_null_conf"
  if command -v xvfb-run >/dev/null 2>&1; then
    ALSA_CONFIG_PATH="$alsa_null_conf" xvfb-run --auto-servernum "$binary"
  else
    ALSA_CONFIG_PATH="$alsa_null_conf" "$binary"
  fi
}

FAILED=()

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

  run_step "flutter pub get --enforce-lockfile" "$FLUTTER" pub get --enforce-lockfile
  run_step "dart format --set-exit-if-changed ." dart format --set-exit-if-changed .
  run_step "flutter analyze" "$FLUTTER" analyze
  run_step "flutter test" "$FLUTTER" test

  # Flutter-independent: the committed runner still matches the app's identity
  # and can still build without a network. Cheap, so it runs before the build.
  run_step "Linux runner configuration" python3 scripts/check_linux_runner.py
  run_step "Linux runner tooling tests" python3 test/tooling/check_linux_runner_test.py

  # Read line by line: a dependency name can contain spaces ("gtk+-3.0
  # development headers"), so word splitting would mangle the report.
  local missing=()
  local dep
  while IFS= read -r dep; do
    [ -n "$dep" ] && missing+=("$dep")
  done < <(missing_native_deps)

  if [ "${#missing[@]}" -eq 0 ]; then
    # A normal Flutter widget test cannot load the Linux plugin bundle, so
    # this target runs in the real GTK runner and opens a silent local WAV
    # through libmpv in three play → stop → dispose cycles — the same smoke CI runs.
    run_step "Build native audio lifecycle smoke" \
      "$FLUTTER" build linux --release \
      --target=tool/linux_audio_backend_smoke.dart
    run_step "Run native audio lifecycle smoke" run_audio_smoke

    run_step "flutter build linux --release" "$FLUTTER" build linux --release
  else
    warn "Missing native Linux build/runtime dependencies:"
    printf '  - %s\n' "${missing[@]}" >&2
    warn "Skipping the native audio lifecycle smoke and"
    warn "'flutter build linux --release'. See docs/linux-desktop.md for the"
    warn "packages to install. analyze/format/tests still ran above."
  fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    info "Verification FAILED (${#FAILED[@]} step(s)):"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi

  info "Verification passed."
}

main "$@"
