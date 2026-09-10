#!/usr/bin/env bash
# Prove a Flatpak user can hand Linthra one music folder and actually use it,
# without the rest of the host coming along (#447).
#
# The flow this exercises, from inside the installed sandbox:
#
#   1. the user selects a folder, and only that folder becomes reachable;
#   2. Linthra scans it, reads its tags and its embedded artwork, and plays a
#      track out of it;
#   3. an unrelated host file and a sibling host directory stay out of reach;
#   4. the same library still works on the next launch;
#   5. when access goes away, Linthra reports a recoverable error and keeps the
#      tracks it had indexed, rather than deciding the library is now empty.
#
# ## What stands in for the portal, and what does not
#
# The grant is `flatpak run --filesystem=<folder>`: one folder, for the length
# of one run, added to no persistent override and to nothing in the package.
# That is the *scope* a document-portal selection produces, and everything
# downstream of the grant (the scan, the metadata, the artwork, the playback,
# the isolation, the revocation) is the real production path.
#
# What it is not is the chooser dialog itself. A portal grant is minted by a
# user clicking a button in xdg-desktop-portal, and no headless runner can
# click it. That step stays a documented manual pass; see
# docs/flatpak-local-library-smoke.md.
#
# The manifest is never widened. `--filesystem=home` and `--filesystem=host`
# are exactly what this test exists to make unnecessary, and
# scripts/check_linux_runner.py still rejects both in the package.
#
# The fixture library is generated into a disposable folder under $HOME and
# deleted on exit. No credentials, no network, no committed media.

set -euo pipefail

APP_ID="io.github.thezupzup.linthra"
REMOTE_NAME="linthra-local-library-smoke-$$"
REPO_PATH="${1:-repo-sandbox-smoke}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MUSIC_DIR=""
SIBLING_DIR=""
SENTINEL_FILE=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v flatpak >/dev/null 2>&1 || fail "flatpak is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"
# The Flutter Linux runner opens a GTK window whatever its Dart entry point
# does, and the artwork fixture is drawn through the real engine.
command -v xvfb-run >/dev/null 2>&1 || fail "xvfb-run is not installed"
command -v dbus-run-session >/dev/null 2>&1 || fail "dbus-run-session is not installed"

SMOKE_COMMAND="$(python3 "$SCRIPT_DIR/make_flatpak_smoke_manifest.py" \
  --print-command local-library)"
[[ -n "$SMOKE_COMMAND" ]] || fail "could not resolve the in-sandbox smoke command"

REPO_PATH="$(cd "$REPO_PATH" && pwd)" || fail "local Flatpak repo not found: $REPO_PATH"
[[ -f "$REPO_PATH/config" ]] || fail "not a Flatpak repository: $REPO_PATH"

if flatpak --user info "$APP_ID" >/dev/null 2>&1 ||
  flatpak --system info "$APP_ID" >/dev/null 2>&1; then
  fail "$APP_ID is already installed; remove it or run this smoke in a clean user environment"
fi

# An existing override would decide the isolation result before the test ran,
# so refuse rather than report a pass that belongs to the override.
for scope in "--user" "--system"; do
  for target in "" "$APP_ID"; do
    # shellcheck disable=SC2086  # $target is deliberately unquoted when empty
    if flatpak override $scope $target --show 2>/dev/null |
      grep -Eq '^[[:space:]]*(filesystems|persistent)='; then
      fail "a $scope override already grants filesystem access; remove it before testing"
    fi
  done
done

[[ -n "${HOME:-}" ]] || fail "HOME is not set"
LOG_FILE="$(mktemp)"

cleanup() {
  rm -f -- "$LOG_FILE" "$SENTINEL_FILE"
  [[ -n "$MUSIC_DIR" && -d "$MUSIC_DIR" ]] && rm -rf -- "$MUSIC_DIR"
  [[ -n "$SIBLING_DIR" && -d "$SIBLING_DIR" ]] && rm -rf -- "$SIBLING_DIR"
  flatpak kill "$APP_ID" >/dev/null 2>&1 || true
  flatpak --user uninstall -y --delete-data "$APP_ID" >/dev/null 2>&1 || true
  flatpak --user remote-delete "$REMOTE_NAME" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

# Music folder paths are private data, and this output ends up in issues.
sanitize() {
  local -a args=(
    -e 's#/run/user/[0-9]\+#/run/user/<uid>#g'
    -e 's#/home/[^/[:space:]"'"'"']\+#/home/<user>#g'
  )
  args+=(-e "s#${HOME//#/\\#}#<home>#g")
  if [[ -n "${USER:-}" ]]; then
    args+=(-e "s#\\b${USER//#/\\#}\\b#<user>#g")
  fi
  sed "${args[@]}"
}

report() {
  sanitize <"$LOG_FILE" >&2
}

# Every sandbox run is time-bounded, for the same reason as the audio smoke:
# the Dart side bounds each step it waits on, but only once Dart is running,
# and a process that blocks before that has nothing watching it. A hung job
# serves no log at all until it ends, so an unbounded run costs the whole job
# timeout and reports nothing.
RUN_TIMEOUT_SECONDS="${LINTHRA_FLATPAK_SMOKE_TIMEOUT:-300}"

# The probes live in $HOME beside the music folder, because that is the case
# worth proving: choosing one folder in your home directory must not hand over
# the rest of it.
MUSIC_DIR="$(mktemp -d "$HOME/linthra-local-library-smoke.XXXXXX")"
SIBLING_DIR="$(mktemp -d "$HOME/linthra-local-library-sibling.XXXXXX")"
SENTINEL_FILE="$(mktemp "$HOME/.linthra-local-library-sentinel.XXXXXX")"
printf 'linthra-host-only\n' >"$SENTINEL_FILE"
chmod 600 "$SENTINEL_FILE"
printf 'linthra-host-only\n' >"$SIBLING_DIR/private-notes.txt"

flatpak --user remote-add --no-gpg-verify "$REMOTE_NAME" "$REPO_PATH"
flatpak --user install -y "$REMOTE_NAME" "$APP_ID"
printf 'Installed %s from local repository %s.\n' "$APP_ID" "$REPO_PATH"

# Bounded like every other run: sandbox startup is where a stall would sit
# unnoticed until the job's own timeout.
probe_status=0
timeout --signal=TERM --kill-after=30 "$RUN_TIMEOUT_SECONDS" \
  flatpak run --command=sh "$APP_ID" -c '[ -x "$1" ]' sh "$SMOKE_COMMAND" ||
  probe_status=$?
if ((probe_status == 124 || probe_status == 137)); then
  flatpak kill "$APP_ID" >/dev/null 2>&1 || true
  fail "checking for $SMOKE_COMMAND hung and was killed after ${RUN_TIMEOUT_SECONDS}s"
fi
if ((probe_status != 0)); then
  fail "$SMOKE_COMMAND is not in the installed package; build the manifest from scripts/make_flatpak_smoke_manifest.py"
fi

# Run one smoke mode inside the sandbox. $2 decides whether the music folder is
# granted for this run; everything else is identical, which is the point of the
# revoked pass.
run_mode() {
  local mode="$1"
  local grant="$2"
  local -a grant_args=()
  if [[ "$grant" == "granted" ]]; then
    grant_args=("--filesystem=$MUSIC_DIR")
  fi

  local status=0
  timeout --signal=TERM --kill-after=30 "$RUN_TIMEOUT_SECONDS" \
    xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' \
    dbus-run-session -- \
    flatpak run \
    "${grant_args[@]}" \
    --env=LINTHRA_LOCAL_LIBRARY_SMOKE_MODE="$mode" \
    --env=LINTHRA_LOCAL_LIBRARY_SMOKE_ROOT="$MUSIC_DIR" \
    --env=LINTHRA_LOCAL_LIBRARY_SMOKE_FORBIDDEN="$SENTINEL_FILE" \
    --env=LINTHRA_LOCAL_LIBRARY_SMOKE_FORBIDDEN_DIR="$SIBLING_DIR" \
    --command="$SMOKE_COMMAND" \
    "$APP_ID" >"$LOG_FILE" 2>&1 || status=$?

  # `timeout` reports 124, or 137 after the SIGKILL escalation. xvfb-run does
  # not necessarily take the sandboxed app with it, and a survivor would hold
  # the app id against the next mode.
  if ((status == 124 || status == 137)); then
    flatpak kill "$APP_ID" >/dev/null 2>&1 || true
    report
    fail "the $mode run hung and was killed after ${RUN_TIMEOUT_SECONDS}s"
  fi
  if ((status != 0)); then
    report
    fail "the local-library smoke failed in $mode mode (status $status)"
  fi
  if ! grep -q "PASS: local-library smoke ($mode) passed." "$LOG_FILE"; then
    report
    fail "the $mode run exited 0 without reporting a pass"
  fi
  sanitize <"$LOG_FILE"
}

# 1. The user's chosen folder gets its fixture library.
printf 'Preparing the selected folder...\n'
run_mode create granted

# 2. Scan it, read its tags and artwork, play from it, and prove nothing else
#    on the host came within reach.
printf 'Scanning the selected folder inside the sandbox...\n'
run_mode scan granted

# 3. The host probes must still be intact and readable *outside* the sandbox.
#    Otherwise "invisible" could mean the smoke deleted them.
[[ -r "$SENTINEL_FILE" ]] ||
  fail "the host sentinel is gone; the isolation result would be meaningless"
[[ -r "$SIBLING_DIR/private-notes.txt" ]] ||
  fail "the sibling host file is gone; the isolation result would be meaningless"
printf 'PASS: both host probes survived, so their invisibility was the sandbox.\n'

# 4. A second launch, a fresh process: the library is still usable while the
#    grant lasts. This is the restart case from the manual audit.
printf 'Re-scanning after a restart...\n'
run_mode scan granted
printf 'PASS: the selected library survived a restart.\n'

# 5. Take the grant away. Same package, same folder path, no access, which is
#    what a revoked portal document, an unplugged drive or a deleted folder all
#    look like from inside.
printf 'Revoking access to the selected folder...\n'
run_mode revoked revoked

printf 'PASS: Flatpak local-library sandbox smoke complete.\n'
