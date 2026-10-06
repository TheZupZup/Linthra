#!/usr/bin/env bash
#
# update_dart_dependencies.sh — re-resolve Linthra's Dart/Flutter packages with
# the pinned Flutter SDK and leave a validated pubspec.lock behind.
#
# This is the local twin of the "Dart dependency updates" workflow. Running it
# by hand produces exactly the lockfile that workflow would commit, which is the
# point: the reproducible F-Droid build resolves from the committed pubspec.lock
# (docs/release-process.md §7), so the lockfile has to come from the SDK this
# repo is actually pinned to and not from whatever Dart happens to be on PATH.
#
#   ./scripts/setup_flutter.sh                    # install the pinned SDK
#   export PATH="$PWD/.tool/flutter/bin:$PATH"
#   ./scripts/update_dart_dependencies.sh
#
# What it runs, and why that command:
#
#   flutter pub upgrade
#
# `pub upgrade` re-resolves every dependency to the newest version the existing
# constraints in pubspec.yaml already allow, and writes pubspec.lock (Flutter
# also regenerates the plugin registrants when the set of plugins changes, which
# the guard below refuses). That
# is the whole "compatible updates, no constraint changes" behaviour by
# construction — `^0.9.42` cannot resolve to 0.10.0, `^11.3.1` cannot resolve to
# 12.0.0. Note that `--major-versions=false` does NOT exist: `--major-versions`
# is a non-negatable flag, and passing it a value fails with
#   Flag option "--major-versions" should not be given a value.
# (exit 64). The flag's actual job is the opposite of what we want here — it
# rewrites the constraints in pubspec.yaml so majors can be pulled in. Plain
# `pub upgrade` is the "no majors, no constraint edits" command.
#
# Transitive packages are a deliberate exception: pubspec.yaml does not
# constrain them, so a lockfile refresh can and does move them across major
# versions (the analyzer/build/source_gen chain behind drift_dev, for example).
# That is what a lockfile refresh is. It is bounded by the pinned SDK and by
# what the direct constraints admit, and it is exactly why this ends in a
# reviewed PR that runs the normal checks instead of a silent commit.
#
# Exit codes:
#
#   0  pubspec.lock was updated and passed every guard
#   3  already up to date — nothing changed, nothing to do
#   1  a guard failed, or the run could not complete
#
# Options:
#
#   --output-dir DIR   Write summary.md (a Markdown report of what moved) and
#                      upgrade.log (the raw `pub upgrade` output) into DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$REPO_ROOT/.flutter-version"
LOCKFILE="pubspec.lock"

# Packages worth calling out by name when they move. Not a resolution rule —
# pub already resolves the graph as one consistent set, so nothing here needs
# artificial grouping. These are the ones whose bump CI cannot fully judge:
# native/plugin code that only a real Android build exercises, the code
# generator behind the committed *.g.dart files, and the SQLite engine the
# reproducible F-Droid build ships.
WATCHED=(
  just_audio just_audio_platform_interface
  audio_service audio_service_platform_interface
  audio_session
  drift drift_dev sqlparser
  sqlite3 sqlite3_flutter_libs
  flutter_secure_storage
  permission_handler
  file_picker
  cast bonsoir
)

output_dir=""

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ "$#" -ge 2 ] || die "--output-dir needs a directory"
      output_dir="$2"
      shift 2 ;;
    --output-dir=*)
      output_dir="${1#--output-dir=}"
      shift ;;
    -h|--help)
      sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
      exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

if [ -n "$output_dir" ]; then
  mkdir -p "$output_dir" || die "cannot create $output_dir"
  output_dir="$(cd "$output_dir" && pwd)"
fi

# --- 1. resolve with the pinned SDK, or not at all --------------------------

command -v flutter >/dev/null 2>&1 \
  || die "flutter is not on PATH. Run ./scripts/setup_flutter.sh first, then
       export PATH=\"$REPO_ROOT/.tool/flutter/bin:\$PATH\""

[ -f "$VERSION_FILE" ] || die "missing $VERSION_FILE (the pinned Flutter version)"
required="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$required" ] || die "$VERSION_FILE is empty"

actual="$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p' | head -1)"
[ -n "$actual" ] || die "could not read the version of the Flutter on PATH"

if [ "$actual" != "$required" ]; then
  die "Flutter on PATH is $actual but this repo is pinned to $required.
       The committed lockfile has to be resolved with the pinned SDK — a
       different SDK resolves a different set and quietly breaks the
       reproducible F-Droid build. Run ./scripts/setup_flutter.sh."
fi
info "Resolving with the pinned Flutter $actual"

# --- 2. refuse to work on a dirty tree --------------------------------------

# Every guard below asks "what did this script change?", and git is what answers
# it — so a checkout is a hard requirement, not a nicety.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$REPO_ROOT is not a git working tree; the changed-file guard cannot run."

# The honest answer only exists when nothing else was already changed.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  git status --short --untracked-files=no >&2
  die "the working tree has uncommitted changes. Commit or stash them first —
       this script has to be able to attribute every changed file to itself."
fi

# --- 3. upgrade inside the existing constraints -----------------------------

upgrade_log="$(mktemp "${TMPDIR:-/tmp}/pub-upgrade.XXXXXX")"
trap 'rm -f "$upgrade_log"' EXIT

info "flutter pub upgrade"
if ! flutter pub upgrade 2>&1 | tee "$upgrade_log"; then
  die "flutter pub upgrade failed; see the output above."
fi

# --- 4. nothing changed? then there is nothing to do ------------------------

# The report directory is this script's own output, not a repository change,
# so drop it when it was pointed somewhere inside the checkout.
out_rel=""
if [ -n "$output_dir" ]; then
  case "$output_dir/" in
    "$REPO_ROOT"/*) out_rel="${output_dir#"$REPO_ROOT"/}" ;;
  esac
fi

changed=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ -n "$out_rel" ]; then
    case "$path" in
      "$out_rel"|"$out_rel"/*) continue ;;
    esac
  fi
  changed="${changed}${path}"$'\n'
done < <(git status --porcelain --untracked-files=normal | sed 's/^...//')
changed="${changed%$'\n'}"

if [ -z "$changed" ]; then
  info "pubspec.lock is already at the newest versions the constraints allow."
  [ -n "$output_dir" ] && cp "$upgrade_log" "$output_dir/upgrade.log"
  exit 3
fi

# --- 5. only pubspec.lock may have moved ------------------------------------

info "Checking the changed files against the allowlist"
if ! printf '%s\n' "$changed" | "$SCRIPT_DIR/check_dependency_update_files.sh"; then
  die "the upgrade changed files an automatic update is not allowed to change.
       Nothing has been committed. Inspect the diff and handle it by hand."
fi

# --- 6. the lockfile must satisfy the unchanged constraints -----------------

# The same command ci.yml runs. If a lockfile we just generated cannot satisfy
# --enforce-lockfile, the artifact itself is broken, so stop here rather than
# opening a PR that is red for a reason nobody needs to review.
info "flutter pub get --enforce-lockfile"
flutter pub get --enforce-lockfile \
  || die "the freshly resolved lockfile fails --enforce-lockfile. This is a bug
       in the resolution, not a dependency that needs review; not proceeding."

# --- 7. report what moved ---------------------------------------------------

# `pub upgrade` already prints the moves; "> name new (was old)" is a change,
# "+ name" an addition, "- name" a removal. Reuse that rather than re-deriving
# it from the lockfile diff.
moves="$(grep -E '^[>+-] [a-z0-9_]+ ' "$upgrade_log" || true)"
moved_names="$(printf '%s\n' "$moves" | awk '{print $2}' | sort -u)"

watched_hits=()
for pkg in "${WATCHED[@]}"; do
  if printf '%s\n' "$moved_names" | grep -qx "$pkg"; then
    watched_hits+=("$pkg")
  fi
done

count="$(printf '%s\n' "$moves" | grep -c . || true)"
info "$count package(s) changed in $LOCKFILE"
if [ "${#watched_hits[@]}" -gt 0 ]; then
  info "Native/codegen packages moved: ${watched_hits[*]}"
fi

if [ -n "$output_dir" ]; then
  cp "$upgrade_log" "$output_dir/upgrade.log"
  {
    echo "### Resolved with Flutter $required"
    echo
    echo "\`flutter pub upgrade\` — inside the existing \`pubspec.yaml\` constraints,"
    echo "so no constraint changed and no direct dependency crossed a major version."
    echo
    if [ "${#watched_hits[@]}" -gt 0 ]; then
      echo "### Needs a closer look"
      echo
      echo "These moved, and the Flutter checks job cannot fully judge them — it"
      echo "does not build an APK, and it does not regenerate the committed Drift"
      echo "output:"
      echo
      for pkg in "${watched_hits[@]}"; do
        echo "- \`$pkg\`"
      done
      echo
    fi
    echo "### Package changes"
    echo
    echo '```text'
    printf '%s\n' "$moves"
    echo '```'
  } > "$output_dir/summary.md"
  info "Wrote $output_dir/summary.md"
fi

info "Done. $LOCKFILE is updated and validated; nothing has been committed."
exit 0
