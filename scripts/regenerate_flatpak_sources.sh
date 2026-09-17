#!/usr/bin/env bash
#
# regenerate_flatpak_sources.sh — regenerate flatpak/io.github.thezupzup.linthra.yml
# and flatpak/generated/ from flatpak/flatpak-flutter.yml and the committed
# pubspec.lock / .flutter-version, using flatpak-flutter
# (https://github.com/TheAppgineer/flatpak-flutter — the tool referenced by
# Flutter's own deployment docs and by flatpak/flatpak-builder-tools).
#
# Run this whenever .flutter-version or pubspec.lock changes. Network access
# is required (it queries pub.dev and storage.googleapis.com to pin every
# dependency by URL + sha256) — that's the same one-time, declared-source
# generation step as running `flutter pub get` to produce pubspec.lock itself,
# not the sandboxed build flatpak-builder later runs offline. See
# flatpak/README.md and docs/flatpak-source-pinning.md.
#
# The output is checked before this script exits: scripts/check_flatpak_sources.py
# re-reads what was just written and refuses a source that is not pinned to a
# commit or a sha256 (#443). Generating a floating source should fail here,
# while the diff is still in front of you, rather than in CI later.
#
# Usage: ./scripts/regenerate_flatpak_sources.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLATPAK_DIR="$REPO_ROOT/flatpak"
TOOL_DIR="$REPO_ROOT/.tool/flatpak-flutter"
VENV_DIR="$REPO_ROOT/.tool/flatpak-flutter-venv"
TOOL_REPO="https://github.com/TheAppgineer/flatpak-flutter.git"
# Pinned to the exact commit tagged 0.15.0 upstream (verified:
# `git rev-parse 0.15.0^{commit}` on that repo resolves to this SHA). Pinned
# by commit rather than by tag name alone, since a tag can be moved or
# deleted upstream but a commit SHA cannot — this generator must never
# silently track a moving main/HEAD. Bump deliberately, re-verifying the new
# SHA against its tag, when picking up an upstream flatpak-flutter release.
TOOL_COMMIT="e59a96fcb0fcf48fcd46e8134cae64c26fdc3290"

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [ ! -d "$TOOL_DIR" ]; then
  info "Fetching flatpak-flutter (dev tool, not a build-time dependency), pinned to $TOOL_COMMIT"
  mkdir -p "$TOOL_DIR"
  git -C "$TOOL_DIR" init -q
  git -C "$TOOL_DIR" remote add origin "$TOOL_REPO"
  git -C "$TOOL_DIR" fetch --depth 1 origin "$TOOL_COMMIT"
  git -C "$TOOL_DIR" checkout -q FETCH_HEAD
fi

resolved_commit="$(git -C "$TOOL_DIR" rev-parse HEAD)"
[ "$resolved_commit" = "$TOOL_COMMIT" ] ||
  die "flatpak-flutter checkout is $resolved_commit, expected pinned $TOOL_COMMIT (stale $TOOL_DIR? remove it and rerun)"

# The venv holds the pinned tool's own dependencies, so it belongs to that
# commit: a bumped TOOL_COMMIT with a stale venv would run new generator code
# against whatever was installed for the old one. The stamp makes that
# visible instead of silent.
VENV_STAMP="$VENV_DIR/.tool-commit"
if [ -x "$VENV_DIR/bin/python3" ] && [ "$(cat "$VENV_STAMP" 2>/dev/null)" != "$TOOL_COMMIT" ]; then
  info "Discarding the venv built for a different flatpak-flutter commit"
  rm -rf "$VENV_DIR"
fi

if [ ! -x "$VENV_DIR/bin/python3" ]; then
  # Every hash this script commits comes out of the generator, so the
  # generator's own dependencies cannot be resolved at install time either.
  # flatpak-flutter pins each of them with `==`; if a future release stops
  # doing that, refuse rather than installing whatever is newest today.
  floating="$(grep -vE '^[[:space:]]*(#|$)' "$TOOL_DIR/requirements.txt" | grep -v '==' || true)"
  [ -z "$floating" ] ||
    die "flatpak-flutter's requirements.txt does not pin every dependency:
$floating
       Pin them (or pin a release that does) before generating source hashes."

  info "Creating a throwaway venv for flatpak-flutter's own dependencies"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install -q -r "$TOOL_DIR/requirements.txt"
  printf '%s\n' "$TOOL_COMMIT" > "$VENV_STAMP"
fi

cd "$FLATPAK_DIR"

# flatpak-flutter's pre-processing step only ever fetches a `git` source to
# discover an app's pubspec.lock (a `dir` source, used for the eventual
# flatpak-builder manifest, is intentionally skipped — see the comment in
# flatpak-flutter.yml). Working from an unpushed local branch, the workaround
# is to pre-stage the working-directory build slot flatpak-flutter is about
# to create — its build id is `(existing "linthra-*" dirs) + 1`, so on a
# clean slate, staging only `linthra-2` makes it land there deterministically
# instead of a stale directory from a previous run.
info "Staging the local checkout for pubspec.lock discovery"
rm -rf .flatpak-builder
mkdir -p .flatpak-builder/build/linthra-2
ln -sf "$REPO_ROOT/pubspec.yaml" .flatpak-builder/build/linthra-2/pubspec.yaml
ln -sf "$REPO_ROOT/pubspec.lock" .flatpak-builder/build/linthra-2/pubspec.lock
ln -sf "$REPO_ROOT/third_party" .flatpak-builder/build/linthra-2/third_party

info "Running flatpak-flutter"
"$VENV_DIR/bin/python3" "$TOOL_DIR/flatpak-flutter.py" flatpak-flutter.yml

rm -rf .flatpak-builder

# Audit what was just generated, offline and against the committed lockfile
# and Flutter pin. Same check CI runs; docs/flatpak-source-pinning.md lists
# what it holds the output to. Run with the venv's python because the check
# reads YAML and the venv already has flatpak-flutter's pinned PyYAML, so this
# does not add a system dependency to a script that only needed git+python3.
info "Checking the generated sources are pinned"
"$VENV_DIR/bin/python3" "$REPO_ROOT/scripts/check_flatpak_sources.py" ||
  die "the generated sources did not pass the pin check above. Nothing was
       reverted: read the findings, then either fix the input in
       flatpak-flutter.yml or bump the generator pin deliberately."

info "Done. Review the diff in flatpak/io.github.thezupzup.linthra.yml and flatpak/generated/."
info "The full offline-build audit needs Flutter: flutter test test/tooling/flatpak_offline_build_test.dart"
