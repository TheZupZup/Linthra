#!/usr/bin/env bash
# Run Linthra's Linux audio lifecycle smoke from inside an installed Flatpak
# (#446), so a packaging mistake in the audio stack fails here rather than on a
# user's machine.
#
# The lifecycle itself — initialize, load, play, pause, seek, stop, dispose —
# lives in tool/linux_audio_backend_smoke.dart and is the same code the native
# Linux workflow runs. This script is only the sandbox harness around it: it
# installs the package from a local repository, runs the smoke inside it, and
# then proves the smoke would have noticed a broken libmpv.
#
# Two properties make the run meaningful:
#
#   * The smoke is told the packaged libmpv is the only acceptable one
#     (LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/app/). It reads back what the
#     loader actually mapped, so a libmpv from anywhere else fails the run
#     instead of quietly standing in for one the package forgot to ship.
#   * The negative control shadows that library with an unloadable file and
#     requires the smoke to fail, naming libmpv. A test that cannot fail proves
#     nothing, and this is the failure mode the whole exercise is about.
#
# The package this needs is built from the manifest that
# scripts/make_flatpak_smoke_manifest.py derives from the submission manifest:
# the same runtime, modules, sources and permissions, plus the smoke binary
# under /app/libexec. See docs/flatpak-audio-smoke.md.
#
# No credentials, no network, no committed media: the fixture is PCM the smoke
# generates into the sandbox's own temp directory at startup.

set -euo pipefail

APP_ID="io.github.thezupzup.linthra"
REMOTE_NAME="linthra-audio-smoke-$$"
REPO_PATH="${1:-repo-sandbox-smoke}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v flatpak >/dev/null 2>&1 || fail "flatpak is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"
# The Flutter Linux runner opens a GTK window whatever its Dart entry point
# does, so the smoke needs a display exactly like the native workflow's run.
command -v xvfb-run >/dev/null 2>&1 || fail "xvfb-run is not installed"
command -v dbus-run-session >/dev/null 2>&1 || fail "dbus-run-session is not installed"

# Asking the generator keeps this in step with the manifest it writes.
SMOKE_COMMAND="$(python3 "$SCRIPT_DIR/make_flatpak_smoke_manifest.py" --print-command audio)"
[[ -n "$SMOKE_COMMAND" ]] || fail "could not resolve the in-sandbox smoke command"

REPO_PATH="$(cd "$REPO_PATH" && pwd)" || fail "local Flatpak repo not found: $REPO_PATH"
[[ -f "$REPO_PATH/config" ]] || fail "not a Flatpak repository: $REPO_PATH"

# Never replace or remove a contributor's existing Linthra installation, and
# never test one: a previously installed build would answer these questions
# about the wrong package.
if flatpak --user info "$APP_ID" >/dev/null 2>&1 ||
  flatpak --system info "$APP_ID" >/dev/null 2>&1; then
  fail "$APP_ID is already installed; remove it or run this smoke in a clean user environment"
fi

LOG_FILE="$(mktemp)"

cleanup() {
  rm -f -- "$LOG_FILE"
  flatpak kill "$APP_ID" >/dev/null 2>&1 || true
  # --delete-data takes the sandbox's own XDG tree with it, including the
  # negative control's shadow directory. Safe because this script refused to
  # start against an installation it did not make.
  flatpak --user uninstall -y --delete-data "$APP_ID" >/dev/null 2>&1 || true
  flatpak --user remote-delete "$REMOTE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Strip host identity out of anything captured before it reaches a log or an
# issue. libmpv quotes paths in its own errors and the sandbox still sees the
# host's HOME string, so the login name travels further than people expect.
sanitize() {
  local -a args=(
    -e 's#/run/user/[0-9]\+#/run/user/<uid>#g'
    -e 's#/home/[^/[:space:]"'"'"']\+#/home/<user>#g'
  )
  if [[ -n "${HOME:-}" ]]; then
    args+=(-e "s#${HOME//#/\\#}#<home>#g")
  fi
  if [[ -n "${USER:-}" ]]; then
    args+=(-e "s#\\b${USER//#/\\#}\\b#<user>#g")
  fi
  sed "${args[@]}"
}

report() {
  sanitize <"$LOG_FILE" >&2
}

# This uniquely named remote points only at the unsigned repository produced by
# the same CI job. --no-gpg-verify must never be used for Flathub or another
# public remote.
flatpak --user remote-add --no-gpg-verify "$REMOTE_NAME" "$REPO_PATH"
flatpak --user install -y "$REMOTE_NAME" "$APP_ID"
printf 'Installed %s from local repository %s.\n' "$APP_ID" "$REPO_PATH"

# A missing smoke binary means the package was built from the submission
# manifest rather than the derived one. Say so, instead of failing later with
# an opaque "command not found" from inside the sandbox.
if ! flatpak run --command=sh "$APP_ID" -c '[ -x "$1" ]' sh "$SMOKE_COMMAND"; then
  fail "$SMOKE_COMMAND is not in the installed package; build the manifest from scripts/make_flatpak_smoke_manifest.py"
fi

# --- the real run ----------------------------------------------------------
#
# ao=null is libmpv's own discard-audio output. Neither CI runner has a sound
# device, so this is what keeps the decode, clock, seek and transport paths
# real without one. It does not prove a speaker makes a sound; that stays a
# manual check (docs/flatpak-audio-smoke.md).
printf 'Running the audio lifecycle smoke inside the sandbox...\n'
status=0
xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' \
  dbus-run-session -- \
  flatpak run \
  --env=LINTHRA_AUDIO_SMOKE_AO=null \
  --env=LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/app/ \
  --command="$SMOKE_COMMAND" \
  "$APP_ID" >"$LOG_FILE" 2>&1 || status=$?

if ((status != 0)); then
  report
  fail "the audio lifecycle smoke failed inside the sandbox (status $status)"
fi
if ! grep -q 'PASS: Linux native audio lifecycle smoke passed.' "$LOG_FILE"; then
  report
  fail "the audio lifecycle smoke exited 0 without reporting a pass"
fi
if ! grep -q 'libmpv in use: /app/' "$LOG_FILE"; then
  report
  fail "the smoke did not report a packaged libmpv"
fi
sanitize <"$LOG_FILE"
printf 'PASS: the packaged %s completed the audio lifecycle on its own libmpv.\n' \
  "$APP_ID"

# --- negative control ------------------------------------------------------
#
# Shadow the packaged libmpv with a zero-byte file the loader cannot accept,
# and require the smoke to fail. The shadow lives in the sandbox's own cache
# directory and only LD_LIBRARY_PATH points at it, so /app is untouched and the
# next run is unaffected.
printf 'Negative control: breaking the packaged libmpv...\n'
status=0
xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' \
  dbus-run-session -- \
  flatpak run --command=sh "$APP_ID" -c '
    set -eu
    shadow="$XDG_CACHE_HOME/linthra-audio-smoke-broken-libmpv"
    rm -rf -- "$shadow"
    mkdir -p -- "$shadow"
    : >"$shadow/libmpv.so.2"
    LINTHRA_AUDIO_SMOKE_AO=null \
    LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/app/ \
    LD_LIBRARY_PATH="$shadow${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      exec "$1"
  ' sh "$SMOKE_COMMAND" >"$LOG_FILE" 2>&1 || status=$?

if ((status == 0)); then
  report
  fail "the smoke passed with an unloadable libmpv, so it cannot detect a broken package"
fi
if ! grep -qi 'libmpv' "$LOG_FILE"; then
  report
  fail "the smoke failed with a broken libmpv but never mentioned it, so the failure is not diagnosable"
fi
sanitize <"$LOG_FILE"
printf 'PASS: a broken libmpv fails the smoke, naming libmpv (status %s).\n' "$status"

printf 'PASS: Flatpak audio playback smoke complete.\n'
