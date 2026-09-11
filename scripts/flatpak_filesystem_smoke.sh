#!/usr/bin/env bash
# Verify Linthra's installed Flatpak keeps host files outside the sandbox while
# retaining writable application-scoped XDG storage (#439), and that the
# permissions the package actually carries are the ones with a written
# rationale (#455).
#
# Two ways to run it:
#
#   scripts/flatpak_filesystem_smoke.sh repo-ci   installs the package from
#                                                 that local repository and
#                                                 uninstalls it afterwards
#   scripts/flatpak_filesystem_smoke.sh           uses whatever is already
#                                                 installed, and leaves it
#
# The first is what CI runs, and it is why this script exists in a workflow at
# all. Until it was wired up, the only caller of
# `check_flatpak_permissions.py --installed` was this file, and nothing ran
# this file: CI checked the two manifests and never the artifact. A manifest
# says what was asked for. Only the package says what was granted, and the
# package is what a user installs.

set -euo pipefail

APP_ID="io.github.thezupzup.linthra"
REPO_PATH="${1:-}"
REMOTE_NAME="linthra-fs-smoke-$$"
HOST_PROBE_DIR=""
INSTALLED_HERE=0

# Whether the app's private data tree is already on this machine, checked
# before anything is installed. Uninstalling a Flatpak does not remove
# ~/.var/app, so a contributor who removed an older Linthra build without
# deleting its data still has their library database, settings and credentials
# sitting there. Whether this script may take that tree with it depends
# entirely on whether it was here first.
APP_DATA_DIR="$HOME/.var/app/$APP_ID"
APP_DATA_EXISTED=0
[[ -e "$APP_DATA_DIR" ]] && APP_DATA_EXISTED=1

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$HOST_PROBE_DIR" && -d "$HOST_PROBE_DIR" ]]; then
    rm -rf -- "$HOST_PROBE_DIR"
  fi
  # Only ever undo an installation this script made. Somebody reproducing a
  # failure locally against their own build must not lose it.
  if (( INSTALLED_HERE )); then
    flatpak kill "$APP_ID" >/dev/null 2>&1 || true
    flatpak --user uninstall -y "$APP_ID" >/dev/null 2>&1 || true

    # And only ever delete app data this run created.
    # docs/flatpak-development.md calls --delete-data Destructive because it
    # is: it wipes the Flatpak install's settings, library database and cache.
    # Refusing to run against an existing *installation* is not enough, since
    # the data tree outlives an ordinary uninstall. A script that borrows the
    # machine for ten seconds has no business emptying it.
    #
    # Removed directly rather than with `uninstall --delete-data`, because that
    # flag reaches further than the tree checked above: it also drops the app's
    # entries from Flatpak's permission store, which lives outside ~/.var/app
    # and holds the document-portal grants for the music folders a user picked.
    # A guard about the data tree has to authorise an action about the data
    # tree, or the check is narrower than what it permits.
    if (( ! APP_DATA_EXISTED )) && [[ -d "$APP_DATA_DIR" ]]; then
      rm -rf -- "$APP_DATA_DIR"
    fi
    flatpak --user remote-delete "$REMOTE_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

check_override_scope() {
  local label="$1"
  shift
  local overrides

  # This audit is only meaningful if every effective override scope can be
  # inspected. Fail closed on an unreadable/broken user or system override
  # instead of treating a failed query as an empty, therefore clean, scope.
  if ! overrides="$(flatpak override "$@" --show 2>&1)"; then
    printf '%s\n' "$overrides" >&2
    fail "could not inspect $label; refusing to assume the scope is clean"
  fi

  if grep -Eq '^[[:space:]]*(filesystems|persistent)=' <<<"$overrides"; then
    printf '%s\n' "$overrides" >&2
    fail "$label contains a filesystem/persist override; remove it before testing"
  fi
}

command -v flatpak >/dev/null 2>&1 || fail "flatpak is not installed"

if [[ -n "$REPO_PATH" ]]; then
  REPO_PATH="$(cd "$REPO_PATH" && pwd)" || fail "local Flatpak repo not found: $REPO_PATH"
  [[ -f "$REPO_PATH/config" ]] || fail "not a Flatpak repository: $REPO_PATH"

  # Never test, replace or remove an installation this script did not make:
  # an older build would answer these questions about the wrong package.
  if flatpak --user info "$APP_ID" >/dev/null 2>&1 ||
    flatpak --system info "$APP_ID" >/dev/null 2>&1; then
    fail "$APP_ID is already installed; remove it or run this smoke in a clean user environment"
  fi

  # A uniquely named remote pointing only at the unsigned repository this same
  # CI job produced. --no-gpg-verify must never be used for Flathub or another
  # public remote.
  flatpak --user remote-add --no-gpg-verify "$REMOTE_NAME" "$REPO_PATH"
  INSTALLED_HERE=1
  flatpak --user install -y "$REMOTE_NAME" "$APP_ID"
  printf 'Installed %s from local repository %s.\n' "$APP_ID" "$REPO_PATH"
fi

flatpak info "$APP_ID" >/dev/null 2>&1 ||
  fail "$APP_ID is not installed; build/install the Flatpak first, or pass a local repository path"

permissions="$(flatpak info --show-permissions "$APP_ID")"

# Flatpak metadata renders filesystem grants as filesystems= and persist grants
# as persistent=. Either one would invalidate #439's no-host-filesystem policy.
if grep -Eq '^[[:space:]]*filesystems=' <<<"$permissions"; then
  printf '%s\n' "$permissions" >&2
  fail "the installed package declares a filesystem permission"
fi
if grep -Eq '^[[:space:]]*persistent=' <<<"$permissions"; then
  printf '%s\n' "$permissions" >&2
  fail "the installed package declares a persist permission"
fi

# Effective permissions can be widened outside the package metadata at four
# levels: global user, app-specific user, global system, and app-specific
# system overrides. Reject filesystem/persist entries in every scope. Otherwise
# a globally granted xdg-music/home path could make a clean package look safely
# sandboxed while this smoke was actually exercising the local override.
# A query failure is also fatal: an unreadable/broken scope is unknown, not clean.
check_override_scope "global user override" --user
check_override_scope "app-specific user override" --user "$APP_ID"
check_override_scope "global system override" --system
check_override_scope "app-specific system override" --system "$APP_ID"

case "$HOME" in
  "$HOME/.var/app/$APP_ID"|"$HOME/.var/app/$APP_ID/"*)
    fail "host HOME unexpectedly points inside the Flatpak app-data tree"
    ;;
esac

HOST_PROBE_DIR="$(mktemp -d "$HOME/.linthra-flatpak-fs-smoke.XXXXXX")"
HOST_SENTINEL="$HOST_PROBE_DIR/host-only-sentinel"
printf 'linthra-flatpak-host-only\n' > "$HOST_SENTINEL"
chmod 600 "$HOST_SENTINEL"

# Pass the absolute host path as data only. With no --filesystem grant the
# sandbox must not be able to stat/read it. Then prove the private XDG data and
# cache locations are writable: Linthra's SQLite catalog, artwork/remote cache,
# and offline-audio stores use path_provider locations mapped into this private
# app tree by Flatpak.
if ! flatpak run --command=sh "$APP_ID" -c '
  set -eu
  host_sentinel="$1"

  if [ -e "$host_sentinel" ] || [ -r "$host_sentinel" ]; then
    printf "host sentinel unexpectedly visible: %s\n" "$host_sentinel" >&2
    exit 42
  fi

  : "${XDG_DATA_HOME:?XDG_DATA_HOME is not set inside the sandbox}"
  : "${XDG_CACHE_HOME:?XDG_CACHE_HOME is not set inside the sandbox}"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

  data_probe="$XDG_DATA_HOME/.linthra-fs-smoke-$$"
  cache_probe="$XDG_CACHE_HOME/.linthra-fs-smoke-$$"
  trap '\''rm -f -- "$data_probe" "$cache_probe"'\'' EXIT

  printf data > "$data_probe"
  printf cache > "$cache_probe"
  test -r "$data_probe"
  test -r "$cache_probe"
' sh "$HOST_SENTINEL"; then
  fail "sandbox isolation/app-data write smoke failed"
fi

# The checks above are about filesystem access specifically. #455 asks the
# wider question: does the *installed* package carry exactly the permission set
# that has a written rationale, and nothing else? A manifest says what was asked
# for; this says what was built.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
  python3 "$SCRIPT_DIR/check_flatpak_permissions.py" --installed ||
    fail "the installed package's permissions do not match their rationale"
else
  fail "python3 is not installed, so the installed permission set was not checked"
fi

printf 'PASS: %s declares no filesystem/persist grant.\n' "$APP_ID"
printf 'PASS: global/app user and system overrides add no filesystem/persist grant.\n'
printf 'PASS: unrelated host file was invisible inside the sandbox.\n'
printf 'PASS: sandbox-local XDG data and cache locations are writable.\n'
printf 'PASS: the installed permission set matches docs/flatpak-permissions.md.\n'
printf 'Manual portal-selected library validation: docs/flatpak-filesystem-audit.md\n'
