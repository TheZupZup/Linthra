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
REPO_PATH="${1:-repo-audio-smoke}"
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
SMOKE_COMMAND="$(python3 "$SCRIPT_DIR/make_flatpak_smoke_manifest.py" --print-command)"
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

# Every sandbox run is time-bounded, and a run that hits the bound is a
# failure of its own.
#
# The smoke's Dart side bounds each transport step, but that only helps once
# Dart is running. A process that blocks earlier — the loader, the GTK
# realize, media_kit bringing up a libmpv that turns out not to be one — has
# nothing watching it, and neither xvfb-run nor `flatpak run` imposes a limit.
# CI showed what that costs: a job sitting at 56 minutes against a 14-minute
# norm, on its way to the 120-minute job timeout, with no output to read
# because logs are not retrievable until a job ends.
RUN_TIMEOUT_SECONDS="${LINTHRA_FLATPAK_SMOKE_TIMEOUT:-300}"

# Runs one command inside the sandbox, under a display and the bound above,
# capturing everything to $LOG_FILE. Returns the command's status, or 124/137
# when the bound was hit (`timeout` uses 124; 137 is the SIGKILL escalation).
bounded_run() {
  local status=0
  timeout --signal=TERM --kill-after=30 "$RUN_TIMEOUT_SECONDS" \
    xvfb-run --auto-servernum --server-args='-screen 0 1280x720x24' \
    dbus-run-session -- \
    "$@" >"$LOG_FILE" 2>&1 || status=$?

  # xvfb-run does not necessarily take the sandboxed app down with it, and a
  # survivor would hold the app id against the next run.
  if ((status == 124 || status == 137)); then
    flatpak kill "$APP_ID" >/dev/null 2>&1 || true
  fi
  return "$status"
}

timed_out() {
  (($1 == 124 || $1 == 137))
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
# Through bounded_run like everything else: this is a `flatpak run` too, and
# sandbox startup is exactly where a stall would go unnoticed — an unbounded
# probe here would recreate the long, logless hang the bound exists to prevent.
probe_status=0
bounded_run flatpak run --command=sh "$APP_ID" -c '[ -x "$1" ]' sh "$SMOKE_COMMAND" ||
  probe_status=$?
if timed_out "$probe_status"; then
  report
  fail "checking for $SMOKE_COMMAND hung and was killed after ${RUN_TIMEOUT_SECONDS}s"
fi
if ((probe_status != 0)); then
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
bounded_run \
  flatpak run \
  --env=LINTHRA_AUDIO_SMOKE_AO=null \
  --env=LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/app/ \
  --command="$SMOKE_COMMAND" \
  "$APP_ID" || status=$?

if timed_out "$status"; then
  report
  fail "the audio lifecycle smoke hung inside the sandbox and was killed after ${RUN_TIMEOUT_SECONDS}s"
fi
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

# --- negative controls -----------------------------------------------------
#
# A smoke that cannot fail proves nothing, so the two ways this one is supposed
# to catch a broken package are exercised deliberately.
#
# Both run the same binary in the same sandbox with one thing changed, and both
# must fail. `expect_failure` also insists the output names the reason: a
# non-zero exit with no explanation is a failure nobody can act on.
# $3 decides what counts as failing well:
#   named    the run must exit non-zero and its output must match $2
#   bounded  a hang also counts, because the app under test is known to hang
#            rather than exit in this case (see the shadow control below)
expect_failure() {
  local what="$1"
  local pattern="$2"
  local kind="$3"
  shift 3

  local status=0
  bounded_run "$@" || status=$?

  # 3 is the inner script's own "I could not set this control up" exit. A
  # control that did not run is not a control that passed.
  if ((status == 3)); then
    report
    fail "could not set up the negative control: $what"
  fi
  if ((status == 0)); then
    report
    fail "the smoke passed $what, so it cannot detect a broken package"
  fi
  if timed_out "$status"; then
    if [[ "$kind" != "bounded" ]]; then
      report
      fail "the smoke hung $what and was killed after ${RUN_TIMEOUT_SECONDS}s"
    fi
    sanitize <"$LOG_FILE"
    printf 'PASS: %s does not pass the smoke — it hung and was killed after %ss.\n' \
      "$what" "$RUN_TIMEOUT_SECONDS"
    return 0
  fi
  if ! grep -qiE "$pattern" "$LOG_FILE"; then
    report
    fail "the smoke failed $what but never mentioned $pattern, so the failure is not diagnosable"
  fi
  sanitize <"$LOG_FILE"
  printf 'PASS: %s fails the smoke (status %s).\n' "$what" "$status"
}

# 1. A libmpv that loads but is not libmpv.
#
# Two things had to be right here, and the first attempt got both wrong.
#
# *Which* name to shadow: media_kit dlopens "libmpv.so", then "libmpv.so.2",
# then "libmpv.so.1", in that order (media_kit's native_library.dart, and
# scripts/verify_linux.sh documents the same list). Shadowing only the
# versioned soname left the unversioned symlink the package also installs as
# the first candidate, so the real library was opened before the shadow was
# ever consulted. All three names are shadowed.
#
# *What* to put there: a zero-byte file is not a broken library, it is an
# invalid one, and both dlopen and the loader's search treat an unreadable ELF
# header as "not this one" and move on. A valid library under the wrong name is
# what actually gets opened and then cannot supply mpv's symbols.
#
# What the packaged app *does* with such a library is the finding: it hangs. CI
# held one for 46 minutes before the job was cancelled. media_kit takes what
# dlopen gives it and nothing downstream ever concludes that the thing it got
# is not libmpv, so the app sits there with a window open instead of failing.
#
# That is why this control is `bounded` rather than `named`: what it proves is
# that a broken libmpv cannot produce a *passing* smoke, which is the property
# that matters. The run bound is what turns "hangs forever" into a result.
# Proving it fails *promptly* would mean the app checking its own libmpv, which
# is a change to shipped code and belongs in its own issue — not in a test.
#
# The shadow lives in the sandbox's own cache directory and only
# LD_LIBRARY_PATH points at it, so /app is untouched and the next run is
# unaffected.
printf 'Negative control: shadowing the packaged libmpv...\n'
expect_failure "a libmpv that carries none of mpv's symbols" 'libmpv' bounded \
  flatpak run --command=sh "$APP_ID" -c '
    set -eu
    shadow="${XDG_CACHE_HOME:-$HOME/.cache}/linthra-audio-smoke-shadow-libmpv"
    rm -rf -- "$shadow"
    mkdir -p -- "$shadow"

    # Any real shared library will do: the loader checks that a candidate is a
    # loadable ELF, not that its soname matches what was asked for.
    donor=""
    for candidate in \
      /app/lib/libass.so.9 \
      /usr/lib/x86_64-linux-gnu/libz.so.1 \
      /usr/lib/x86_64-linux-gnu/libexpat.so.1 \
      /usr/lib/x86_64-linux-gnu/libpng16.so.16; do
      if [ -f "$candidate" ]; then donor="$candidate"; break; fi
    done
    if [ -z "$donor" ]; then
      donor="$(find /app/lib /usr/lib -maxdepth 2 -name "lib*.so.*" -type f \
        2>/dev/null | grep -v libmpv | head -n 1)"
    fi
    if [ -z "$donor" ]; then
      printf "no donor library to stand in for libmpv\n" >&2
      exit 3
    fi
    # Every name media_kit will try, so the first candidate is the shadow.
    for soname in libmpv.so libmpv.so.2 libmpv.so.1; do
      cp -L "$donor" "$shadow/$soname"
    done

    LINTHRA_AUDIO_SMOKE_AO=null \
    LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/app/ \
    LD_LIBRARY_PATH="$shadow${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      exec "$1"
  ' sh "$SMOKE_COMMAND"

# 2. The identity check itself.
#
# The positive run above requires the loaded libmpv to come from /app/. This
# asks for a prefix nothing can satisfy and requires the run to fail on it, so
# a passing positive run means the check really ran rather than silently
# accepting whatever it found.
printf 'Negative control: requiring a libmpv from somewhere it cannot be...\n'
expect_failure "a libmpv loaded outside the required prefix" 'libmpv' named \
  flatpak run \
  --env=LINTHRA_AUDIO_SMOKE_AO=null \
  --env=LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/nowhere-a-package-installs/ \
  --command="$SMOKE_COMMAND" \
  "$APP_ID"

printf 'PASS: Flatpak audio playback smoke complete.\n'
