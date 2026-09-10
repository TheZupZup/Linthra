#!/usr/bin/env bash
# Verify Linthra's installed Flatpak keeps host files outside the sandbox while
# retaining writable application-scoped XDG storage. This is a host-side smoke
# for issue #439; run it after installing the Flatpak.

set -euo pipefail

APP_ID="io.github.thezupzup.linthra"
HOST_PROBE_DIR=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$HOST_PROBE_DIR" && -d "$HOST_PROBE_DIR" ]]; then
    rm -rf -- "$HOST_PROBE_DIR"
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
flatpak info "$APP_ID" >/dev/null 2>&1 ||
  fail "$APP_ID is not installed; build/install the Flatpak first"

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
